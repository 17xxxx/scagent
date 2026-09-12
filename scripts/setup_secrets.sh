#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/setup_secrets.sh —— 把密钥从 .env 迁移到 Docker secrets 文件
#
#  为什么要把密钥放到【项目目录之外】：
#    开发编排挂载的是 `..:/workspace`（整个仓库）。任何放在项目内的密钥文件
#    都会随这个挂载进入容器，secrets 就失去了意义。
#    参见 docs 中关于挂载范围的说明。
#
#  产出（默认）：
#    ~/.config/scagent/deepseek_api_key   权限 600
#    ~/.config/scagent/scagent_token      权限 600
#    目录本身权限 700
#
#  用法：
#      ./scripts/setup_secrets.sh                    # 从项目根 .env 迁移
#      ./scripts/setup_secrets.sh --target DIR       # 指定目录
#      ./scripts/setup_secrets.sh --from FILE        # 从别的 env 文件读取
#      ./scripts/setup_secrets.sh --force            # 覆盖已存在的密钥
#      ./scripts/setup_secrets.sh --check            # 只检查现状，不写文件
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
info() { printf '\n%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '  %s\n' "${C_G}✅${C_0} $*"; }
warn() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; }
die()  { printf '  %s\n' "${C_R}❌${C_0} $*" >&2; exit 1; }

TARGET="${HOME}/.config/scagent"
FROM_FILE="$ROOT/.env"
FORCE=0
CHECK_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --target) shift; TARGET="${1:?--target 需要目录}" ;;
    --from)   shift; FROM_FILE="${1:?--from 需要文件}" ;;
    --force)  FORCE=1 ;;
    --check)  CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
  shift
done

KEY_FILE="$TARGET/deepseek_api_key"
TOKEN_FILE="$TARGET/scagent_token"

printf '\n%s\n' "════════════════════════════════════════════════════════════"
printf '%s\n'   "  scAgent 密钥迁移（Docker secrets）"
printf '%s\n\n' "════════════════════════════════════════════════════════════"
# 归一化为绝对路径 —— 否则 `--target ./deploy/secrets` 这类相对路径
# 会绕过下面的"项目内"检查（曾因此把真实密钥误写进项目）
_norm() {
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$1"
  else
    case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac
  fi
}
ROOT_ABS="$(_norm "$ROOT")"
TARGET="$(_norm "$TARGET")"

printf '  目标目录: %s\n' "$TARGET"

# ── 安全检查：目标目录绝不能在项目内 ─────────────────────────────────────────
case "$TARGET" in
  "$ROOT_ABS"|"$ROOT_ABS"/*)
    die "目标目录位于项目内（$TARGET）。
      开发编排会把整个仓库挂进容器（..:/workspace），
      放在项目内的密钥文件会随挂载进入容器，secrets 就失去意义。
      请改用项目外的目录，例如默认的 \$HOME/.config/scagent" ;;
esac
ok "目标目录在项目之外（挂载不会带进去）"

# ── 只检查模式 ────────────────────────────────────────────────────────────────
read_env() {   # read_env <变量名> <文件>
  local name="$1" file="$2"
  [ -f "$file" ] || return 0
  # tr -d '\r' 必须有：.env 常是 CRLF，否则密钥尾部会混入 \r 导致鉴权失败
  sed -n "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*//p" "$file" \
    | tail -1 | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

if [ "$CHECK_ONLY" -eq 1 ]; then
  info "现状检查"
  for f in "$KEY_FILE" "$TOKEN_FILE"; do
    if [ -f "$f" ]; then
      perms=$(stat -c '%a' "$f" 2>/dev/null || echo '?')
      size=$(wc -c < "$f")
      if [ "$perms" = "600" ]; then ok "$f  权限 $perms  长度 $size"
      else warn "$f  权限 $perms（建议 600：chmod 600 $f）"; fi
    else
      warn "缺失: $f"
    fi
  done
  dperms=$(stat -c '%a' "$TARGET" 2>/dev/null || echo '?')
  ok "目录权限 $dperms"
  exit 0
fi

# ── 取密钥值 ──────────────────────────────────────────────────────────────────
info "[1/3] 收集密钥"

api_key=""
if [ -f "$FROM_FILE" ]; then
  api_key=$(read_env DEEPSEEK_API_KEY "$FROM_FILE")
  [ -n "$api_key" ] && ok "从 $FROM_FILE 读到 DEEPSEEK_API_KEY"
fi
if [ -z "$api_key" ]; then
  api_key="${DEEPSEEK_API_KEY:-}"
  [ -n "$api_key" ] && ok "从环境变量 DEEPSEEK_API_KEY 读到"
fi
if [ -z "$api_key" ]; then
  if [ -t 0 ]; then
    printf '  未找到 LLM API Key。请粘贴（到 https://platform.deepseek.com/api_keys 创建）：\n  > '
    read -r api_key
  fi
fi
[ -n "$api_key" ] || die "没有可用的 API Key。
    请先在项目根 .env 里填好 DEEPSEEK_API_KEY，或用环境变量提供。"
case "$api_key" in
  sk-*) ;;
  *) warn "取到的值不以 sk- 开头，请确认它是密钥而不是占位符" ;;
esac

token=""
[ -f "$FROM_FILE" ] && token=$(read_env SCAGENT_TOKEN "$FROM_FILE")
[ -z "$token" ] && token="${SCAGENT_TOKEN:-}"
if [ -n "$token" ]; then
  ok "复用已有访问令牌"
else
  if command -v openssl >/dev/null 2>&1; then
    token=$(openssl rand -hex 24)
  else
    token=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  fi
  ok "已生成新的访问令牌（48 位十六进制）"
fi

# ── 写文件 ────────────────────────────────────────────────────────────────────
info "[2/3] 写入密钥文件"

# 再兜一道：确认没被别的路径绕过
case "$TARGET" in
  "$ROOT_ABS"|"$ROOT_ABS"/*)
    die "内部错误：目标目录仍在项目内（$TARGET），已中止写入" ;;
esac

if [ -e "$KEY_FILE" ] && [ "$FORCE" -eq 0 ]; then
  warn "$KEY_FILE 已存在，未覆盖（要覆盖请加 --force）"
else
  umask 077
  mkdir -p "$TARGET" 2>/dev/null || die "无法创建目录 $TARGET（权限不足）。
      请确认上级目录存在且当前用户可写，或用 --target 指定别的位置：
          ./scripts/setup_secrets.sh --target \$HOME/scagent-secrets"
  chmod 700 "$TARGET" 2>/dev/null || true
  printf '%s' "$api_key" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  ok "$KEY_FILE  (600)"
fi

if [ -e "$TOKEN_FILE" ] && [ "$FORCE" -eq 0 ]; then
  warn "$TOKEN_FILE 已存在，未覆盖（要覆盖请加 --force）"
  token=$(cat "$TOKEN_FILE")
else
  umask 077
  mkdir -p "$TARGET"
  chmod 700 "$TARGET"
  printf '%s' "$token" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  ok "$TOKEN_FILE  (600)"
fi

# ── 提示下一步 ────────────────────────────────────────────────────────────────
info "[3/3] 完成"
printf '\n  访问令牌（浏览器 / CLI 登录时用）已写入：\n'
printf '      %s\n' "$TOKEN_FILE"
printf '  查看它：\n'
printf '      cat %s\n\n' "$TOKEN_FILE"
printf '  （故意不回显到终端，避免令牌进入 shell 记录或日志）\n\n' 

printf '  启动开发环境：\n'
printf '      docker compose -f .devcontainer/docker-compose.yml up -d\n\n'
printf '  说明：\n'
printf '    · 密钥文件通过 Docker secrets 挂到容器内的 /run/secrets/，\n'
printf '      不会出现在 docker inspect 的 Config.Env 里\n'
printf '    · 项目内的 .env 现在可以删掉了（或留作模板，但不要再放真密钥）\n'
printf '    · 生产环境用同一套机制，只是路径不同（deploy/secrets/）\n'
printf '    · 复查现状： ./scripts/setup_secrets.sh --check\n'
