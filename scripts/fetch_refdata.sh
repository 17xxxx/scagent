#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/fetch_refdata.sh —— 一次性获取参考数据集（细胞类型注释用）
#
#  背景：celldex 这个 **R 包**随镜像自动安装（1.5 MB）；但它提供的**数据集**
#  （MouseRNAseqData / HumanPrimaryCellAtlasData）体积大、不进镜像，
#  需要在首次部署时下载一次，放到宿主机的 SCAGENT_BIODATA 目录下。
#
#  做法：起一个**临时容器**（带外网）调用 celldex 下载并直接 saveRDS 到目标目录。
#        生产容器仍然离线、只读挂载 —— 运行期零下载的架构不变。
#
#  用法：
#      ./scripts/fetch_refdata.sh                      # 小鼠（默认）
#      ./scripts/fetch_refdata.sh --species human
#      ./scripts/fetch_refdata.sh --target /srv/scagent/biodata/celldex --force
#
#  完成后： ./deploy/up.sh ；自检： ./deploy/doctor.sh
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
info() { printf '\n%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '  %s\n' "${C_G}✅${C_0} $*"; }
warn() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; }
die()  { printf '  %s\n' "${C_R}❌${C_0} $*" >&2; exit 1; }

SPECIES="mouse"
TARGET=""
IMAGE=""
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --species) shift; SPECIES="${1:?mouse|human}" ;;
    --target)  shift; TARGET="${1:?--target 需要目录}" ;;
    --image)   shift; IMAGE="${1:?--image 需要镜像名}" ;;
    --force)   FORCE=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$1（可用：--species mouse|human --target DIR --image IMG --force）" ;;
  esac
  shift
done

case "$SPECIES" in
  mouse|human) ;;
  *) die "--species 只能是 mouse 或 human（当前：$SPECIES）" ;;
esac

if [ "$SPECIES" = "human" ]; then
  REF_FUN="HumanPrimaryCellAtlasData"; REF_FILE="HumanPrimaryCellAtlasData.rds"
else
  REF_FUN="MouseRNAseqData";           REF_FILE="MouseRNAseqData.rds"
fi

command -v docker >/dev/null 2>&1 || die "未找到 docker"
docker info >/dev/null 2>&1 || die "无法连接 Docker 守护进程（Docker Desktop 是否已启动？）"

# 目标目录：显式参数 > deploy/.env 的 SCAGENT_BIODATA/celldex
if [ -z "$TARGET" ]; then
  if [ -f deploy/.env ]; then
    # shellcheck source=lib/image-source.sh
    . "$ROOT/deploy/lib/image-source.sh"
    scagent_load_env deploy/.env
    BIO="$(scagent_resolve_path "${SCAGENT_BIODATA:?deploy/.env 未设置 SCAGENT_BIODATA}" 2>/dev/null || printf '%s' "$SCAGENT_BIODATA")"
    TARGET="$BIO/celldex"
  else
    # 与 install/configure 的默认布局一致：安装根 = 仓库的上级目录（仓库名通常是 scagent）
    warn "没有 deploy/.env —— 使用默认目标：<仓库上级>/biodata/celldex"
    TARGET="$(cd "$ROOT/.." && pwd)/biodata/celldex"
  fi
fi

# 镜像：显式参数 > .env 推导
if [ -z "$IMAGE" ]; then
  if [ -n "${SCAGENT_IMAGE_PREFIX:-}" ] && [ -n "${SCAGENT_VERSION:-}" ]; then
    IMAGE="${SCAGENT_IMAGE_PREFIX}/scagent-seurat:${SCAGENT_VERSION}"
  else
    IMAGE="scagent/scagent-seurat:1.0.0"
  fi
fi

if ! mkdir -p "$TARGET" 2>/dev/null; then
  die "无法创建/写入目标目录：$TARGET
      常见原因：该目录的父目录属主是 root —— 容器首次启动时 Docker 会为
      bind mount 的源目录自动创建它。修复：
          sudo chown -R \$(id -u):\$(id -g) '$(dirname "$TARGET")'
      或改用 --target 指向一个你自己可写的目录。"
fi

printf '\n%s\n' "════════════════════════════════════════════════════════════"
printf '%s\n'   "  获取参考数据集（celldex）"
printf '%s\n'   "════════════════════════════════════════════════════════════"
printf '  物种    : %s（%s）\n' "$SPECIES" "$REF_FUN"
printf '  目标目录: %s\n' "$TARGET"
printf '  使用镜像: %s\n' "$IMAGE"
printf '  说明    : 用一个临时容器联网下载并写入目标目录；生产容器仍然离线只读挂载\n'

if [ -f "$TARGET/$REF_FILE" ] && [ "$FORCE" -eq 0 ]; then
  ok "已存在 $TARGET/$REF_FILE（$(du -h "$TARGET/$REF_FILE" | cut -f1)）—— 需要重新下载请加 --force"
  exit 0
fi

info "下载中（体积较大，请耐心等待）"
if ! docker run --rm --network bridge \
      --user "$(id -u):$(id -g)" \
      -v "$TARGET:/out" \
      --entrypoint Rscript "$IMAGE" -e "
        library(celldex)
        message('正在获取 $REF_FUN() …')
        x <- $REF_FUN()
        saveRDS(x, '/out/$REF_FILE')
        cat('OK', '/out/$REF_FILE', format(file.size('/out/$REF_FILE')), '\n')
      "; then
  die "下载失败。常见原因：容器无法出网（代理/防火墙/DNS），或该镜像不存在。
      离线环境可改用自建对象存储： scripts/download_data.sh（见 deploy/data.manifest）"
fi

ok "已写入：$TARGET/$REF_FILE（$(du -h "$TARGET/$REF_FILE" 2>/dev/null | cut -f1)）"
printf '    下一步： ./deploy/up.sh        （生产容器会以只读方式挂载它）\n'
printf '             ./deploy/doctor.sh    （确认"参考数据（celldex）"一项为 ✅）\n'
