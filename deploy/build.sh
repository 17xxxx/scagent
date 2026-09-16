#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  deploy/build.sh —— 本机构建镜像（Linux / WSL；Windows 用 deploy\scagent.cmd build）
#
#  为什么需要它：构建必须**分两步串行** —— compose 会并行构建各服务，而
#  seurat 层的 `FROM ${RUNTIME}` 在 runtime 镜像尚不存在时会去 Docker Hub 解析
#  （必然失败）。depends_on 只约束 up 的顺序，不约束并行 build。
#
#  用法：
#      ./deploy/build.sh              # runtime 已存在则跳过，只重建应用层
#      ./deploy/build.sh --force      # 连 runtime 一起重建
#      ./deploy/build.sh --no-cache   # 完全不复用构建缓存（等于"新用户首次构建"，30–90 分钟）
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
info() { printf '\n%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '  %s\n' "${C_G}✅${C_0} $*"; }
warn() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; }
die()  { printf '  %s\n' "${C_R}❌${C_0} $*" >&2; exit 1; }

FORCE=0; NO_CACHE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force)    FORCE=1 ;;
    --no-cache) NO_CACHE=1 ;;
    -h|--help)  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '未知参数：%s（可用：--force --no-cache）\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

BUILD_OPTS=()
[ "$NO_CACHE" -eq 1 ] && { BUILD_OPTS+=(--no-cache); FORCE=1; }

# apt 镜像源（可选）：来自环境变量或 deploy/.env 的 APT_MIRROR
if [ -n "${APT_MIRROR:-}" ]; then
  BUILD_OPTS+=(--build-arg "APT_MIRROR=${APT_MIRROR}")
  printf '      （apt 镜像源：%s）\n' "$APT_MIRROR"
fi

# shellcheck source=lib/image-source.sh
. "$ROOT/deploy/lib/image-source.sh"

# build 属于"配置前"操作：没有 deploy/.env 也能用默认值构建
if [ -f deploy/.env ]; then
  scagent_load_env deploy/.env
else
  warn "未找到 deploy/.env —— 使用默认值：SCAGENT_IMAGE_SOURCE=local、前缀 scagent、版本 1.0.0"
  printf '      （要自定义镜像来源/版本，请先运行 ./deploy/configure.sh，或手动创建 deploy/.env）\n'
  SCAGENT_IMAGE_SOURCE="${SCAGENT_IMAGE_SOURCE:-local}"
  SCAGENT_VERSION="${SCAGENT_VERSION:-1.0.0}"
fi
scagent_resolve_image

BUILD_FILE=deploy/docker-compose.build.yml
RUNTIME_IMG="$(scagent_image runtime)"

info "构建 R 运行时层（≈10 GB，首次 30–90 分钟）：$RUNTIME_IMG"
if [ "$FORCE" -eq 0 ] && docker image inspect "$RUNTIME_IMG" >/dev/null 2>&1; then
  ok "已存在，跳过（需要重建加 --force）"
else
  if ! docker compose -f "$BUILD_FILE" build "${BUILD_OPTS[@]}" runtime; then
    warn "运行时层构建失败。常见原因与对策："
    printf '      · 拉基础镜像被拦 → 配 registry mirror（scripts/setup-network.sh 或 Docker Desktop → Docker Engine）\n'
    printf '      · apt 报退出码 100 / 卡在 Get:InRelease → 换国内 apt 源后重试：\n'
    printf '          APT_MIRROR=https://mirrors.aliyun.com/ubuntu ./deploy/build.sh --force\n'
    printf '      · R 包拉取慢或超时 → 设置 PPM_CRAN / CRAN_FALLBACK / BIOC_ROOT（见 Dockerfile.runtime 默认值）\n'
    printf '      · 磁盘不足（该层约 10 GB）→ 清理空间或调整 Docker Desktop 的资源上限\n'
    printf '      · 只想用现成镜像 → 把 SCAGENT_IMAGE_SOURCE 改为 public/private（见 deploy/.env.sample）\n'
    exit 3
  fi
fi

info "构建应用层（只 COPY 代码）"
if ! docker compose -f "$BUILD_FILE" build "${BUILD_OPTS[@]}" seurat agent; then
  warn "应用层构建失败；若提示找不到 runtime 镜像，请用 --force 重建运行时层"
  exit 3
fi

ok "镜像构建完成"
printf '    下一步： ./deploy/up.sh\n'
