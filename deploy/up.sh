#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  deploy/up.sh —— 启动/更新 scAgent 服务（服务器侧）
#
#  这是服务器上**唯一允许发起网络请求**的动作，且只允许访问私有 registry。
#  设计依据：docs/VENDORING_AUDIT.md §3.1
#    · 强制要求 SCAGENT_REGISTRY，缺失即报错 —— 绝不静默回落公网 Docker Hub
#    · 显式拒绝 docker.io / index.docker.io / registry-1.docker.io
#    · 拉取动作集中在此处，docker-compose.yml 里用 pull_policy: never
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
info() { printf '%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '%s\n' "  ${C_G}✅${C_0} $*"; }
warn() { printf '%s\n' "  ${C_Y}⚠️ ${C_0} $*"; }
die()  { printf '%s\n' "  ${C_R}❌${C_0} $*" >&2; exit 1; }

# ── 1. 载入配置 ───────────────────────────────────────────────────────────────
[ -f deploy/.env ] || die "缺少 deploy/.env。请先：cp deploy/.env.sample deploy/.env && chmod 600 deploy/.env && vi deploy/.env"
set -a
# shellcheck disable=SC1091
. deploy/.env
set +a

: "${SCAGENT_REGISTRY:?deploy/.env 中未设置 SCAGENT_REGISTRY}"
: "${SCAGENT_VERSION:?deploy/.env 中未设置 SCAGENT_VERSION}"

# ── 密钥方式自动判定 ─────────────────────────────────────────────────────────
#   优先 Docker secrets（与开发环境完全一致）；缺失时回退到 deploy/.env 环境变量。
SECRETS_DIR_RAW="${SCAGENT_SECRETS_DIR:-./secrets}"
case "$SECRETS_DIR_RAW" in
  /*) SECRETS_DIR="$SECRETS_DIR_RAW" ;;
  *)  SECRETS_DIR="$ROOT/${SECRETS_DIR_RAW#./}" ;;
esac
COMPOSE_FILES=(-f deploy/docker-compose.yml)

if [ -f "$SECRETS_DIR/deepseek_api_key" ] && [ -f "$SECRETS_DIR/scagent_token" ]; then
  export SCAGENT_SECRETS_DIR="$SECRETS_DIR"
  COMPOSE_FILES+=(-f deploy/docker-compose.secrets.yml)
  USE_SECRETS=1
  # verify.sh 在宿主机上跑，需要宿主侧的令牌副本
  SCAGENT_TOKEN="$(cat "$SECRETS_DIR/scagent_token")"
  export SCAGENT_TOKEN
else
  USE_SECRETS=0
  : "${SCAGENT_TOKEN:?未找到密钥。二选一：
      · Docker secrets： 在 $SECRETS_DIR/ 下放置 deepseek_api_key 与 scagent_token
        （推荐，与开发环境一致；可运行 ./scripts/setup_secrets.sh --target $SECRETS_DIR）
      · 环境变量：       在 deploy/.env 中设置 SCAGENT_TOKEN}"
fi

if [ "$USE_SECRETS" -eq 1 ]; then
  ok "密钥方式：Docker secrets（$SECRETS_DIR）"
else
  ok "密钥方式：环境变量（deploy/.env）"
fi

# ── 2. 公网 registry 白名单校验（防止偷偷摸公网）──────────────────────────────
info "校验 registry 地址"
case "$SCAGENT_REGISTRY" in
  docker.io*|*.docker.io*|registry-1.docker.io*|index.docker.io*|scagent|scagent/*|library/*)
    die "拒绝从公网 registry 拉取: $SCAGENT_REGISTRY
    服务器必须只从私有 registry 取镜像。请把它改成内网地址，例如 harbor.corp.local/scagent" ;;
esac
case "$SCAGENT_REGISTRY" in
  *.*|*:*|localhost*) ;;                       # 含点/冒号，像一个真实主机名
  *) die "SCAGENT_REGISTRY 看起来不是合法的主机名: $SCAGENT_REGISTRY" ;;
esac
ok "私有 registry: $SCAGENT_REGISTRY  (版本 $SCAGENT_VERSION)"

# ── 2.5 密钥可读性预检 ────────────────────────────────────────────────────────
#  Docker Compose 的 file 型 secret 底层是 bind mount：容器能否读取由
#  宿主机文件的【属主 + 权限 + SELinux 标签】共同决定，而 services.secrets 的
#  uid/gid/mode 属性不被支持。这里提前检查，避免 agent 起来后才发现读不到。
if [ -x scripts/check_secrets.sh ] || [ -f scripts/check_secrets.sh ]; then
  info "密钥可读性预检"
  if ! bash scripts/check_secrets.sh --prod 2>&1 | sed 's/^/  /'; then
    warn "预检未全部通过 —— 若 agent 启动失败，请优先按上面的提示处理"
    printf '  继续启动？[y/N] '
    read -r _ans
    case "$_ans" in y|Y|yes|YES) ;; *) die "已按用户要求中止" ;; esac
  fi
fi

# ── 3. 检查 compose 文件与工作目录 ────────────────────────────────────────────
for f in deploy/docker-compose.yml; do
  [ -f "$f" ] || die "缺少 $f"
done

# 相对路径统一以 deploy/ 为基准（与 docker compose 的解析规则一致）
resolve_workspace() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s' "$ROOT/deploy/$1" ;;
  esac
}

WORKSPACE="$(resolve_workspace "${SCAGENT_WORKSPACE:-../workspace}")"
mkdir -p "$WORKSPACE/data/rawdata" "$WORKSPACE/state"
ok "工作目录: $WORKSPACE"

BIODATA="${SCAGENT_BIODATA:-/data/biodata}"
if [ -d "$BIODATA" ]; then
  ok "参考数据目录: $BIODATA"
else
  warn "参考数据目录不存在: $BIODATA"
  warn "  细胞注释（Step 4）会失败。请先执行: scripts/download_data.sh --target $BIODATA"
fi

# ── 4. 保留当前版本镜像（供 rollback.sh 回滚）────────────────────────────────
info "保留当前版本标签 :prev（供回滚）"
for svc in scagent-runtime scagent-seurat scagent-agent; do
  cur="${SCAGENT_REGISTRY}/bio/${svc}:${SCAGENT_VERSION}"
  if docker image inspect "$cur" >/dev/null 2>&1; then
    docker tag "$cur" "${SCAGENT_REGISTRY}/bio/${svc}:prev" 2>/dev/null || true
    ok "$svc → :prev"
  fi
done

# ── 5. 拉取并启动 ─────────────────────────────────────────────────────────────
COMPOSE=(docker compose "${COMPOSE_FILES[@]}")
info "从私有 registry 拉取镜像（服务器唯一联网动作）"
"${COMPOSE[@]}" pull

info "启动服务"
"${COMPOSE[@]}" up -d --force-recreate

info "等待健康检查通过（seurat 冷启动约需 120 秒）"
for i in $(seq 1 60); do
  unhealthy=$("${COMPOSE[@]}" ps --format json 2>/dev/null \
    | grep -o '"Health":"[a-z]*"' | grep -cv '"healthy"' || true)
  total=$("${COMPOSE[@]}" ps -q 2>/dev/null | wc -l)
  if [ "${unhealthy:-1}" -eq 0 ] && [ "${total:-0}" -ge 2 ]; then
    ok "全部容器健康"
    break
  fi
  printf '\r  ... 等待中 (%d/60)  ' "$i"
  sleep 5
done
printf '\n'

"${COMPOSE[@]}" ps

# ── 6. 端到端自检 ─────────────────────────────────────────────────────────────
info "端到端自检"
if [ -x deploy/verify.sh ] || [ -f deploy/verify.sh ]; then
  bash deploy/verify.sh || warn "自检未全部通过，请查看上面的输出"
else
  warn "未找到 deploy/verify.sh，跳过自检"
fi

PORT="${SCAGENT_PORT:-8080}"
printf '\n%s\n' "────────────────────────────────────────────────────────────"
ok "部署完成"
printf '    访问地址: http://<服务器IP>:%s\n' "$PORT"
printf '    下一步  : 把 10X 数据放入 %s/data/rawdata/<样本名>/\n' "$WORKSPACE"
printf '    使用    : 浏览器打开上面的地址，或 client/scagent.py ask "帮我做质控"\n'
