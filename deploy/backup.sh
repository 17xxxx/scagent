#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  deploy/backup.sh —— 备份运行状态
#
#  备份内容：
#    · deploy/.env         【已脱敏】密钥值被清空，只保留 registry/version/port 等配置
#    · workspace/state/    SQLite 会话检查点（升级前的回滚依据）
#    · workspace/data/     分析产物（默认不含 1.6 GB 级的中间 .rds）
#
#  ⚠️ 默认【不】备份密钥目录 deploy/secrets/：
#      密钥应与数据分开管理。一旦装进备份包，它就会被 rsync、快照、对象存储、
#      以及任何拿到备份文件的人一并带走 —— 这是最容易被忽视的泄漏路径。
#      确需一并备份时加 --include-secrets，并自行确保备份介质已加密。
#
#  用法：
#      ./deploy/backup.sh                    # 轻量备份（不含 .rds、不含密钥）
#      ./deploy/backup.sh --with-rds         # 含中间产物（体积大）
#      ./deploy/backup.sh --include-secrets  # 额外打包密钥（风险自负）
#      ./deploy/backup.sh --out /backup      # 指定输出目录
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 共享库：.env 去 CR 加载（Windows 编辑器写入的 .env 带 \r，会让脱敏/路径解析出错）
# shellcheck source=lib/image-source.sh
. "$ROOT/deploy/lib/image-source.sh"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
ok()   { printf '  %s\n' "${C_G}✅${C_0} $*"; }
warn() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; }

WITH_RDS=0
WITH_SECRETS=0
OUT_DIR="./backups"
while [ $# -gt 0 ]; do
  case "$1" in
    --with-rds)        WITH_RDS=1 ;;
    --include-secrets) WITH_SECRETS=1 ;;
    --out) shift; OUT_DIR="${1:?--out 需要目录参数}" ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -f deploy/.env ] || { echo "❌ 缺少 deploy/.env" >&2; exit 1; }
scagent_load_env deploy/.env

WORKSPACE="$(scagent_resolve_path "${SCAGENT_WORKSPACE:?deploy/.env 中未设置 SCAGENT_WORKSPACE}")"

# 密钥目录：建议在仓库之外（见 deploy/.env.sample），相对路径以 deploy/ 为基准
SECRETS_DIR="$(scagent_resolve_path "${SCAGENT_SECRETS_DIR:-./secrets}")"

STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"
ARCHIVE="$(cd "$OUT_DIR" && pwd)/scagent-backup-$STAMP.tar.gz"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> 备份到 $ARCHIVE"
echo "    工作目录: $WORKSPACE"
echo "    包含 .rds: $WITH_RDS"

EXCLUDES=(--exclude='*.tmp' --exclude='*.lock')
[ "$WITH_RDS" -eq 0 ] && EXCLUDES+=(--exclude='*.rds' --exclude='*.RDS')

# ── 1. .env 脱敏后暂存（密钥值清空，键名保留）─────────────────────────────────
mkdir -p "$STAGE/deploy"
sed -E -e 's|^([[:space:]]*DEEPSEEK_API_KEY[[:space:]]*=).*$|\1|' \
       -e 's|^([[:space:]]*SCAGENT_LLM_API_KEY[[:space:]]*=).*$|\1|' \
       -e 's|^([[:space:]]*SCAGENT_LLM_API_KEY_FILE[[:space:]]*=).*$|\1|' \
       -e 's|^([[:space:]]*SCAGENT_TOKEN[[:space:]]*=).*$|\1|' \
       -e 's|^([[:space:]]*SCAGENT_TOKEN_FILE[[:space:]]*=).*$|\1|' \
    deploy/.env > "$STAGE/deploy/.env"
chmod 600 "$STAGE/deploy/.env"
ok "deploy/.env 已脱敏（密钥值清空）"

# ── 2. 状态目录 ───────────────────────────────────────────────────────────────
if [ -d "$WORKSPACE/state" ]; then
  mkdir -p "$STAGE/workspace"
  cp -a "$WORKSPACE/state" "$STAGE/workspace/"
  ok "已收集 state/（会话检查点）"
fi

# ── 3. 分析产物 ───────────────────────────────────────────────────────────────
if [ -d "$WORKSPACE/data" ]; then
  mkdir -p "$STAGE/workspace"
  # 用 tar 管道复制以便应用排除规则（cp 不支持 exclude）
  ( cd "$WORKSPACE" && tar -cf - "${EXCLUDES[@]}" data ) | ( cd "$STAGE/workspace" && tar -xf - )
  ok "已收集 data/（$([ "$WITH_RDS" -eq 0 ] && echo '不含 .rds' || echo '含 .rds')）"
fi

# ── 4. 密钥（默认排除）────────────────────────────────────────────────────────
if [ "$WITH_SECRETS" -eq 1 ]; then
  if [ -d "$SECRETS_DIR" ]; then
    mkdir -p "$STAGE/secrets"
    cp -a "$SECRETS_DIR/." "$STAGE/secrets/"
    warn "已按 --include-secrets 打包 $SECRETS_DIR —— 请确保备份介质已加密"
  else
    echo "  （--include-secrets 已指定，但 $SECRETS_DIR 不存在）"
  fi
else
  warn "已排除密钥目录 $SECRETS_DIR（如需一并备份，加 --include-secrets）"
  # 双保险：万一 secrets 被误复制进 stage
  rm -rf "$STAGE/deploy/secrets" "$STAGE/secrets"
fi

# ── 5. 打包 ───────────────────────────────────────────────────────────────────
tar -czf "$ARCHIVE" -C "$STAGE" .

# 打包后再确认一次包内没有活密钥（脱敏失效时会在这里暴露）
if tar -xzOf "$ARCHIVE" ./deploy/.env 2>/dev/null | grep -qE 'sk-[A-Za-z0-9]{20,}'; then
  rm -f "$ARCHIVE"
  printf '  %s\n' "${C_R}❌ 备份包内检出活密钥，已删除该包。请检查 deploy/.env 的脱敏规则。${C_0}" >&2
  exit 1
fi
ok "已校验：备份包内无活密钥"

SIZE=$(du -h "$ARCHIVE" | cut -f1)
printf '\n%s\n' "────────────────────────────────────────────────────────────"
ok "完成: $ARCHIVE ($SIZE)"
printf '\n  恢复方式：\n'
printf '      tar -xzf %s -C /tmp/restore\n' "$(basename "$ARCHIVE")"
printf '      # 包内结构： deploy/.env  workspace/state/  workspace/data/\n'
printf '      # 注意：deploy/.env 里的密钥值已在备份时清空，需重新填写\n'
