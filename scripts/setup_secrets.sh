#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/setup_secrets.sh —— 把密钥从 .env 迁移到 Docker secrets 文件
#
#  为什么默认放到【项目目录之外】：
#    1) 任何放在项目内的密钥文件都可能被误打包/误提交（见 docs 的 G 类）；
#    2) 开发编排挂载的是 `..:/workspace`（整个仓库），项目内密钥会随挂载进容器。
#    要放回项目内需显式指定：--target deploy/secrets
#
#  产出（默认落点，按此顺序解析）：
#    1) deploy/.env 中的 SCAGENT_SECRETS_DIR
#    2) <仓库>/../scagent-secrets
#    文件名 deepseek_api_key / scagent_token，权限 600；目录权限 700
#
#  用法：
#      ./scripts/setup_secrets.sh                    # 从项目根 .env 迁移
#      ./scripts/setup_secrets.sh --target DIR       # 指定目录
#      ./scripts/setup_secrets.sh --from FILE        # 从别的 env 文件读取
#      ./scripts/setup_secrets.sh --force            # 覆盖已存在的密钥
#      ./scripts/setup_secrets.sh --check            # 只检查现状，不写文件
#      ./scripts/setup_secrets.sh --sanitize         # 清理项目内 .env 里的活密钥
#      ./scripts/setup_secrets.sh --profile dev      # 仅开发者：额外校验密钥不会进开发容器
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
info() { printf '\n%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '  %s\n' "${C_G}✅${C_0} $*"; }
warn() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; }
die()  { printf '  %s\n' "${C_R}❌${C_0} $*" >&2; exit 1; }

# 默认落点：优先用 deploy/.env 里的 SCAGENT_SECRETS_DIR；否则放在**仓库之外**的兄弟目录。
# （$HOME/.config/scagent 不适合作为默认值：在 WSL 里它落在发行版文件系统内，
#   Windows 侧看不到、也备份不到，违反「安装位置必须在宿主机磁盘」的约束。）
_default_target() {
  if [ -f "$ROOT/deploy/.env" ]; then
    local d
    d="$(sed -n 's/^[[:space:]]*SCAGENT_SECRETS_DIR[[:space:]]*=[[:space:]]*//p' "$ROOT/deploy/.env" | tr -d '\r' | head -1)"
    if [ -n "$d" ]; then
      case "$d" in
        /*) printf '%s' "$d" ;;
        *)  printf '%s/deploy/%s' "$ROOT" "${d#./}" ;;
      esac
      return
    fi
  fi
  printf '%s/../secrets' "$ROOT"
}

TARGET="$(_default_target)"
FROM_FILE="$ROOT/.env"
FORCE=0
CHECK_ONLY=0
SANITIZE=0
PROFILE="prod"

while [ $# -gt 0 ]; do
  case "$1" in
    --target) shift; TARGET="${1:?--target 需要目录}" ;;
    --from)   shift; FROM_FILE="${1:?--from 需要文件}" ;;
    --force)  FORCE=1 ;;
    --check)  CHECK_ONLY=1 ;;
    --sanitize) SANITIZE=1 ;;
    --profile|--for) shift; PROFILE="${1:?--profile 需要 dev 或 prod}" ;;
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

# ── 安全护栏：dev 与 prod 的规则不同 ─────────────────────────────────────────
#   dev  ：开发编排挂载 `..:/workspace`（整个仓库）→ 项目内密钥会被带进容器，
#          必须放在项目之外。
#   prod ：生产编排只挂 `${SCAGENT_WORKSPACE}/workspace` 与参考数据卷，
#          仓库根【不进】容器 → deploy/secrets/ 是安全且惯用的位置。
#          但仍需确认没有把仓库根误配成挂载源。
case "$TARGET" in
  "$ROOT_ABS"|"$ROOT_ABS"/*) IN_REPO=1 ;;
  *) IN_REPO=0 ;;
esac

if [ "$PROFILE" = "auto" ]; then
  # 仅当显式传 --profile auto 时才走老逻辑（auto 不再是默认值）
  if [ "$IN_REPO" -eq 1 ]; then PROFILE="prod"; else PROFILE="dev"; fi
fi
case "$PROFILE" in dev|prod) ;; *) die "--profile 只能是 dev 或 prod（当前: $PROFILE）" ;; esac

# 从 compose 的 volumes 行里取挂载源（能处理 ${VAR:-default} 形式）
_extract_mount_src() {
  local line="$1"
  line="${line#*- }"; line="${line#\"}"
  if [[ "$line" == *'${'*'}'* ]]; then
    local inner="${line#*\${}"; inner="${inner%%\}*}"
    local dflt="${inner#*:-}"
    [ "$dflt" = "$inner" ] && dflt=""     # 没有 :- 说明无默认值
    printf '%s' "$dflt"
  else
    printf '%s' "${line%%:*}"
  fi
}

# 判断密钥目录是否落在某个挂载源【之下】—— 这才是因果判断。
#   对比两种写法：
#     ✗ 错误问法："挂载源是否在仓库内" → 会把 ../workspace 误判为危险
#     ✓ 正确问法："密钥目录是否在挂载源之下" → 精确命中"会被带进容器"
check_target_not_mounted() {
  local cf="$1" label="$2" line src resolved bad=0 seen=""
  [ -f "$cf" ] || { warn "找不到 $cf，跳过挂载校验"; return 0; }

  _check_src() {   # _check_src <原始写法> <解析后的绝对路径>
    local raw="$1" abs="$2"
    [ -z "$abs" ] && return 0
    case "$seen" in *"|$abs|"*) return 0 ;; esac      # 去重（两个服务挂同一路径）
    seen="$seen|$abs|"
    case "$TARGET" in
      "$abs"|"$abs"/*)
        warn "$label 会把密钥目录带进容器： $raw  →  $abs"
        bad=1 ;;
    esac
  }

  # 1) compose 文件里声明的挂载（含 ${VAR:-default} 的默认值）
  while IFS= read -r line; do
    src="$(_extract_mount_src "$line")"
    [ -z "$src" ] && continue
    case "$src" in
      /*) resolved="$src" ;;
      *)  resolved="$(realpath -m "$(dirname "$cf")/$src" 2>/dev/null || echo "$src")" ;;
    esac
    _check_src "$src" "$resolved"
  done < <(grep -E '^\s*-\s*"?[^"]*:[^"]*"?\s*$' "$cf" 2>/dev/null | grep -vE '^\s*#')

  # 2) 运行时覆盖：deploy/.env 里的 SCAGENT_WORKSPACE 可能指向别处
  if [ -f "$ROOT/deploy/.env" ]; then
    local ws
    ws="$(sed -n 's/^[[:space:]]*SCAGENT_WORKSPACE[[:space:]]*=[[:space:]]*//p' "$ROOT/deploy/.env" \
          | tail -1 | tr -d '"'"'"'\r')"
    if [ -n "$ws" ]; then
      case "$ws" in /*) resolved="$ws" ;; *) resolved="$(realpath -m "$ROOT/deploy/$ws")" ;; esac
      _check_src "SCAGENT_WORKSPACE=$ws" "$resolved"
    fi
  fi

  return "$bad"
}

# dev 与 prod 用同一套【因果】判断，只是检查的 compose 文件不同
if [ "$PROFILE" = "dev" ]; then
  COMPOSE_TO_CHECK="$ROOT/.devcontainer/docker-compose.yml"
  COMPOSE_LABEL="开发编排"
else
  COMPOSE_TO_CHECK="$ROOT/deploy/docker-compose.yml"
  COMPOSE_LABEL="生产编排"
fi

if check_target_not_mounted "$COMPOSE_TO_CHECK" "$COMPOSE_LABEL"; then
  if [ "$IN_REPO" -eq 1 ]; then
    ok "【$PROFILE】密钥目录在项目内，但$COMPOSE_LABEL不会把它带进容器 → 安全"
  else
    ok "【$PROFILE】密钥目录在项目之外（挂载不会带进去）"
  fi
else
  die "【$PROFILE】密钥目录会被 $COMPOSE_LABEL 带进容器，Docker secrets 失去意义。

      目标：  $TARGET
      原因：  上面的挂载源是它的父目录之一。

      处置（二选一）：
        1) 换成项目外目录：
               ./scripts/setup_secrets.sh --target \$HOME/.config/scagent
        2) 若这是生产密钥，请修正挂载源不要包含它 ——
           检查 deploy/.env 的 SCAGENT_WORKSPACE 是否指向了仓库根。

      如果你要准备的是【生产】密钥：
          ./scripts/setup_secrets.sh --target deploy/secrets --profile prod"
fi

# ── 只检查模式 ────────────────────────────────────────────────────────────────
read_env() {   # read_env <变量名> <文件>
  local name="$1" file="$2"
  [ -f "$file" ] || return 0
  # tr -d '\r' 必须有：.env 常是 CRLF，否则密钥尾部会混入 \r 导致鉴权失败
  sed -n "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*//p" "$file" \
    | tail -1 | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

# ── 项目内活密钥检测 / 清理 ────────────────────────────────────────────────────
#  必须做这一步：项目根会被 compose 的 `..:/workspace` 整个挂进容器。
#  若 .env 里的真密钥仍在，secrets 的安全收益就归零 —— 容器内任何进程都能读到。
live_key_files() {
  local f
  for f in "$ROOT/.env" "$ROOT"/.env.*; do
    [ -f "$f" ] || continue
    case "$f" in *.sample|*.bak|*.orig) continue ;; esac
    grep -qE 'sk-[A-Za-z0-9]{20,}' "$f" 2>/dev/null && printf '%s\n' "$f"
  done
}

sanitize_file() {   # sanitize_file <env文件>
  local f="$1" tmp
  [ -f "$f" ] || return 0
  tmp="$(mktemp "${f}.XXXXXX")" || { warn "无法在 $f 旁创建临时文件"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  # 把 DEEPSEEK_API_KEY=... 与 SCAGENT_TOKEN=... 的值清空，保留键名
  sed -E -e 's|^([[:space:]]*DEEPSEEK_API_KEY[[:space:]]*=).*$|\1|' \
         -e 's|^([[:space:]]*SCAGENT_TOKEN[[:space:]]*=).*$|\1|' "$f" > "$tmp"
  {
    printf '# %s 已将密钥迁移到 Docker secrets（scripts/setup_secrets.sh）\n' "$(date +%F)"
    printf '# 真密钥不再保存在项目内，以免随 ..:/workspace 挂载进入容器。\n'
    printf '# 如需切回环境变量方式，请重新填入并删除上面的说明。\n'
    cat "$tmp"
  } > "${tmp}.new" && mv "${tmp}.new" "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$f"
  chmod 600 "$f"
  ok "已清理 $f 中的密钥值"
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

  echo
  mapfile -t _files < <(live_key_files)
  if [ "${#_files[@]}" -eq 0 ]; then
    ok "项目内无活密钥残留"
  else
    warn "项目内仍有活密钥： ${_files[*]}"
    printf '      这些文件会随 ..:/workspace 挂进容器，使 secrets 收益归零\n'
    printf '      修复： ./scripts/setup_secrets.sh --sanitize\n'
  fi
  exit 0
fi

# ── --sanitize：只清理项目内残留，不写 secrets ────────────────────────────────
if [ "$SANITIZE" -eq 1 ]; then
  info "清理项目内残留密钥"
  mapfile -t _files < <(live_key_files)
  if [ "${#_files[@]}" -eq 0 ]; then
    ok "项目内未发现活密钥，无需清理"
  else
    for f in "${_files[@]}"; do sanitize_file "$f"; done
  fi
  printf '\n  复查： ./scripts/check_secrets.sh\n'
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

# 占位符/残留值不算有效密钥（例：.env 里被清空成 sk- 或 sk-请替换为你的密钥）
if [ -n "$api_key" ] && ! printf '%s' "$api_key" | grep -qE '^sk-[A-Za-z0-9_-]{16,}$'; then
  warn "取到的值不像有效密钥（长度 ${#api_key}，内容以 ${api_key:0:6} 开头）—— 已忽略"
  api_key=""
fi
# 3) 继承已有 secrets 目录 —— 让"开发 → 生产"一条命令完成
if [ -z "$api_key" ]; then
  for cand in "${SCAGENT_SECRETS_DIR:-}" "$HOME/.config/scagent"; do
    [ -n "$cand" ] || continue
    [ "$(realpath -m "$cand")" = "$TARGET" ] && continue    # 就是目标目录，无需继承
    if [ -s "$cand/deepseek_api_key" ]; then
      api_key="$(tr -d '\r\n' < "$cand/deepseek_api_key")"
      ok "从已有 secrets 继承 LLM Key：$cand/deepseek_api_key"
      break
    fi
  done
fi

if [ -z "$api_key" ]; then
  if [ -t 0 ]; then
    printf '  未找到 LLM API Key。请粘贴（不回显，粘贴后回车）：\n  > '
    # -s 不回显，避免密钥留在终端回滚缓冲/肩窥；shebang 已是 bash，故可用
    # 刻意【不加】IFS=：默认行为会去掉首尾空白，恰好容错"多粘了一个空格"
    read -rs api_key
    printf '\n' 
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
# 残留的占位值不算数（长度过短就不是真令牌）
if [ -n "$token" ] && [ "${#token}" -lt 24 ]; then
  warn "取到的令牌过短（${#token} 字符）—— 已忽略"
  token=""
fi
if [ -z "$token" ]; then
  for cand in "${SCAGENT_SECRETS_DIR:-}" "$HOME/.config/scagent"; do
    [ -n "$cand" ] || continue
    [ "$(realpath -m "$cand")" = "$TARGET" ] && continue
    if [ -s "$cand/scagent_token" ]; then
      token="$(tr -d '\r\n' < "$cand/scagent_token")"
      ok "从已有 secrets 继承访问令牌：$cand/scagent_token"
      break
    fi
  done
fi
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

# 写入前再兜一道（用与前面一致的因果判断，而非"是否在项目内"）
if ! check_target_not_mounted "$COMPOSE_TO_CHECK" "$COMPOSE_LABEL"; then
  die "写入前复查失败：密钥目录会被 $COMPOSE_LABEL 带进容器，已中止"
fi

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

# ── 迁移后：清理项目内残留（否则 secrets 收益归零）──────────────────────────
mapfile -t _leaks < <(live_key_files)
if [ "${#_leaks[@]}" -gt 0 ]; then
  printf '\n'
  warn "检测到项目内仍有活密钥： ${_leaks[*]}"
  printf '      这些文件会随 `..:/workspace` 挂进容器，使 Docker secrets 的安全收益归零。\n'
  _do_sanitize=0
  if [ -t 0 ]; then
    printf '      现在清理吗（清空值、保留键名）？[Y/n] '
    read -r _ans
    case "$_ans" in ''|y|Y|yes|YES) _do_sanitize=1 ;; esac
  fi
  if [ "$_do_sanitize" -eq 1 ]; then
    for _f in "${_leaks[@]}"; do sanitize_file "$_f"; done
  else
    printf '      稍后清理： ./scripts/setup_secrets.sh --sanitize\n'
  fi
fi

# ── 提示下一步 ────────────────────────────────────────────────────────────────
info "[3/3] 完成"
printf '\n  访问令牌（浏览器 / CLI 登录时用）已写入：\n'
printf '      %s\n' "$TOKEN_FILE"
printf '  查看它：\n'
printf '      cat %s\n\n' "$TOKEN_FILE"
printf '  （故意不回显到终端，避免令牌进入 shell 记录或日志）\n\n' 

printf '  说明：\n'
printf '    · 密钥文件通过 Docker secrets 挂到容器内的 /run/secrets/，\n'
printf '      不会出现在 docker inspect 的 Config.Env 里\n'
printf '    · 项目内的 .env 现在可以删掉了（或留作模板，但不要再放真密钥）\n'
printf '    · 启动服务： ./deploy/up.sh      （Windows： deploy\\scagent.ps1 up）\n'
printf '    · 请确认 deploy/.env 里的 SCAGENT_SECRETS_DIR 指向本目录：\n'
printf '          SCAGENT_SECRETS_DIR=%s\n' "$TARGET"
printf '      up.sh 会在该目录下找到这两个文件时自动叠加 docker-compose.secrets.yml\n'
printf '    · 复查现状： ./scripts/setup_secrets.sh --check\n'
