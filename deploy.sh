#!/usr/bin/env bash
# =============================================================================
# SilvaEngine Gateway — Banyan deployment with direct JSON configuration
#
# The target server only needs Docker preinstalled (with the Compose v2 plugin); no Python / jq / awscli.
# This script wraps the manual path in README.md (§2/§4/§7) into an idempotent one-shot flow:
#
#   Stage 1  environment check     docker / daemon reachable / compose v2
#   Stage 2  config & source check .env and seed JSON generate/reuse (four-state machine) +
#                                  12 Banyanos engine source directories
#   Stage 3  port pre-check        configured application service host ports
#   Stage 4  build image           pip-installed gateway + JSON settings support
#   Stage 5  validate JSON         env/se-configdata.local.json (no configuration database)
#   Stage 6  start runtime         postgres neo4j redis gateway
#   Stage 7  health & log checks   4 containers healthy + /health probe + two key startup log lines
#   Stage 8  summary               addresses / tenant / verification steps / common operations
#
# Usage:
#   bash deploy.sh                # deploy/update (idempotent, safe to rerun)
#   bash deploy.sh status         # status and health check
#   bash deploy.sh down [-v]      # stop and clean up (-v also deletes data volumes)
#   bash deploy.sh --restart      # restart gateway after deploy (after source/JSON edits)
#   bash deploy.sh --bump         # bump SilvaEngine pins to the latest main, then deploy
#   bash deploy.sh --bump=staging # same for staging (also --bump=dev; main where a repo lacks the branch)
#   bash deploy.sh --force-env    # regenerate .env and the seed JSON (passwords change)
#   bash deploy.sh --dry-run      # run stages 1-3 only (generate .env/JSON, no containers)
#   bash deploy.sh --self-test    # built-in pure-logic self-test (no docker)
#
# Environment variable overrides available before .env is first generated:
#   TENANT_PART_ID (default nestaging), BANYAN_MODULES_DIR, SSH_PRIVATE_KEY_FILE;
#   GATEWAY_WAIT_TIMEOUT (health wait limit in seconds, default 600) can be set any time.
#
# Configuration is read from JSON on gateway startup. Application data uses
# db_backend=postgresql or dynamodb, independently of the configuration source.
# Reruns preserve .env and the JSON file. Any failed stage
# exits safely with a reason; fix it and rerun. Full rollback: bash deploy.sh down.
#
# Compatibility: bash 3.2+ (the macOS stock version works), no Python / associative array dependencies.
# =============================================================================
set -Eeuo pipefail
umask 077
export LC_ALL=C

DEPLOY_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DEPLOY_DIR"
# Banyanos engines live beside this project locally, or under banyan/modules on the server.
PARENT_DIR=$(cd "$DEPLOY_DIR/.." && pwd)

ENV_FILE="$DEPLOY_DIR/.env"
SEED_DIR="$DEPLOY_DIR/env"
EXAMPLE_JSON="$SEED_DIR/se-configdata.example.json"
SEED_JSON="$SEED_DIR/se-configdata.local.json"

COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.override.yml)
UP_SERVICES=(postgres neo4j redis gateway)
HOST_PORTS=(8000 5432 6379 7474 7687)
ENGINE_REPOS=(agent_engine capability_engine knowledge_engine llm_engine \
  memory_engine merchant_engine monitor_engine orchestration_engine \
  perm_engine prompt_engine setting_engine user_engine)
REQUIRED_LOGS=("JSON setting loaded:" \
  "Pool bootstrap: framework pools created")
OPTIONAL_LOGS=("Rewrote [0-9]+ httpx pool base_url")

REQUIRED_ENV_KEYS=(GATEWAY_IMAGE TENANT_PART_ID POSTGRES_USER POSTGRES_PASSWORD \
  POSTGRES_DB NEO4J_AUTH REDIS_PASSWORD \
  BANYAN_MODULES_DIR)

WAIT_TIMEOUT="${GATEWAY_WAIT_TIMEOUT:-600}"
FORCE_ENV=0
DRY_RUN=0
RESTART=0
BUMP=0
BUMP_BRANCH="main"
VOLUMES=0
MODE="up"

CURRENT_STAGE="0"
STAGE_DESC="初始化"
STAGE_HINT=""

log() { printf '[deploy.sh] %s\n' "$*"; }

set_stage() {
  CURRENT_STAGE="$1"
  STAGE_DESC="$2"
  STAGE_HINT="$3"
  log "── 阶段 $1/8：$2"
}

die() {
  printf '\n[deploy.sh] X 阶段 %s（%s）失败：%s\n' \
    "$CURRENT_STAGE" "$STAGE_DESC" "$*" >&2
  if [ -n "$STAGE_HINT" ]; then
    printf '[deploy.sh] 排查建议：%s\n' "$STAGE_HINT" >&2
  fi
  printf '[deploy.sh] 本脚本幂等——修复后可直接重跑；整体回滚：bash deploy.sh down（-v 连数据卷）\n' >&2
  exit 1
}

on_error() {
  local code=$?
  printf '\n[deploy.sh] X 阶段 %s（%s）内部异常（退出码 %s，行 %s）。\n' \
    "$CURRENT_STAGE" "$STAGE_DESC" "$code" "${BASH_LINENO[0]:-?}" >&2
  if [ -n "$STAGE_HINT" ]; then
    printf '[deploy.sh] 排查建议：%s\n' "$STAGE_HINT" >&2
  fi
  printf '[deploy.sh] 本脚本幂等——修复后可直接重跑；整体回滚：bash deploy.sh down（-v 连数据卷）\n' >&2
  exit "$code"
}
trap on_error ERR

usage() {
  cat <<'USAGE'
SilvaEngine Gateway — Banyan 一键部署（JSON configuration）

用法: bash deploy.sh [命令] [选项]

命令:
  (默认)      部署/更新（幂等，可重复执行）
  status      容器状态 + 健康检查 + 关键日志核查
  down        停止并清理（数据卷保留）；down -v 连数据卷一起删除

选项:
  --restart   部署后重启 gateway（修改源码/种子 JSON 后使用）
  --bump[=main|dev|staging]
              部署前把 SilvaEngine 依赖 pin 切换并升到该分支最新提交（默认 main；
              无该分支的仓库回退 main；scripts/bump_silvaengine.sh）。
              不加则按 requirements 现有 SHA 构建
  --force-env 删除并重新生成 .env 与种子 JSON（密码会变更）
  --dry-run   只跑阶段 1-3（环境检测/配置生成/校验/端口预检），不起容器
  --self-test 内置纯逻辑自检（不碰 docker）
  -h, --help  显示本帮助

环境变量（首次生成 .env 前生效，路径类覆盖探测结果）:
  TENANT_PART_ID            租户 part_id（默认 nestaging）
  BANYAN_MODULES_DIR        Banyan 12 引擎目录（banyan/modules）
  SSH_PRIVATE_KEY_FILE     GitHub SSH private key (default ./.ssh/id_ed25519; build only)
  GATEWAY_WAIT_TIMEOUT      健康等待上限秒数（默认 600）
USAGE
}

# ---------------------------------------------------------------------------
# Basic utility functions
# ---------------------------------------------------------------------------

dc() { docker compose "${COMPOSE_FILES[@]}" "$@"; }

# Random alphanumeric string (urandom | tr | head; trailing || true guards SIGPIPE under pipefail)
rand_alnum() {
  local n="$1" out
  out=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$n" || true)
  printf '%s' "$out"
}

# Escape a sed replacement string (\ / & ; this script uses | as the delimiter but escapes generically)
sed_escape() {
  printf '%s' "$1" | sed 's/[\\/&]/\\&/g' || true
}

# Return the first existing candidate path in order; non-zero if none exist
first_existing() {
  local c
  for c in "$@"; do
    if [ -e "$c" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

# Read a key from .env (strips paired quotes; missing key returns an empty string)
env_get() {
  local key="$1" line val
  line=$(grep -m1 "^${key}=" "$ENV_FILE" 2>/dev/null || true)
  val="${line#*=}"
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
  esac
  printf '%s' "$val"
}

# Return 0 if the port is busy, non-zero if free. Prefer timeout to bound the probe (macOS without
# timeout connects directly; an unlistened port on 127.0.0.1 gets an immediate RST, so it won't hang)
port_busy() {
  local port="$1"
  if command -v timeout >/dev/null 2>&1; then
    if timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" >/dev/null 2>&1; then
      return 0
    fi
  else
    if bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Stage 2: config generation and validation
# ---------------------------------------------------------------------------

# Load all of .env into shell variables (used to render the seed JSON and by later stages)
load_env_values() {
  TENANT_PART_ID=$(env_get TENANT_PART_ID)
  PG_USER=$(env_get POSTGRES_USER)
  PG_PASSWORD=$(env_get POSTGRES_PASSWORD)
  PG_DB=$(env_get POSTGRES_DB)
  NEO4J_AUTH=$(env_get NEO4J_AUTH)
  NEO4J_PASSWORD="${NEO4J_AUTH#neo4j/}"
  REDIS_PASSWORD=$(env_get REDIS_PASSWORD)
  BANYAN_MODULES_DIR=$(env_get BANYAN_MODULES_DIR)
  load_host_ports
}

# Match Compose precedence: shell environment, .env, then the documented default.
load_host_ports() {
  local spec key value
  HOST_PORTS=()
  for spec in GATEWAY_HOST_PORT:8000 POSTGRES_HOST_PORT:5432 REDIS_HOST_PORT:6379 \
    NEO4J_HTTP_HOST_PORT:7474 NEO4J_BOLT_HOST_PORT:7687; do
    key="${spec%%:*}"
    value="${!key:-}"
    [ -n "$value" ] || value=$(env_get "$key")
    value="${value:-${spec#*:}}"
    case "$value" in
      *[!0-9]*|'') die "Invalid host port: $key (expected 1-65535)" ;;
    esac
    if [ "${#value}" -gt 5 ] || [ "$((10#$value))" -lt 1 ] || [ "$((10#$value))" -gt 65535 ]; then
      die "Invalid host port: $key (expected 1-65535)"
    fi
    printf -v "$key" '%s' "$value"
    HOST_PORTS+=("$value")
  done
}

# Config values must be purely alphanumeric: this script renders the seed JSON with sed, and a wider
# charset would introduce injection/escaping issues; for passwords with special characters use mode B's manual table load
assert_alnum() {
  local name="$1" val="$2"
  if [ -z "$val" ]; then
    die "配置值校验失败：$name 为空（.env）"
  fi
  case "$val" in
    *[!A-Za-z0-9]*)
      die "配置值校验失败：$name 含非字母数字字符。种子 JSON 由 sed 渲染，为避免转义问题，请把 .env 中该值改为纯字母数字，删除 env/se-configdata.local.json 后重跑（或 --force-env 重新生成）"
      ;;
  esac
}

# First deploy: discover source paths + generate random passwords → .env
generate_env() {
  local part_id pg_pw neo4j_pw redis_pw tmp_f

  # Path discovery: environment variable overrides win, otherwise probe the
  # local layout first, then the server workspace layout (see PARENT_DIR above).
  if [ -z "${BANYAN_MODULES_DIR:-}" ]; then
    # local: banyanos/ itself holds the engine repos (banyanos/<repo>/<repo>/)
    if [ -d "$PARENT_DIR/agent_engine" ]; then
      BANYAN_MODULES_DIR="$PARENT_DIR"
    elif ! BANYAN_MODULES_DIR=$(first_existing "$PARENT_DIR/banyan/modules"); then
      BANYAN_MODULES_DIR=""
    fi
  fi

  part_id="${TENANT_PART_ID:-nestaging}"
  pg_pw=$(rand_alnum 16)
  neo4j_pw=$(rand_alnum 16)
  redis_pw=$(rand_alnum 16)

  tmp_f="$ENV_FILE.tmp.$$"
  cat > "$tmp_f" <<EOF
# docker-banyanos-gateway .env — generated by deploy.sh, do not commit (contains passwords).
# After editing, rerun bash deploy.sh to apply; keys are described in README.md §2/§7.1.

# --- Locally built gateway image ---
GATEWAY_IMAGE=banyanos-gateway:local

# --- Configuration from JSON; application database selected independently ---
SETTING_SOURCE=json
db_backend=${db_backend:-postgresql}

# --- Published host ports (internal container ports stay fixed) ---
GATEWAY_HOST_PORT=${GATEWAY_HOST_PORT:-8000}
POSTGRES_HOST_PORT=${POSTGRES_HOST_PORT:-5432}
REDIS_HOST_PORT=${REDIS_HOST_PORT:-6379}
NEO4J_HTTP_HOST_PORT=${NEO4J_HTTP_HOST_PORT:-7474}
NEO4J_BOLT_HOST_PORT=${NEO4J_BOLT_HOST_PORT:-7687}
DYNAMODB_HOST_PORT=${DYNAMODB_HOST_PORT:-8001}

# --- Banyan authentication delegates login to user_engine ---
GATEWAY_AUTH_PROVIDER=${GATEWAY_AUTH_PROVIDER:-module}
GATEWAY_AUTH_MODULE_DISPATCH=${GATEWAY_AUTH_MODULE_DISPATCH:-user_engine.main:dispatch_graphql}
JWT_ALGORITHM=${JWT_ALGORITHM:-HS256}
ACCESS_TOKEN_EXP=${ACCESS_TOKEN_EXP:-15}
# Leave JWT_SECRET_KEY unset to use the shared jwt_secret from the JSON file.

# --- Tenant ---
TENANT_PART_ID=${part_id}

# --- Data-plane infrastructure (random passwords, purely alphanumeric) ---
POSTGRES_USER=banyan
POSTGRES_PASSWORD=${pg_pw}
POSTGRES_DB=banyan
NEO4J_AUTH=neo4j/${neo4j_pw}
REDIS_PASSWORD=${redis_pw}

# --- AWS credentials: configure real credentials for db_backend=dynamodb ---
# Placeholder signing credentials for PostgreSQL-only local use
region_name=us-west-2
aws_access_key_id=local
aws_secret_access_key=local

# --- Only Banyanos source is mounted ---
BANYAN_MODULES_DIR=${BANYAN_MODULES_DIR}
# Private GitHub access for image build; key never enters the image.
SSH_PRIVATE_KEY_FILE=${SSH_PRIVATE_KEY_FILE:-./.ssh/id_ed25519}
PIP_INDEX_URL=${PIP_INDEX_URL:-https://pypi.org/simple/}

# --- Optional overrides (uncomment to enable) ---
# SILVAENGINE_CACHE_TTL=300
# BANYAN_LOOPBACK_BASE_URL=http://127.0.0.1:8000/beta/core/banyan
EOF
  mv -f "$tmp_f" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  log "已生成 .env（随机密码 16 位；JWT/x-api-key 密钥仅在种子 JSON 中）"
}

# Render the seed JSON from .env: replace 8 placeholders + drop _comment lines + verify after rendering
render_seed_json() {
  local jwt api_key sed_script tmp_f

  assert_alnum "TENANT_PART_ID" "$TENANT_PART_ID"
  assert_alnum "POSTGRES_USER" "$PG_USER"
  assert_alnum "POSTGRES_DB" "$PG_DB"
  assert_alnum "POSTGRES_PASSWORD" "$PG_PASSWORD"
  assert_alnum "NEO4J_PASSWORD" "$NEO4J_PASSWORD"
  assert_alnum "REDIS_PASSWORD" "$REDIS_PASSWORD"
  jwt=$(rand_alnum 32)
  api_key=$(rand_alnum 32)
  assert_alnum "JWT_SECRET" "$jwt"
  assert_alnum "ENV_API_KEY" "$api_key"

  sed_script=$(mktemp) || die "mktemp 失败"
  tmp_f=$(mktemp) || { rm -f "$sed_script"; die "mktemp 失败"; }
  {
    printf 's|<TENANT_PART_ID>|%s|g\n' "$(sed_escape "$TENANT_PART_ID")"
    printf 's|<REPLACE_WITH_BANYAN_JWT_SECRET>|%s|g\n' "$(sed_escape "$jwt")"
    printf 's|<NEO4J_PASSWORD>|%s|g\n' "$(sed_escape "$NEO4J_PASSWORD")"
    printf 's|<REDIS_PASSWORD>|%s|g\n' "$(sed_escape "$REDIS_PASSWORD")"
    printf 's|<POSTGRES_DB>|%s|g\n' "$(sed_escape "$PG_DB")"
    printf 's|<POSTGRES_USER>|%s|g\n' "$(sed_escape "$PG_USER")"
    printf 's|<POSTGRES_PASSWORD>|%s|g\n' "$(sed_escape "$PG_PASSWORD")"
    printf 's|<ENV_API_KEY>|%s|g\n' "$(sed_escape "$api_key")"
    printf '/^[[:space:]]*"_comment"[[:space:]]*:/d\n'
  } > "$sed_script"
  sed -f "$sed_script" "$EXAMPLE_JSON" > "$tmp_f" \
    || { rm -f "$sed_script" "$tmp_f"; die "种子 JSON 渲染失败（sed 异常）"; }
  rm -f "$sed_script"

  if grep -q '<[A-Z][A-Z0-9_]*>' "$tmp_f"; then
    rm -f "$tmp_f"
    die "种子 JSON 仍残留未替换占位符——env/se-configdata.example.json 可能被改动过"
  fi
  if grep -q '"_comment"' "$tmp_f"; then
    rm -f "$tmp_f"
    die "种子 JSON 仍含 _comment 模板元数据"
  fi
  mv -f "$tmp_f" "$SEED_JSON"
  chmod 600 "$SEED_JSON"
  log "已渲染 env/se-configdata.local.json（含随机 JWT_SECRET 与 x-api-key）"
}

# Required-key non-empty check (collect all missing keys, then report once)
validate_env_keys() {
  local missing=() k v
  for k in "${REQUIRED_ENV_KEYS[@]}"; do
    v=$(env_get "$k")
    if [ -z "$v" ]; then
      missing+=("$k")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die ".env 缺少必填键：${missing[*]}。手工补全，或删除 .env 与 env/se-configdata.local.json 后重跑自动生成（或 --force-env）"
  fi
}

# Source-tree check (collect all problems, then report once so they can be fixed in one go)
validate_source_paths() {
  local problems=() f d

  for d in "${ENGINE_REPOS[@]}"; do
    if [ ! -d "$BANYAN_MODULES_DIR/$d" ]; then
      problems+=("Banyan 引擎目录缺失：${BANYAN_MODULES_DIR}/$d（.env: BANYAN_MODULES_DIR）")
    fi
  done
  local key_file
  key_file=$(env_get SSH_PRIVATE_KEY_FILE)
  key_file="${key_file:-./.ssh/id_ed25519}"
  if [ ! -s "$key_file" ]; then
    problems+=("Place a GitHub SSH private key at $key_file (or set SSH_PRIVATE_KEY_FILE in .env)")
  fi
  for f in Dockerfile requirements-silvaengine.txt; do
    if [ ! -f "$DEPLOY_DIR/$f" ]; then problems+=("Missing $f"); fi
  done
  if [ ! -f "$DEPLOY_DIR/requirements-bindmount.txt" ]; then
    problems+=("缺少 requirements-bindmount.txt")
  fi
  if [ ! -f "$EXAMPLE_JSON" ]; then
    problems+=("缺少模板 env/se-configdata.example.json")
  fi

  if [ "${#problems[@]}" -gt 0 ]; then
    printf '[deploy.sh] 源码树校验未通过（%s 项）：\n' "${#problems[@]}" >&2
    for d in "${problems[@]}"; do
      printf '  - %s\n' "$d" >&2
    done
    die "源码树不完整——按上方清单补齐后重跑；源路径可用环境变量覆盖（见 -h）"
  fi

  log "源码树校验通过：12 Banyanos engines + pip requirements + build SSH key"
}

# Four-state machine: reuse / generate / re-render from .env only / orphan error
ensure_config() {
  if [ "$FORCE_ENV" = "1" ]; then
    log "--force-env：删除并重新生成 .env 与种子 JSON（密码将变更）"
    rm -f "$ENV_FILE" "$SEED_JSON"
  fi

  local have_env=0 have_json=0
  if [ -f "$ENV_FILE" ]; then have_env=1; fi
  if [ -f "$SEED_JSON" ]; then have_json=1; fi

  if [ "$have_env" = "1" ] && [ "$have_json" = "1" ]; then
    log "复用现有配置：.env + env/se-configdata.local.json"
    load_env_values
  elif [ "$have_env" = "0" ] && [ "$have_json" = "0" ]; then
    log "首次部署：自动生成 .env（随机密码）并渲染种子 JSON"
    generate_env
    load_env_values
    render_seed_json
  elif [ "$have_env" = "1" ]; then
    log "种子 JSON 缺失——按现有 .env 重新渲染（密码/JWT 会重生成）"
    load_env_values
    render_seed_json
  else
    die "孤儿状态：env/se-configdata.local.json 存在但 .env 缺失（两者密码会不一致）。请恢复 .env，或两者都删除后重跑（或 --force-env 重新生成全部密码）"
  fi

  validate_env_keys
  validate_source_paths
}

# ---------------------------------------------------------------------------
# Stages 1/3: environment and ports
# ---------------------------------------------------------------------------

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    die "未找到 docker 命令——请先安装 Docker：https://docs.docker.com/engine/install/"
  fi
  local info_out cv
  if ! info_out=$(docker info 2>&1); then
    printf '%s\n' "$info_out" >&2
    if printf '%s' "$info_out" | grep -qi 'permission denied'; then
      die "Docker 守护进程连接被拒（permission denied）——当前用户不在 docker 组。修复：sudo usermod -aG docker \$(id -un)，然后重新登录会话"
    fi
    die "Docker 守护进程未运行或连接失败——请启动 Docker（Linux: systemctl start docker；macOS: 打开 Docker Desktop）"
  fi
  cv=$(docker compose version --short 2>&1 || true)
  # Compose v2 plugin or newer (v2.x, 5.x, ...); v1 (docker-compose) lacks the plugin form
  local cv_major="${cv#v}"
  cv_major="${cv_major%%.*}"
  case "$cv_major" in
    ''|*[!0-9]*) cv_major=0 ;;
  esac
  if [ "$cv_major" -lt 2 ]; then
    die "需要 Docker Compose v2（当前：${cv:-未检出}）——请安装 docker-compose-plugin：https://docs.docker.com/compose/migrate/"
  fi
  log "Docker 可用，Compose 版本：$cv"
}

check_ports() {
  local p holder
  for p in "${HOST_PORTS[@]}"; do
    if port_busy "$p"; then
      holder=$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null \
        | grep ":$p->" | head -1 | cut -d' ' -f1 || true)
      if printf '%s' "$holder" | grep -q '^banyanos-gateway'; then
        log "端口 $p 被本部署容器（$holder）占用——重复运行场景，继续"
      elif [ -n "$holder" ]; then
        die "端口 $p 被其他容器（$holder）占用——请停止该容器或调整端口映射"
      else
        die "端口 $p 被宿主机进程占用——排查：lsof -i :$p 或 ss -ltnp | grep :$p"
      fi
    fi
  done
  log "端口预检通过：${HOST_PORTS[*]}"
}

# ---------------------------------------------------------------------------
# Stage 7: health and logs
# ---------------------------------------------------------------------------

wait_healthy() {
  local deadline now all_ok st c line
  deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  log "等待容器健康（最长 ${WAIT_TIMEOUT}s；pip dependencies are installed during image build）"
  while :; do
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      printf '%s\n' '── gateway 最近日志（docker logs --tail 60）──' >&2
      docker logs --tail 60 banyanos-gateway 2>&1 || true
      die "健康检查超时（${WAIT_TIMEOUT}s）。可用 GATEWAY_WAIT_TIMEOUT 环境变量延长等待"
    fi
    all_ok=1
    line=""
    for c in banyanos-postgres banyanos-neo4j \
      banyanos-redis banyanos-gateway; do
      st=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || true)
      line="$line ${c#banyanos-gateway-}=${st:-none}"
      if [ "$st" != "healthy" ]; then
        all_ok=0
      fi
    done
    if [ "$all_ok" = "1" ]; then
      log "全部容器健康：$line"
      return 0
    fi
    printf '  等待中（剩余 %ss）：%s\n' "$(( deadline - now ))" "$line"
    sleep 5
  done
}

verify_gateway() {
  local out
  if ! out=$(dc exec -T gateway python -c \
    "import urllib.request; r=urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=10); print('health=' + str(r.status))" 2>&1); then
    die "网关 /health 探活失败（容器内 urllib）"
  fi
  log "网关探活：$out"
}

# $1 = required (missing fails the deploy) | info (status only warns)
# Scan the full container log rather than a tail window: startup logs can run to hundreds of lines (incl. engine
# migration tracebacks), and a fixed tail window pushes the two early startup markers out of view (hit in practice);
# "container currently healthy" is already ensured by wait_healthy first, so a full scan won't pass a crash loop.
check_log() {
  local logs miss=() pat
  logs=$(docker logs banyanos-gateway 2>&1 || true)
  # herestring instead of a pipe: under pipefail, grep -q exiting on first match makes the upstream printf take SIGPIPE
  # (141 → if! evaluates true → false 'missing' report); always triggers once startup logs exceed the 64KB pipe buffer (hit in practice)
  for pat in "${REQUIRED_LOGS[@]}"; do
    if ! grep -qF "$pat" <<< "$logs"; then
      miss+=("$pat")
    fi
  done
  if [ "${#miss[@]}" -gt 0 ]; then
    for pat in "${miss[@]}"; do
      printf '[deploy.sh] 缺失关键日志：%s\n' "$pat" >&2
    done
    if [ "$1" = "required" ]; then
      die "网关启动关键日志缺失——JSON 配置加载或池引导未生效；完整日志：docker logs banyanos-gateway"
    fi
  fi
  for pat in "${OPTIONAL_LOGS[@]}"; do
    if ! grep -qE "$pat" <<< "$logs"; then
      printf '[deploy.sh] 提示：可选日志缺失（%s）——池回环改写未发生，非预期时请检查挂载路径与 BANYAN_LOOPBACK_BASE_URL\n' "$pat" >&2
    fi
  done
}

# ---------------------------------------------------------------------------
# Stage 8: summary
# ---------------------------------------------------------------------------

print_summary() {
  cat <<EOF

============================================================
 SilvaEngine Gateway（Banyan 数据面）部署完成
============================================================
  网关地址      : http://<服务器IP>:${GATEWAY_HOST_PORT}  （本机探活 curl http://127.0.0.1:${GATEWAY_HOST_PORT}/health）
  GraphQL 入口  : POST http://<服务器IP>:${GATEWAY_HOST_PORT}/beta/core/banyan/<engine>_engine_graphql
  租户 part_id  : ${TENANT_PART_ID}
  生成文件      : .env（数据面密码，600 权限，勿提交）
                  env/se-configdata.local.json（JWT/x-api-key 等，600 权限，勿提交）
  数据面        : postgres / neo4j / redis; configuration: env/se-configdata.local.json

验证步骤（README §5 六步验收）：
  curl -sS http://127.0.0.1:${GATEWAY_HOST_PORT}/health
  # 登录 mutation 骨架（携带 part_id 头 + Banyan JWT）：
  # curl -sS -X POST http://127.0.0.1:${GATEWAY_HOST_PORT}/beta/core/banyan/user_engine_graphql \\
  #   -H 'content-type: application/json' -H 'part_id: ${TENANT_PART_ID}' \\
  #   -d '{"query": "mutation { ... }"}'
  # 12 引擎 pytest 在开发机 banyan 仓执行（服务器无 Python）

常用操作：
  bash deploy.sh status          # 状态/健康/关键日志
  bash deploy.sh down            # 停止（数据卷保留）
  bash deploy.sh down -v         # 停止并删除数据卷
  bash deploy.sh --restart       # 改源码/种子 JSON 后重启网关
  bash deploy.sh --force-env     # 重新生成全部密码
  # 跟踪日志（三文件 Overlay）：
  # docker compose logs -f gateway

安全提醒：公网防火墙只放行 ${GATEWAY_HOST_PORT}；其余配置的宿主机端口仅供本机调试。
============================================================
EOF
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_up() {
  set_stage 1 "环境检测（Docker / Compose v2）" \
    "安装 Docker：https://docs.docker.com/engine/install/；权限：sudo usermod -aG docker \$(id -un) 后重新登录；Compose v2：安装 docker-compose-plugin"
  check_docker

  set_stage 2 "配置生成与源码树校验" \
    "源路径可用环境变量覆盖（bash deploy.sh -h 查看清单）；.env 改动后重跑即生效；--force-env 重新生成"
  ensure_config
  if [ "$BUMP" = "1" ]; then
    log "--bump：把 requirements-silvaengine.txt 的 SilvaEngine pin 切换并升到 $BUMP_BRANCH 分支最新提交"
    bump_args=(--branch "$BUMP_BRANCH")
    [ "$DRY_RUN" = "1" ] && bump_args+=(--dry-run)
    bash "$DEPLOY_DIR/scripts/bump_silvaengine.sh" ${bump_args[@]+"${bump_args[@]}"} \
      || die "SilvaEngine pin 更新失败（requirements 未改动）；检查 GitHub SSH 访问后重跑，或去掉 --bump 按现有 pin 部署"
  fi

  set_stage 3 "端口预检（${HOST_PORTS[*]}）" \
    "占用排查：lsof -i :<port>（macOS）/ ss -ltnp | grep :<port>（Linux）"
  check_ports

  if [ "$DRY_RUN" = "1" ]; then
    log "--dry-run 完成：环境/配置/端口全部通过，未启动任何容器"
    return 0
  fi

  set_stage 4 "Build gateway image" "Check pip index and GitHub SSH key configuration"
  dc build gateway

  set_stage 5 "Validate env/se-configdata.local.json" "Fix invalid JSON or unresolved placeholders in the configuration file"
  dc run --rm --no-deps --entrypoint python gateway -c \
    'from scripts.json_settings import load_json_settings; load_json_settings("/app/env/se-configdata.local.json"); print("JSON configuration validated")'

  set_stage 6 "Start gateway and application data services" "Check container logs"
  dc up -d "${UP_SERVICES[@]}"
  if [ "$RESTART" = "1" ]; then
    log "--restart：重启 gateway"
    dc restart gateway
  fi

  set_stage 7 "健康检查与启动验证" \
    "看报错：docker logs banyanos-gateway；可用 GATEWAY_WAIT_TIMEOUT=900 bash deploy.sh 延长等待"
  wait_healthy
  verify_gateway
  check_log required

  set_stage 8 "输出摘要" ""
  print_summary
}

cmd_status() {
  if [ ! -f "$ENV_FILE" ]; then
    die "未找到 .env——请先运行 bash deploy.sh 完成部署"
  fi
  set_stage S "状态检查" "docker compose ... ps -a 查看全部容器"
  dc ps
  local bad=0 c st
  for c in banyanos-postgres banyanos-neo4j \
    banyanos-redis banyanos-gateway; do
    st=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || true)
    printf '  %-34s %s\n' "$c" "${st:-未运行}"
    if [ "$st" != "healthy" ]; then
      bad=1
    fi
  done
  check_log info
  if [ "$bad" = "1" ]; then
    log "存在未健康/未运行的容器（上方状态）"
    exit 1
  fi
  log "全部容器健康"
}

cmd_down() {
  if [ ! -f "$ENV_FILE" ]; then
    die "未找到 .env——如需清理残留容器/卷，请手工执行 docker compose down（三 -f 文件见 README §8.2）"
  fi
  set_stage D "停止并清理" "compose down 失败时可先 docker ps 查看占用"
  if [ "$VOLUMES" = "1" ]; then
    dc down -v
    log "已停止全部容器并删除数据卷（postgres/neo4j/redis 数据已清空）"
  else
    dc down
    log "已停止全部容器（数据卷保留；彻底清理：bash deploy.sh down -v）"
  fi
}

# ---------------------------------------------------------------------------
# Self-test (pure logic, no docker; runs generation/rendering in a mktemp directory)
# ---------------------------------------------------------------------------

cmd_self_test() {
  local tmp
  tmp=$(mktemp -d) || return 1
  local saved_env="$ENV_FILE" saved_seed="$SEED_JSON"
  local pass=0 fail=0

  expect_eq() {
    local desc="${1:-}" actual="${2:-}" expected="${3:-}"
    if [ "$actual" = "$expected" ]; then
      printf '  PASS: %s\n' "$desc"
      pass=$((pass + 1))
    else
      printf '  FAIL: %s —— 期望 [%s] 实际 [%s]\n' "$desc" "$expected" "$actual"
      fail=$((fail + 1))
    fi
  }

  ENV_FILE="$tmp/.env"
  SEED_JSON="$tmp/se-configdata.local.json"

  # rand_alnum
  local r1 r2
  r1=$(rand_alnum 16)
  r2=$(rand_alnum 16)
  expect_eq "rand_alnum 长度 16" "${#r1}" "16"
  expect_eq "rand_alnum 纯字母数字" \
    "$(printf '%s' "$r1" | grep -c '^[A-Za-z0-9]*$' || true)" "1"
  expect_eq "rand_alnum 两次不同" "$([ "$r1" != "$r2" ] && echo 1 || true)" "1"

  # sed_escape
  expect_eq "sed_escape 转义 \\ / &" "$(sed_escape 'a/b\c&d')" 'a\/b\\c\&d'

  # env_get (temporarily switch to a separate .env, then switch back)
  local saved_env2="$ENV_FILE"
  ENV_FILE="$tmp/envget"
  printf 'K1="va lue"\nK2=plain\n' > "$ENV_FILE"
  expect_eq "env_get 剥双引号" "$(env_get K1)" "va lue"
  expect_eq "env_get 普通值" "$(env_get K2)" "plain"
  expect_eq "env_get 缺失为空" "$(env_get K3)" ""
  ENV_FILE="$saved_env2"

  # generate_env → .env assertions
  generate_env
  local pw_check
  pw_check=$(env_get POSTGRES_PASSWORD)
  expect_eq "GATEWAY_IMAGE local build" "$(env_get GATEWAY_IMAGE)" "banyanos-gateway:local"
  expect_eq "Configuration source JSON" "$(env_get SETTING_SOURCE)" "json"
  expect_eq "Application backend configured" "$(env_get db_backend)" "${db_backend:-postgresql}"
  expect_eq "POSTGRES_PASSWORD 16 位" "${#pw_check}" "16"
  expect_eq "POSTGRES_PASSWORD 纯字母数字" \
    "$(printf '%s' "$pw_check" | grep -c '^[A-Za-z0-9]*$' || true)" "1"
  expect_eq "NEO4J_AUTH 形态 neo4j/<16>" \
    "$(env_get NEO4J_AUTH | grep -c '^neo4j/[A-Za-z0-9]\{16\}$' || true)" "1"
  expect_eq "AWS 假凭据已写入" "$(env_get aws_access_key_id)" "local"
    expect_eq "SSH key path configured" "$(env_get SSH_PRIVATE_KEY_FILE)" "${SSH_PRIVATE_KEY_FILE:-./.ssh/id_ed25519}"
  if [ -z "${TENANT_PART_ID:-}" ]; then
    expect_eq "TENANT_PART_ID 默认 nestaging" "$(env_get TENANT_PART_ID)" "nestaging"
  fi
  local env_mode
  if ! env_mode=$(stat -c '%a' "$ENV_FILE" 2>/dev/null); then
    env_mode=$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || true)
  fi
  expect_eq ".env 权限 600" "$env_mode" "600"

  # load_env_values read-back
  load_env_values
  expect_eq "load_env_values 回读 PG 密码一致" "$PG_PASSWORD" "$(env_get POSTGRES_PASSWORD)"
  expect_eq "NEO4J_PASSWORD 解析 16 位" "${#NEO4J_PASSWORD}" "16"

  # render_seed_json (using the real template in the repo)
  render_seed_json
  expect_eq "种子 JSON 无残留占位符" "$(grep -c '<[A-Z][A-Z0-9_]*>' "$SEED_JSON" || true)" "0"
  expect_eq "种子 JSON 无 _comment" "$(grep -c '_comment' "$SEED_JSON" || true)" "0"
  expect_eq "种子 JSON 注入 PG 库名（3 处池）" \
    "$(grep -c "\"database\": \"$(env_get POSTGRES_DB)\"" "$SEED_JSON" || true)" "3"
  expect_eq "种子 JSON 注入 PG 密码（3 处池）" \
    "$(grep -c "\"password\": \"$(env_get POSTGRES_PASSWORD)\"" "$SEED_JSON" || true)" "3"
  expect_eq "种子 JSON initialize_tables 保留" \
    "$(grep -c 'initialize_tables": true' "$SEED_JSON" || true)" "1"
  expect_eq "种子 JSON part_id 已注入" \
    "$(grep -c "\"part_id\": \"$(env_get TENANT_PART_ID)\"" "$SEED_JSON" || true)" "1"

  # port_busy free-port check
  local free_p="" p
  for p in 39201 39211 39221 39231 39241 39251 39261 39271 39281 39291; do
    if ! port_busy "$p"; then
      free_p="$p"
      break
    fi
  done
  if [ -n "$free_p" ]; then
    if port_busy "$free_p"; then
      expect_eq "port_busy 空闲端口($free_p)判定非忙" "busy" "free"
    else
      expect_eq "port_busy 空闲端口($free_p)判定非忙" "free" "free"
    fi
  else
    printf '  （跳过 port_busy 测试：未找到空闲端口）\n'
  fi

  ENV_FILE="$saved_env"
  SEED_JSON="$saved_seed"
  rm -rf "$tmp"

  if [ "$fail" -gt 0 ]; then
    printf 'self-test FAILED（%s/%s 通过）\n' "$pass" "$((pass + fail))"
    return 1
  fi
  printf 'self-test OK（%s/%s 全部通过）\n' "$pass" "$pass"
  return 0
}

# ---------------------------------------------------------------------------
# Argument parsing and dispatch
# ---------------------------------------------------------------------------

for arg in "$@"; do
  case "$arg" in
    up|deploy) MODE="up" ;;
    status) MODE="status" ;;
    down) MODE="down" ;;
    --volumes|-v) VOLUMES=1 ;;
    --restart) RESTART=1 ;;
    --bump) BUMP=1; BUMP_BRANCH="main" ;;
    --bump=main|--bump=dev|--bump=staging) BUMP=1; BUMP_BRANCH="${arg#--bump=}" ;;
    --bump=*)
      printf '错误：--bump 仅支持 main/dev/staging（其他分支请直接运行 scripts/bump_silvaengine.sh --branch NAME）\n' >&2
      exit 1
      ;;
    --force-env) FORCE_ENV=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --self-test) MODE="selftest" ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf '未知参数：%s\n' "$arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$MODE" != "down" ] && [ "$VOLUMES" = "1" ]; then
  printf '错误：-v/--volumes 仅可与 down 组合\n' >&2
  exit 1
fi

log "SilvaEngine Gateway 一键部署（JSON configuration）"

case "$MODE" in
  selftest)
    if cmd_self_test; then exit 0; else exit 1; fi
    ;;
  status) cmd_status ;;
  down) cmd_down ;;
  up) cmd_up ;;
esac
