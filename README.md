# docker-banyanos-gateway — Banyan 生产数据面部署（P0）

> P0 最小交付：网关容器 + postgres + neo4j + redis，se-configdata 读真实云端
> DynamoDB。nginx 统一入口（TLS / 前端反代）归 P1；任务/限流共享后端归 P2。
> 容器级操作（compose up、镜像构建）由使用者执行——本仓交付物为配置与脚本。

## 1. 架构

```
浏览器/前端
    │  /beta/core/banyan/{function}（API-GW 路径契约）
    ▼
gateway (FastAPI, uvicorn :8000)
    ├─ BanyanPathNormalizer   剥 /{stage}/{area} 前缀 → 双契约并存
    ├─ BanyanAuthorizerBridge perm_engine.PermAuthorizer 真实鉴权（401/403）
    ├─ FlexJWTMiddleware      非 Banyan 域（本网关自有 /auth 等）走 local/Cognito
    └─ 路由分发 → 12 引擎进程内 dispatch_graphql
         │
         ├─ postgres:16  关系型/审计/遥测（三池：postgres_main/audit/telemetry）
         ├─ neo4j:5      图数据 + 向量（唯一存储，铁律二）
         ├─ redis:7      瞬态令牌/验证码
         └─ DynamoDB（云端 se-configdata，启动时只读）
                └─ 跨引擎互调：httpx 池回环（BANYAN_LOOPBACK_BASE_URL）
                   引擎服务令牌经鉴权桥验证——与前端调用同一路径，无内部旁路
```

## 2. 前置条件与 .env

镜像：`GATEWAY_IMAGE` 必须是含 12 引擎 + 框架的扩展镜像（P1 由
`docker-silvaengine-gateway` 仓构建；PYTHONPATH 布局
`/app/modules/<12 引擎仓根>`（SilvaEngine 包由 pip 安装到 site-packages），与 api-runtime 已验证形态一致）。

AWS：默认读真实云端 `se-configdata`（`beta_core_banyan` 记录，**只读**），
凭证需有该表读权限；完全离线用文末 DDB Local 变体。

在本项目根目录下创建 `.env`（不要提交）：

```dotenv
# --- 网关镜像 ---
GATEWAY_IMAGE=silvaengine-gateway-banyan:latest

# --- DynamoDB（云端 se-configdata，只读）---
region_name=us-west-2
aws_access_key_id=<AWS_KEY_WITH_DDB_READ>
aws_secret_access_key=<AWS_SECRET>

# --- 数据面基础设施（与 se-configdata 记录值保持一致）---
POSTGRES_USER=banyan
POSTGRES_PASSWORD=<PG_PASSWORD>
POSTGRES_DB=banyan
NEO4J_AUTH=neo4j/<NEO4J_PASSWORD>
REDIS_PASSWORD=<REDIS_PASSWORD>

# --- 可选覆盖（默认见 docker-compose.yml environment 段）---
# ENDPOINT_ID=banyan
# ADAPTER_STAGE=beta
# ADAPTER_AREA=core
# BANYAN_LOOPBACK_BASE_URL=http://127.0.0.1:8000/beta/core/banyan
# SE_CONFIGDATA_TABLE=se-configdata
# SE_CONFIGDATA_ENDPOINT_URL=http://ddb-local:8000   # DDB Local 变体
```

## 3. 启动

```bash
cd docker-banyanos-gateway
docker compose up -d
docker compose ps          # 等 gateway healthy
curl http://127.0.0.1:8000/health
```

启动日志应出现：`se-configdata setting loaded: setting_id=beta_core_banyan`
与 `Pool bootstrap: framework pools created`——两者缺失说明
配置叠加或池引导未生效，先排查再继续。

## 4. se-configdata 记录

`env/se-configdata.example.json` 是**占位模板**（无真实密钥），记录形态：
`(setting_id, variable) → value` 每变量一行；`plugins` 为列表，
池配置位于 `plugins[0]["config"][<pool>]["settings"]`。

权威变量集合是 staging 真实记录——用
`banyan/scripts/probe_seconfig.py`（AWS profile `ideabosque-dev`）核对后再
填充/裁剪模板；`httpx_*` 池的 `base_url` 会被 `BANYAN_LOOPBACK_BASE_URL`
启动时统一改写为回环地址，无需在记录里预改。

灌表（仅 DDB Local 变体需要）：

```bash
python scripts/seed_seconfig.py --file env/se-configdata.local.json \
    --endpoint-url http://127.0.0.1:8001 --apply
```

默认 dry-run，`--apply` 才写。含真实密钥的文件严禁提交任何仓库。

## 5. P0 验收步骤（使用者执行）

1. `docker compose ps` 全部 healthy；`curl /health` 200。
2. 前端契约：`POST http://127.0.0.1:8000/beta/core/banyan/user_engine_graphql`
   （`part_id` 头 + Banyan JWT）登录 mutation 返回 token。
3. 鉴权负向：错误 token → 401；有效 token 但无角色权限 → 403。
4. 回环链路：触发一次跨引擎调用（如 invokeAgent → httpx_agent 池），网关
   日志可见同一请求二次进入鉴权桥（服务令牌）且业务结果正常。
5. x-api-key 护栏：带 `x-api-key` 头调用一次，debug 日志出现
   `x-api-key present: True`（P0 仅记录存在性，不校验）。
6. 12 引擎 pytest（banyan 仓，引擎侧零改动回归）。

## 6. P0 已知边界

- **x-api-key**：透传不校验（Lambda 链由 API-GW usage plan 强制），存在性
  日志护栏已加；校验归 P1 评审。
- **WebSocket**：鉴权桥为 BaseHTTPMiddleware，WS 升级请求不经其拦截
  （Starlette 行为）；WS 路由的鉴权策略归 P1 评审。
- **nginx/TLS/前端反代**：P1；**任务/限流共享后端**（多 worker）：P2。
- 单进程部署（uvicorn 单 worker，ConnectionManager MVP 约束）；多 worker
  前置依赖 P2 的任务/限流后端改造。
- staging se-configdata 的真实记录值（尤其 `httpx_llm` 等池形态）以
  probe 实测为准；发现与模板不一致时以记录为准修模板。

## 7. Pip-installed SilvaEngine + local Banyanos source

The overlay builds a Python 3.12 image. Pip installs the gateway, six shared
SilvaEngine framework packages, and the MCP daemon/plugin/client from the
private GitHub repositories in `requirements-silvaengine.txt`. Third-party
dependencies come from `requirements-bindmount.txt`. Only the 12 Banyanos
engines are mounted from local source at `/app/modules`.

### 7.1 SSH key and environment

Place a GitHub SSH private key with read access to **every** repository listed
in `requirements-silvaengine.txt` at `.ssh/id_ed25519` in this directory.
Add its public key to the appropriate GitHub account or repository deploy-key
configuration. On Linux/macOS:

```bash
mkdir -p .ssh
# Put your private key at .ssh/id_ed25519, then:
chmod 700 .ssh
chmod 600 .ssh/id_ed25519
```

The key is ignored by Git, excluded from the Docker build context, and passed
as a BuildKit secret only during installation. It is never copied into the
image or mounted in the running gateway. The build needs GitHub SSH access
(port 22) and access to the pip index. SSH host checking uses a known_hosts
file populated by ssh-keyscan during the build.

Add to the environment from section 2:

```dotenv
GATEWAY_IMAGE=banyanos-gateway:local
BANYAN_MODULES_DIR=C:/Users/bibo7/gitrepo/banyanos
SSH_PRIVATE_KEY_FILE=./.ssh/id_ed25519
# Alternatively point SSH_PRIVATE_KEY_FILE at an existing private key.
# PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
# SILVAENGINE_CACHE_TTL=300
```

Existing gateway/framework/vendor/MCP path variables can be removed; the
overlay and deploy script no longer use them. Keep existing passwords and
seed configuration when migrating.

### 7.2 Build and start

```bash
docker compose -f docker-compose.yml -f docker-compose.bindmount.yml build gateway
docker compose -f docker-compose.yml -f docker-compose.bindmount.yml up -d
docker compose -f docker-compose.yml -f docker-compose.bindmount.yml logs -f gateway
```

For DynamoDB Local include `-f docker-compose.ddb.yml` or run `bash deploy.sh`.
Package installation happens at build time. Container restarts do not run pip.
Banyanos source changes take effect after `docker compose ... restart gateway`.
SilvaEngine changes require rebuilding the image; to fetch newer commits at
the same `@main` reference, use `build --no-cache gateway` and recreate the
gateway with `up -d gateway`. Pin Git references to release tags or commits
for repeatable releases.

### 7.3 Acceptance

Use the acceptance checks in section 5. The base compose alone still supports
a prebuilt image; that image must supply both the dependencies and Banyanos
engines if the source overlay is omitted.

## 8. 一键部署脚本 deploy.sh（模式 A 全自动）

`deploy.sh` 把 §2/§4/§7 的手工步骤（`.env` 生成、种子 JSON 渲染、源码树校验、
端口预检、DDB Local 启动与初始化、五服务 up、健康与关键日志验证）封装为
幂等一键流程。目标服务器只需预装 Docker（含 Compose v2 插件），无需
Python / jq / awscli；每阶段有状态输出，失败给出具体原因与排查建议后安全
退出，修复后直接重跑，整体回滚 `bash deploy.sh down`。

### 8.1 服务器准备（一次性）

同步本项目与 12 个 Banyanos 引擎目录，设置 `BANYAN_MODULES_DIR` 指向引擎仓根目录。
SilvaEngine 仓与 vendor 快照无需同步。按 §7.1 放置 GitHub SSH 私钥；
首次构建需要访问 GitHub 与 pip 索引，DynamoDB Local 仅替代云端配置数据库。

### 8.2 命令

| 命令 | 作用 |
| --- | --- |
| `bash deploy.sh` | 部署/更新（幂等，重复执行安全） |
| `bash deploy.sh status` | 容器状态 + 健康检查 + 关键日志核查 |
| `bash deploy.sh down` | 停止并清理（数据卷保留） |
| `bash deploy.sh down -v` | 停止并连数据卷一起删除 |
| `bash deploy.sh --restart` | 部署后重启 gateway（改源码/种子 JSON 后） |
| `bash deploy.sh --force-env` | 重新生成 .env 与种子 JSON（密码会变） |
| `bash deploy.sh --dry-run` | 只跑环境检测/配置生成/校验/端口预检，不起容器 |
| `bash deploy.sh --self-test` | 内置纯逻辑自检（不碰 docker） |

环境变量（首次生成 `.env` 前生效）：`TENANT_PART_ID`（默认 nestaging）、
`BANYAN_MODULES_DIR`（优先于自动探测）和 `SSH_PRIVATE_KEY_FILE`
（默认 `./.ssh/id_ed25519`）。`GATEWAY_WAIT_TIMEOUT` 随时可设。

### 8.3 设计要点

- 密钥自动生成：PG / Neo4j / Redis 密码各 16 位随机，JWT_SECRET 与 x-api-key
  各 32 位随机（后两者只写入种子 JSON）；`.env` 与种子 JSON 均 600 权限，
  `.gitignore` 已排除，勿提交。
- 四态状态机：`.env`/JSON 都在→复用；都无→生成；仅 `.env`→补渲染；
  仅 JSON（孤儿态）→报错（防密码不一致）。配置值强制纯字母数字（sed
  渲染防注入），改密码后删 JSON 重跑。
- 幂等与自愈：重复运行 `.env`/JSON 内容不变；每次重灌 DDB Local 种子，
  `-inMemory` 重建后自动恢复。`--force-env` 为显式重新生成入口。
- 与 §7 手动路径同一 compose project（目录名 deploy），容器/卷/网络互通。
- base compose 若已手动取消注释 ddb-local，请注释回去（脚本会警告端口冲突）。
- 公网防火墙只放行 8000；8001/5432/6379/7474/7687 仅供本机调试。
- 12 引擎 pytest 仍在开发机 banyan 仓执行（服务器无 Python）。
