#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/dev_build.sh —— 构建本地开发镜像（处理分层顺序）
#
#  为什么需要这个脚本：
#    seurat_backend/Dockerfile 现在是**应用层**（FROM scagent-runtime），
#    所以必须先构建 runtime，再构建应用层。直接 `docker compose build` 会因为
#    scagent-runtime:dev 尚不存在而失败。
#
#  用法：
#      ./scripts/dev_build.sh                 # 首次：构建 runtime + 应用层
#      ./scripts/dev_build.sh --app-only      # 只重建应用层（改过 R/Python 代码后）
#      ./scripts/dev_build.sh --runtime-only  # 只重建 runtime（升级 R 包时）
#
#  首次构建约 30–90 分钟（要装 108 个 R 包）。之后改代码只走应用层，数秒完成。
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
info() { printf '\n%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '  %s\n' "${C_G}✅${C_0} $*"; }
warn() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; }
die()  { printf '  %s\n' "${C_R}❌${C_0} $*" >&2; exit 1; }

RUNTIME_IMAGE="${RUNTIME_IMAGE:-scagent-runtime:dev}"
DO_RUNTIME=1
DO_APP=1

for arg in "$@"; do
  case "$arg" in
    --app-only)     DO_RUNTIME=0 ;;
    --runtime-only) DO_APP=0 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $arg" ;;
  esac
done

# ── 前置检查 ──────────────────────────────────────────────────────────────────
mkdir -p .biodata

info "[0/3] 环境检查"
if ! command -v docker >/dev/null 2>&1; then
  die "未找到 docker 命令。
      Windows/WSL 用户：请在 Docker Desktop → Settings → Resources → WSL Integration
      中勾选当前发行版，然后重开终端。"
fi
if ! docker info >/dev/null 2>&1; then
  die "Docker 守护进程不可用。可能原因：
      · Windows/WSL：Docker Desktop 未启动，或未开启 WSL Integration
      · Linux   ：sudo systemctl start docker（当前用户还需在 docker 组）
      验证： docker ps"
fi
ok "Docker 可用: $(docker --version | awk '{print $3}' | tr -d ,)"

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  die "缺少 docker compose 插件（需要 v2）"
fi
ok "$(docker compose version | head -1)"

# 基础镜像在国内需要镜像加速，否则拉取会超时
if [ -f scripts/setup-network.sh ]; then
  warn "若拉取基础镜像超时，先运行: ./scripts/setup-network.sh"
fi

# ── 1. R 运行时 ───────────────────────────────────────────────────────────────
if [ "$DO_RUNTIME" -eq 1 ]; then
  if docker image inspect "$RUNTIME_IMAGE" >/dev/null 2>&1; then
    info "[1/3] R 运行时已存在（$RUNTIME_IMAGE），跳过构建"
    ok "如需重建请执行: ./scripts/dev_build.sh --runtime-only"
  else
    info "[1/3] 构建 R 运行时 $RUNTIME_IMAGE"
    warn "这一步会安装 108 个 R 包，首次约 30–90 分钟，请耐心等待"
    docker build \
      --build-arg PPM_CRAN="${PPM_CRAN:-https://packagemanager.posit.co/cran/__linux__/jammy/latest}" \
      --build-arg PPM_BIOC="${PPM_BIOC:-https://packagemanager.posit.co/bioconductor/__linux__/jammy/latest}" \
      -f seurat_backend/Dockerfile.runtime \
      -t "$RUNTIME_IMAGE" .
    ok "runtime 构建完成"
  fi
else
  info "[1/3] 跳过 runtime"
fi

if [ "$DO_APP" -eq 0 ]; then
  info "[2/3] --runtime-only，结束"
  exit 0
fi

# ── 2. 应用层 ─────────────────────────────────────────────────────────────────
info "[2/3] 构建应用层（只 COPY 代码，很快）"
docker compose -f .devcontainer/docker-compose.yml build seurat agent
ok "应用层构建完成"

# ── 3. 提示下一步 ─────────────────────────────────────────────────────────────
info "[3/3] 完成"
printf '    启动:  docker compose -f .devcontainer/docker-compose.yml up -d\n'
printf '    验证:  docker compose -f .devcontainer/docker-compose.yml exec seurat \\\n'
printf '               Rscript -e "jsonlite::toJSON(jsonlite::fromJSON(\\"http://127.0.0.1:9000/api/ping\\"))"\n'
printf '    跑分析: docker compose -f .devcontainer/docker-compose.yml exec agent \\\n'
printf '               python /workspace/agent_core/pipeline_cli.py run --steps qc,pca,snn,anno\n'
