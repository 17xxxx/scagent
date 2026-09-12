#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  deploy/backup.sh —— 备份运行状态
#
#  备份内容：
#    · .env                （含密钥，务必妥善保管）
#    · workspace/state/    （SQLite 会话检查点，升级前的回滚依据）
#    · workspace/data/     （分析产物；默认不备份 1.6 GB 级的中间 .rds，可加 --with-rds）
#
#  用法：
#      ./deploy/backup.sh                    # 轻量备份（不含 .rds）
#      ./deploy/backup.sh --with-rds         # 含中间产物（体积大）
#      ./deploy/backup.sh --out /backup      # 指定输出目录
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WITH_RDS=0
OUT_DIR="./backups"
while [ $# -gt 0 ]; do
  case "$1" in
    --with-rds) WITH_RDS=1 ;;
    --out) shift; OUT_DIR="${1:?--out 需要目录参数}" ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -f deploy/.env ] || { echo "❌ 缺少 deploy/.env" >&2; exit 1; }
set -a; . deploy/.env; set +a

# 相对路径统一以 deploy/ 为基准（与 docker compose 的解析规则一致）
resolve_workspace() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s' "$ROOT/deploy/$1" ;;
  esac
}

WORKSPACE="$(resolve_workspace "${SCAGENT_WORKSPACE:-../workspace}")"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"
ARCHIVE="$OUT_DIR/scagent-backup-$STAMP.tar.gz"

echo "==> 备份到 $ARCHIVE"
echo "    工作目录: $WORKSPACE"
echo "    包含 .rds: $WITH_RDS"

EXCLUDES=()
[ "$WITH_RDS" -eq 0 ] && EXCLUDES+=(--exclude='*.rds' --exclude='*.RDS')
EXCLUDES+=(--exclude='*.tmp' --exclude='*.lock')

tar -czf "$ARCHIVE" \
  "${EXCLUDES[@]}" \
  -C "$ROOT" deploy/.env 2>/dev/null || true
tar -rzf "$ARCHIVE" \
  -C "$ROOT" "$WORKSPACE/state" 2>/dev/null || true
tar -rzf "$ARCHIVE" \
  "${EXCLUDES[@]}" -C "$ROOT" "$WORKSPACE/data" 2>/dev/null || true

SIZE=$(du -h "$ARCHIVE" | cut -f1)
echo "✅ 完成: $ARCHIVE ($SIZE)"
echo
echo "恢复方式："
echo "    tar -xzf $ARCHIVE -C /"
echo "    # .env 会还原到 deploy/.env；state/ 与 data/ 会还原到 \${SCAGENT_WORKSPACE}/"
