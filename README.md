# docker-banyanos-gateway

本项目部署 Banyanos 网关及其 PostgreSQL、Neo4j 和 Redis 服务。网关从
`env/se-configdata.local.json` 加载配置，并在同一进程内将请求分发给十二个
Banyanos 引擎。

平台依赖包默认从 `requirements-silvaengine.txt` 所列仓库的 **main** 分支安装。
本地开发时，可设置 `SILVAENGINE_SRC`，优先使用本地框架源码。
两种模式都使用 `docker compose up -d` 启动。

## 1. 系统架构

```text
浏览器／前端
    | /beta/core/banyan/<engine>_engine_graphql
    v
网关 — FastAPI / Uvicorn，容器端口 8000
    |-- 路径规范化：支持带 stage/area/endpoint 前缀的请求路径
    |-- Banyan 鉴权桥：通过 perm_engine 检查访问权限
    |-- 网关 JWT 中间件：保护 /me 等网关接口
    |-- 十二个 Banyanos 引擎：在进程内执行 dispatch_graphql
    |-- PostgreSQL：业务、审计和遥测数据
    |-- Neo4j：图数据和向量数据
    |-- Redis：临时令牌、验证码及可选的流式事件
    `-- JSON 配置：启动时加载，以只读方式挂载
```

引擎之间的 HTTP 调用通过 `BANYAN_LOOPBACK_BASE_URL` 回到本网关，
携带引擎服务令牌，并经过同一鉴权桥验证。

## 2. 前置条件与环境配置

安装 Docker 及 Compose v2 插件，并准备以下内容：

- 本仓库及 Banyanos 引擎、模型提供方插件的源码仓库。
- 对平台私有仓库具有读取权限的 GitHub SSH 密钥。
- 包含部署参数及基础设施凭据的 `.env` 文件。
- 已填入实际配置值的 `env/se-configdata.local.json` 文件，其中使用 Docker 服务地址。

将 `.env.example` 复制为 `.env` 并替换占位值，或按照第 8 节使用
`deploy.sh` 生成环境配置和 JSON 配置。两个文件均包含敏感信息，请勿提交。

主要构建参数如下：

```dotenv
GATEWAY_IMAGE=banyanos-gateway:local
SETTING_SOURCE=json
db_backend=postgresql
BANYAN_MODULES_DIR=..
SSH_PRIVATE_KEY_FILE=./.ssh/id_ed25519
PIP_INDEX_URL=https://pypi.org/simple/
DOCKER_MIRROR_PREFIX=docker.io/library/

# 可选：优先使用本地框架源码。
# 默认使用镜像内安装的平台依赖包，保持下面这一行被注释即可。
# SILVAENGINE_SRC=./www/projects
```

`BANYAN_MODULES_DIR` 指向包含引擎仓库和 `llm_provider_*` 仓库的目录。
相对路径以本项目目录为基准。默认的本地目录结构如下：

```text
gitrepo/
    banyanos/
        docker-banyanos-gateway/
            www/
                projects/        # 框架和附加模块的默认源码工作区
        agent_engine/
        user_engine/
        ...
    silvaengine/                  # 仅本地框架开发时需要
        silvaengine_gateway/
        silvaengine_utility/
        ...
```

`db_backend` 独立选择业务数据存储，不影响 JSON 配置的加载方式。
使用随项目部署的 PostgreSQL 时，设置为 `postgresql`。
使用 AWS DynamoDB 时，需要有效的 AWS 凭据。
可选的 `docker-compose.ddb.yml` 用于启动存储业务数据的 DynamoDB Local，
不会初始化配置数据库。

宿主机端口可通过 `GATEWAY_HOST_PORT`、`POSTGRES_HOST_PORT`、
`REDIS_HOST_PORT`、`NEO4J_HTTP_HOST_PORT`、`NEO4J_BOLT_HOST_PORT` 和
`DYNAMODB_HOST_PORT` 配置，默认分别为 8000、5432、6379、7474、7687 和 8001。
容器端口及服务间调用地址保持不变。

## 3. 启动服务

```bash
docker compose up -d
docker compose ps
docker compose logs -f gateway
```

等待四个服务全部通过健康检查后，检查网关接口：

```bash
# 如果设置了 GATEWAY_HOST_PORT，请将 8000 替换为对应端口。
curl http://127.0.0.1:8000/health
```

直接执行 `docker compose up -d` 会自动加载 `docker-compose.yml` 和
`docker-compose.override.yml`。后者引用 `docker-compose.bindmount.yml`
中的网关服务配置。

| 文件 | 用途 | 普通启动命令是否加载 |
| --- | --- | --- |
| `docker-compose.yml` | 网关、数据库、缓存、端口及持久化数据卷 | 是 |
| `docker-compose.override.yml` | 将网关连接到镜像构建及源码挂载配置 | 是 |
| `docker-compose.bindmount.yml` | 镜像构建、Banyanos 源码挂载及可选的框架源码 | 由覆盖文件引用 |
| `docker-compose.ddb.yml` | 可选的 DynamoDB Local 服务 | 仅显式指定时加载 |

启动日志应包含以下原始日志文本：`JSON setting loaded:`、
`Pool bootstrap: framework pools created` 和 `Application startup complete`。
即使 `/health` 返回成功，也应检查日志；部分可选路由加载失败时，进程仍可能
通过健康检查。

## 4. JSON 配置与身份认证

`env/se-configdata.example.json` 是占位模板。启动前，请将实际部署参数填入
`env/se-configdata.local.json`。配置根对象是变量名到变量值的映射，
连接池配置位于 `plugins[0]["config"][<pool>]["settings"]`。

使用 `postgres:5432`、`redis:6379` 和 `neo4j:7687` 等 Docker 服务地址。
基础设施密码必须与 `.env` 保持一致。无效配置、空配置或未替换的占位值
会导致校验失败。修改 JSON 后应重启网关，无需配置数据库或初始化服务。

需要与预发布环境核对配置时，可使用现有的 `banyan/scripts/probe_seconfig.py`
流程及对应的 AWS 配置档案。启动时，网关通过 `BANYAN_LOOPBACK_BASE_URL`
改写已配置的 HTTP 连接池基础地址；使用绝对地址调用外部大模型的请求不受影响。

默认的模块认证模式将 `/auth/token` 登录请求交给 `user_engine` 处理。
网关本地账号和 Cognito 是另外两种受支持的认证模式。
不设置 `JWT_SECRET_KEY` 时，网关使用 JSON 配置中的共享 JWT 密钥。

### 4.1 首个管理员与权限资源

新数据库需要创建管理员并注册权限资源。先通过前端或 `registerUser` 注册用户，
再使用现有初始化脚本激活该用户、分配 `platform:super_admin` 角色并注册资源：

```bash
BANYAN_ADMIN_PASSWORD=... SE_CONFIGDATA_DATABASE_URL=... \
  python scripts/bootstrap_platform_admin.py \
  --email admin@example.com \
  --gateway-url http://127.0.0.1:8000/beta/core/banyan \
  --part-id <tenant>
```

通过环境变量传入密码，并根据实际部署修改网关地址和租户标识。
该初始化操作可重复执行。

### 4.2 流式输出配置

逐令牌流式输出需要为大模型事件生产端和智能体消费端配置 `llm_stream_redis`。
未配置时，对话退化为调用级事件。请按实际需求设置主机、端口、数据库、
认证信息、保留期限及事件流长度。

本地 GraphQL 订阅推送依赖 `silvaengine_utility` 在提交
`b7f000d18c2e68959e7342290f3965aac2f090f8` 中引入的 ConnectionManager 钩子。
WebSocket 地址为 `ws://127.0.0.1:<GATEWAY_HOST_PORT>/banyan/banyan_ws`。
前端从已登录用户所属的租户获取 `part_id`；平台用户使用部署分区作为后备值。
推理过程显示开关只控制展示哪些模型事件，不控制模型是否进行推理计算。

## 5. 验证步骤

重新构建镜像或修改源码配置后，执行以下检查：

1. 确认四个服务全部通过健康检查，且 `/health` 返回 HTTP 200。
2. 确认第 3 节列出的启动日志存在，并检查错误和警告。
3. 验证已配置的模块认证登录流程。
4. 确认无效令牌返回 401，无所需权限的调用者按路由授权规则被拒绝。
5. 执行一个有代表性的跨引擎请求，检查其回环调用链路。
6. 在 Banyanos 工作区运行现有的引擎回归测试。

`/me` 和 `/openapi.json` 均需要身份认证。未认证访问 OpenAPI 返回 401 属于
预期行为。HTTP OpenAPI 描述中不会列出 WebSocket 路由。

部署验证报告存放在 `docs/test_results/`，其中包括已执行的本地源码模式、
镜像内 main 分支依赖包模式等检查，以及各项验证的范围和限制。

## 6. 当前限制

- 网关路由清单可能引用本部署未安装的可选引擎。对应路由会被跳过，启动钩子
  也可能产生警告。使用这些可选接口前，应检查日志并配置实际需要的模块。
- 当前 x-api-key 检查只记录请求头是否存在，不校验密钥本身。
  Lambda 部署依赖 API Gateway 使用计划执行限制。
- HTTP 鉴权桥不覆盖 WebSocket 升级请求，WebSocket 路由使用独立的认证配置。
- 当前部署使用单个 Uvicorn 工作进程。使用多个工作进程前，需要评估任务、
  限流、连接及事件分发状态的共享方式。
- TLS、前端反向代理配置以及更完整的业务集成验证，需要单独实施。

## 7. 平台依赖包与本地开发

### 7.1 镜像构建与平台依赖

镜像先安装 `requirements-bindmount.txt` 中的第三方依赖，再使用 `--no-deps`
安装 `requirements-silvaengine.txt` 中的十个平台依赖包。
所有平台仓库地址均指向 **main** 分支，不再固定提交 SHA，也无需执行版本更新脚本。

将 GitHub 私钥放在 `.ssh/id_ed25519`，或通过 `SSH_PRIVATE_KEY_FILE`
指定其位置。BuildKit 仅在安装依赖时临时提供该密钥，不会将其复制进镜像或
挂载到运行中的服务。Linux/macOS 上建议将 `.ssh` 权限设为 700，私钥权限设为 600。

```bash
docker compose build gateway
docker compose up -d
```

即使 Git 分支已有更新，Docker 仍可能复用已缓存的依赖层。
需要明确获取当前 main 分支版本时，执行：

```bash
docker compose build --no-cache gateway
docker compose up -d gateway
```

重启容器不会执行 pip，也不会刷新已安装的依赖包。
修改依赖、Dockerfile 或复制进镜像的部署脚本后，需要重新构建镜像。

### 7.2 SILVAENGINE_SRC 如何选择框架代码

同一条 Compose 启动命令支持以下两种模式：

| `SILVAENGINE_SRC` 的值 | 实际使用的框架代码 | 挂载到 `/app/src` 的内容 |
| --- | --- | --- |
| 未设置或为空 | 镜像内从 main 分支安装的依赖包 | 默认工作区 `./www/projects`，不添加框架导入路径 |
| 非空目录路径 | 通过 PYTHONPATH 优先使用本地仓库 | 指定的宿主机目录，只读挂载 |

两种模式都会通过 `BANYAN_MODULES_DIR` 将 Banyanos 引擎和模型提供方插件
挂载到 `/app/modules`。启用本地开发后，镜像中已安装的平台依赖包仍然保留。

参照 `docker-a2a-gateway`，统一使用 `www/projects` 作为默认源码工作区，
并通过两个只读挂载区分框架和附加模块：

| 环境变量 | 默认宿主机目录 | 容器挂载路径 | 导入方式 |
| --- | --- | --- | --- |
| `SILVAENGINE_SRC` | `./www/projects` | `/app/src` | 设置非空变量后，自动添加十个平台仓库的 PYTHONPATH 路径 |
| `EXTRA_MODULES_DIR` | `./www/projects` | `/app/extra_modules` | 通过 `EXTRA_PYTHONPATH` 指定需要启用的附加仓库 |

未设置变量时，这两个路径都挂载默认工作区。设置 `SILVAENGINE_SRC` 前，
框架仍使用镜像内安装的 main 分支依赖包；没有 `EXTRA_PYTHONPATH` 条目的
附加模块也不会因此自动启用。两个变量可分别指向不同的宿主机目录。
Compose 仍会创建挂载，但不再需要单独的空占位目录。

`www` 和 `www/projects` 的目录标记文件纳入版本管理，克隆进去的本地仓库
由 `.gitignore` 排除，不会随本项目提交。

### 7.3 启用或关闭本地框架开发

启用本地源码时，可将框架仓库克隆到 `www/projects`，然后设置：

```dotenv
SILVAENGINE_SRC=./www/projects
```

如果框架仓库已经位于其他目录，也可以直接指定该父目录：

```dotenv
SILVAENGINE_SRC=C:/Users/bibo7/gitrepo/silvaengine
```

该目录应包含 `silvaengine_constants`、`silvaengine_utility`、
`silvaengine_dynamodb_base`、`silvaengine_definitions`、`silvaengine_connections`、
`silvaengine_base`、`mcp_http_client`、`silvaengine_daemon`、`mcp_protocol_plugin`
和 `silvaengine_gateway`。

使用普通启动命令应用设置：

```bash
docker compose up -d gateway
```

源码目录必须事先存在，Compose 不会自动创建。本地仓库可以包含开发中的修改；
Compose 不会切换其分支或拉取更新。`requirements-silvaengine.txt` 中的依赖地址
始终指向 main 分支。

附加模块独立配置，例如将 `rfq_engine` 克隆到 `www/projects/rfq_engine` 后：

```dotenv
EXTRA_MODULES_DIR=./www/projects
EXTRA_PYTHONPATH=/app/extra_modules/rfq_engine
```

需要恢复为镜像内依赖包时，删除或注释 `SILVAENGINE_SRC`，也可以将其设为空值，
然后再次执行 `docker compose up -d gateway`。
同时应清除终端中已导出的同名变量，因为终端环境变量优先于 `.env`。

修改已挂载的 Python 源码或 JSON 配置后，重启网关：

```bash
docker compose restart gateway
```

修改源码路径、端口或环境变量后，应执行 `up -d`，让 Compose 重建受影响的
容器配置。仅执行 `restart` 不会应用这些配置变更。

如果使用已经包含全部依赖和业务引擎的预构建镜像，可以显式只加载
`docker-compose.yml`，不加载源码挂载和构建覆盖配置。

## 8. 部署脚本

`deploy.sh` 封装了环境检查、配置生成、源码校验、端口检查、镜像构建、
JSON 校验、服务启动及健康和日志检查。宿主机需要 Docker 和 Compose v2，
脚本本身不要求安装 Python、jq 或 AWS CLI。

### 8.1 准备服务器

复制本项目及 Banyanos 引擎、模型提供方插件仓库，设置 `BANYAN_MODULES_DIR`，
提供用于构建的 GitHub 密钥，并准备 JSON 配置。
只有启用 `SILVAENGINE_SRC` 时，才需要同步本地框架仓库。

脚本保留已有的 `.env` 和 JSON 文件。两者都不存在时，使用模板及生成的凭据
创建文件；仅缺少 JSON 时，根据 `.env` 重新渲染；如果 JSON 存在但 `.env`
缺失，则停止执行，以避免凭据不一致。生成文件的权限为 600，并已从 Git 中排除。

### 8.2 命令说明

| 命令 | 作用 |
| --- | --- |
| `bash deploy.sh` | 使用现有 Compose 配置构建并部署 |
| `bash deploy.sh status` | 查看容器健康状态及必需的启动日志 |
| `bash deploy.sh down` | 停止服务，保留数据卷 |
| `bash deploy.sh down -v` | 停止服务并删除数据卷 |
| `bash deploy.sh --restart` | 部署后重启网关 |
| `bash deploy.sh --force-env` | 重新生成 `.env` 和 JSON，凭据会改变 |
| `bash deploy.sh --dry-run` | 检查环境、配置和端口，不启动容器 |
| `bash deploy.sh --self-test` | 运行脚本自检，无需 Docker |

首次生成环境文件前，可通过 `TENANT_PART_ID`（默认 `nestaging`）、
`BANYAN_MODULES_DIR` 和 `SSH_PRIVATE_KEY_FILE`（默认 `./.ssh/id_ed25519`）
覆盖对应参数。`GATEWAY_WAIT_TIMEOUT` 用于调整健康检查等待时间。
需要本地框架开发时，在 `.env` 中设置 `SILVAENGINE_SRC`。

种子配置渲染器要求其替换的凭据值仅包含字母和数字。脚本生成的 JWT 密钥和
x-api-key 写入 JSON 文件。请保持 `.env` 与 JSON 中的基础设施凭据一致。
使用 `--force-env` 或删除配置文件前，应确认其影响范围。

仅向公网开放预期的网关端口。数据库和缓存的宿主机端口用于受控的本地开发访问，
应根据目标环境检查端口绑定方式及防火墙规则。
