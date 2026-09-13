#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/download_data.sh —— 从对象存储下载参考数据
#
#  数据与软件是两套独立的分发系统（docs/PROD_HANDOVER.md）：
#    · 镜像 → 私有 registry
#    · 数据 → 对象存储（OSS / S3 / MinIO），由本脚本拉取
#
#  特性：
#    · 断点续传（curl -C -），大文件中途断了可重跑
#    · sha256 校验，防止半截/被篡改的数据进入分析
#    · 与镜像版本完全解耦 —— 换参考集不需要重建任何镜像
#
#  用法：
#      export SCAGENT_DATA_BASE_URL=https://oss.example.com/biodata
#      ./scripts/download_data.sh --target /data/biodata
#      ./scripts/download_data.sh --only celldex
#      ./scripts/download_data.sh --check          # 只校验已下载的数据
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${ROOT}/deploy/data.manifest"

TARGET="${SCAGENT_BIODATA:-/data/biodata}"
ONLY=""
CHECK_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --target) shift; TARGET="${1:?--target 需要目录}" ;;
    --only)   shift; ONLY="${1:?--only 需要名称}" ;;
    --check)  CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
info() { printf '\n%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '  %s\n' "${C_G}✅${C_0} $*"; }
warn() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; }
die()  { printf '  %s\n' "${C_R}❌${C_0} $*" >&2; exit 1; }

[ -f "$MANIFEST" ] || die "找不到清单: $MANIFEST"
command -v curl >/dev/null || die "需要 curl"

BASE_URL="${SCAGENT_DATA_BASE_URL:-}"
if [ -z "$BASE_URL" ] && [ "$CHECK_ONLY" -eq 0 ]; then
  die "未设置对象存储地址。请先：
      export SCAGENT_DATA_BASE_URL=https://oss.example.com/biodata
    或在 deploy/.env 中设置后 source 它。"
fi

printf '\n%s\n' "附件数据下载"
printf '  清单    : %s\n' "$MANIFEST"
printf '  目标目录: %s\n' "$TARGET"
printf '  数据源  : %s\n' "${BASE_URL:-<仅校验模式>}"

if [ "$CHECK_ONLY" -eq 0 ]; then
  mkdir -p "$TARGET" || die "无法创建目录 $TARGET（权限不足？请用 sudo 或换目录）"
fi

FAILED=()
COUNT=0

while read -r name version sha; do
  case "$name" in ''|\#*) continue ;; esac
  [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue
  COUNT=$((COUNT+1))

  dir="$TARGET/$name"
  archive="$dir/$name-$version.tar.gz"

  if [ "$CHECK_ONLY" -eq 1 ]; then
    info "校验 $name ($version)"
    if [ -d "$dir" ] && find "$dir" -name '*.rds' | grep -q .; then
      n=$(find "$dir" -name '*.rds' | wc -l)
      ok "$n 个 .rds 已就绪"
    else
      warn "尚无数据: $dir"
      FAILED+=("$name")
    fi
    continue
  fi

  if printf '%s' "$sha" | grep -qE 'REPLACE|PLACEHOLDER'; then
    warn "$name 的 sha256 仍是占位值 —— 跳过校验（请在 deploy/data.manifest 中填真实值）"
  fi

  info "下载 $name $version"
  mkdir -p "$dir"

  if [ -f "$archive" ] && ! printf '%s' "$sha" | grep -qE 'REPLACE|PLACEHOLDER'; then
    if echo "$sha  $archive" | sha256sum -c - >/dev/null 2>&1; then
      ok "已存在且校验通过，跳过下载"
      continue
    fi
    warn "已有文件校验失败，重新下载"
  fi

  # 断点续传 + 重试
  if ! curl -fL -C - --retry 5 --retry-delay 3 --retry-all-errors \
        -o "$archive" "$BASE_URL/$name-$version.tar.gz"; then
    warn "下载失败: $name"
    FAILED+=("$name")
    continue
  fi

  if ! printf '%s' "$sha" | grep -qE 'REPLACE|PLACEHOLDER'; then
    if ! echo "$sha  $archive" | sha256sum -c - >/dev/null 2>&1; then
      warn "sha256 校验失败: $name（文件可能损坏，请重跑本脚本）"
      FAILED+=("$name")
      continue
    fi
    ok "sha256 校验通过"
  fi

  info "解包 $name"
  tar -xzf "$archive" -C "$dir" || { warn "解包失败: $name"; FAILED+=("$name"); continue; }
  rm -f "$archive"
  ok "$(find "$dir" -name '*.rds' | wc -l) 个 .rds 就绪"
done < "$MANIFEST"

printf '\n%s\n' "────────────────────────────────────────────────────────────"
if [ "$COUNT" -eq 0 ]; then
  warn "清单中没有匹配的条目（--only $ONLY？）"
  exit 0
fi

if [ "${#FAILED[@]}" -eq 0 ]; then
  ok "全部就绪: $TARGET"
  printf '\n  下一步：\n'
  printf '    1. 确认 deploy/.env 中 SCAGENT_BIODATA=%s\n' "$TARGET"
  printf '    2. 重启服务： ./deploy/up.sh\n'
  printf '    3. 验证：     ./deploy/verify.sh\n'
  exit 0
fi

die "以下数据下载失败: ${FAILED[*]}
    可重跑本脚本（支持断点续传），或检查 SCAGENT_DATA_BASE_URL 与网络。"
