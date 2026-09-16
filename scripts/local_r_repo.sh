#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/local_r_repo.sh —— 管理"本机临时的 R 源码包本地优先源"（.local-r-repo/）
#
#  用途：网络不稳定时，把已下载好的 R 源码包放到构建能读到的地方，
#        让镜像构建优先用本地包、少联网。**它不属于项目**：不进 git、不进镜像。
#        详见 .local-r-repo/README.md。
#
#  用法：
#      ./scripts/local_r_repo.sh link      # 把 shared_data/*.tar.gz 硬链接进来（推荐）
#      ./scripts/local_r_repo.sh status    # 看当前有哪些包会被优先使用
#      ./scripts/local_r_repo.sh clean     # 清空（镜像建完、流程跑通后）
#
#  说明：硬链接（cp -l）只在同一文件系统有效；失败时自动退回复制。
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
ok()   { printf '  %s\n' "${C_G}✅${C_0} $*"; }
warn() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; }
die()  { printf '  %s\n' "${C_R}❌${C_0} $*" >&2; exit 1; }

LOCAL_DIR="$ROOT/.local-r-repo"
SRC_DIR="$ROOT/shared_data"

cmd="${1:-status}"

case "$cmd" in
  link)
    mkdir -p "$LOCAL_DIR"
    shopt -s nullglob
    files=("$SRC_DIR"/*.tar.gz)
    [ "${#files[@]}" -gt 0 ] || die "shared_data/ 里没有 *.tar.gz（先把源码包下载到那里）"
    n=0
    for f in "${files[@]}"; do
      base="$(basename "$f")"
      cp -l "$f" "$LOCAL_DIR/$base" 2>/dev/null || cp "$f" "$LOCAL_DIR/$base"
      n=$((n+1))
    done
    ok "已就位 $n 个源码包 → $LOCAL_DIR"
    printf '    下一步： docker compose -f deploy/docker-compose.build.yml build runtime\n'
    printf '    （构建日志里会看到「本地优先源: /tmp/local-r-repo（N 个源码包）」）\n'
    ;;
  status)
    shopt -s nullglob
    files=("$LOCAL_DIR"/*.tar.gz)
    printf '\n%s\n' "${C_B}本地优先源状态${C_0}"
    printf '  目录: %s\n' "$LOCAL_DIR"
    printf '  包数: %d\n' "${#files[@]}"
    if [ "${#files[@]}" -gt 0 ]; then
      printf '  会被优先使用的包：\n'
      for f in "${files[@]}"; do printf '    - %s\n' "$(basename "$f")"; done
    else
      warn "目录为空 —— 构建将全部走远端镜像（scratch 克隆的默认状态）"
    fi
    printf '\n  它在 git 里吗: '; git check-ignore -q .local-r-repo/x 2>/dev/null && echo "否（已被 .gitignore 忽略）✅" || echo "⚠️ 未忽略，请检查 .gitignore"
    ;;
  clean)
    if [ -d "$LOCAL_DIR" ]; then
      find "$LOCAL_DIR" -maxdepth 1 -type f -name '*.tar.gz' -delete
      ok "已清空本地优先源（说明文件与占位保留）"
    else
      warn "目录不存在：$LOCAL_DIR"
    fi
    ;;
  -h|--help|help)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    die "未知命令：$cmd（可用：link / status / clean）"
    ;;
esac
