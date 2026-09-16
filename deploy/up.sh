#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  deploy/up.sh —— 启动/更新 scAgent 服务（单机 / 服务器）
#
#  这是部署机上**唯一允许发起网络请求**的动作，且只允许访问 .env 指定的镜像来源。
#  设计依据：镜像名只有一个来源（SCAGENT_IMAGE_PREFIX），绝不静默回落公网
#    · local    本机 build 产物，强制不拉取（never）
#    · public   公开发布（如 ghcr.io/...）
#    · private  自有 registry
#    · 三种来源都显式拒绝 docker.io / index.docker.io / registry-1.docker.io 命名空间
#    · 解析逻辑集中在 deploy/lib/image-source.sh，本脚本不再自行拼镜像名
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
# shellcheck source=lib/image-source.sh
. "$ROOT/deploy/lib/image-source.sh"
scagent_load_env deploy/.env          # 去 CR 后再 source（Windows 编辑器写入的 .env 带 \r 会让鉴权 401）

: "${SCAGENT_VERSION:?deploy/.env 中未设置 SCAGENT_VERSION}"

# ── 密钥方式自动判定 ─────────────────────────────────────────────────────────
#   优先 Docker secrets（与开发环境完全一致）；缺失时回退到 deploy/.env 环境变量。
SECRETS_DIR="$(scagent_resolve_path "${SCAGENT_SECRETS_DIR:-./secrets}")"
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

# ── 2. 镜像来源解析 + 公网回落防护 ────────────────────────────────────────────
#   唯一拼接规则：<SCAGENT_IMAGE_PREFIX>/scagent-<svc>:<SCAGENT_VERSION>（A4）
info "解析镜像来源"
scagent_resolve_image
ok "来源: $SCAGENT_IMAGE_SOURCE   前缀: $SCAGENT_IMAGE_PREFIX   版本: $SCAGENT_VERSION"
ok "拉取策略: $SCAGENT_PULL_POLICY"
SEURAT_IMG="$(scagent_image seurat)"
AGENT_IMG="$(scagent_image agent)"

if [ "$SCAGENT_PULL_POLICY" = "never" ]; then
  missing=""
  for img in "$SEURAT_IMG" "$AGENT_IMG"; do
    docker image inspect "$img" >/dev/null 2>&1 || missing="$missing $img"
  done
  if [ -n "$missing" ]; then
    die "本地缺少镜像：$missing
      local 模式不会联网拉取。请二选一：
        · 先构建（注意两步顺序，否则应用层会去 Docker Hub 找 runtime 镜像而失败）：
            docker compose -f deploy/docker-compose.build.yml build runtime
            docker compose -f deploy/docker-compose.build.yml build seurat agent
          Windows 用户可直接： deploy\\scagent.cmd build
        · 或改用发布镜像：把 deploy/.env 的 SCAGENT_IMAGE_SOURCE 改成 public"
  fi
  ok "本地镜像已就绪（不联网拉取）"
fi

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

WORKSPACE="$(scagent_resolve_path "${SCAGENT_WORKSPACE:?deploy/.env 中未设置 SCAGENT_WORKSPACE}")"
mkdir -p "$WORKSPACE/data/rawdata" "$WORKSPACE/state"
ok "工作目录: $WORKSPACE"

BIODATA="$(scagent_resolve_path "${SCAGENT_BIODATA:?deploy/.env 中未设置 SCAGENT_BIODATA}")"
if [ -d "$BIODATA" ]; then
  ok "参考数据目录: $BIODATA"
else
  warn "参考数据目录不存在: $BIODATA"
  warn "  细胞注释（Step 4）会失败。一次性获取（需要外网）: ./scripts/fetch_refdata.sh"
  warn "  （离线环境或有自建对象存储时: scripts/download_data.sh --target $BIODATA）"
fi

# ── 4. 保留当前版本镜像（供 rollback.sh 回滚）────────────────────────────────
info "保留当前版本标签 :prev（供回滚）"
for svc in runtime seurat agent; do
  cur="$(scagent_image "$svc")"
  if docker image inspect "$cur" >/dev/null 2>&1; then
    if ! docker tag "$cur" "${SCAGENT_IMAGE_PREFIX}/scagent-${svc}:prev" 2>/dev/null; then
      warn "打 :prev 标签失败（不影响本次启动，但 rollback 会不可用）: $cur"
      continue
    fi
    ok "$svc → :prev"
  else
    warn "$svc 镜像不在本地，跳过 :prev: $cur"
  fi
done

# ── 5. 拉取并启动 ─────────────────────────────────────────────────────────────
COMPOSE=(docker compose "${COMPOSE_FILES[@]}")
if [ "$SCAGENT_PULL_POLICY" = "never" ]; then
  info "跳过拉取（local 模式，使用本地镜像）"
else
  info "拉取镜像（唯一联网动作）：$SCAGENT_IMAGE_PREFIX"
  "${COMPOSE[@]}" pull
fi

info "启动服务"
# --pull 显式传参，不依赖 compose 对 pull_policy 的插值行为
"${COMPOSE[@]}" up -d --force-recreate --pull "$SCAGENT_PULL_POLICY"

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
case "${SCAGENT_BIND_ADDR:-127.0.0.1}" in
  127.0.0.1) printf '    访问地址: http://127.0.0.1:%s  （仅本机）\n' "$PORT" ;;
  *)         printf '    访问地址: http://<本机IP>:%s  （局域网；请确认防火墙已放行）\n' "$PORT" ;;
esac
printf '    下一步  : 把 10X 数据放入 %s/data/rawdata/<样本名>/\n' "$WORKSPACE"
printf '    使用    : 浏览器打开上面的地址，或 client/scagent.py ask "帮我做质控"\n'
