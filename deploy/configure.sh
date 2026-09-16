#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  deploy/configure.sh —— 交互式生成配置（Linux / WSL 侧；Windows 用 install.cmd）
#
#  只问 3 件事，其余自动推导：**数据根目录 → workspace/biodata/secrets 三个路径**。
#  目标是把"填配置"从 ★★★ 降到 ★（见 docs/ISSUES_AND_PLAN.md §7.6 / 决-21）。
#
#  用法：
#      ./deploy/configure.sh              # 交互（推荐）
#      ./deploy/configure.sh --yes        # 非交互：用参数/已有值，不提问
#      ./deploy/configure.sh --print      # 只打印将要写入的内容，不落盘
#      ./deploy/configure.sh --root /srv/scagent --image-source public \
#                            --deepseek-key sk-xxx --port 8080 --force
#
#  与 Windows 侧的 PS `install` **共用同一套 env 键与默认值**；镜像来源的推导
#  复用 deploy/lib/image-source.sh（真·同一实现，避免两套默认值漂移）。
#
#  本脚本**不**构建镜像、**不**启动容器、**不**改动 ACL。
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_D=$'\033[2m'; C_0=$'\033[0m'
info() { printf '\n%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '  %s\n' "${C_G}✅${C_0} $*"; }
warn() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; }
die()  { printf '  %s\n' "${C_R}❌${C_0} $*" >&2; exit 1; }
step() { printf '      %s%s%s\n' "$C_D" "$*" "$C_0"; }

INSTALL_ROOT=""
IMAGE_SOURCE=""
DEEPSEEK_KEY=""
PORT="8080"
BIND_ADDR="127.0.0.1"
YES=0; PRINT_ONLY=0; FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root)         shift; INSTALL_ROOT="${1:?--root 需要目录}" ;;
    --image-source) shift; IMAGE_SOURCE="${1:?local|public|private}" ;;
    --deepseek-key) shift; DEEPSEEK_KEY="${1:?--deepseek-key 需要值}" ;;
    --port)         shift; PORT="${1:?--port 需要端口号}" ;;
    --bind)         shift; BIND_ADDR="${1:?--bind 需要地址}" ;;
    --yes|-y)       YES=1 ;;
    --print)        PRINT_ONLY=1 ;;
    --force)        FORCE=1 ;;
    -h|--help)      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$1（可用：--root --image-source --deepseek-key --port --bind --yes --print --force）" ;;
  esac
  shift
done

printf '\n%s\n' "════════════════════════════════════════════════════════════"
printf '%s\n'   "  scAgent 配置向导（configure）"
printf '%s\n'   "════════════════════════════════════════════════════════════"

ask() {
  local prompt="$1" default="${2:-}" answer=""
  if [ -n "$default" ]; then printf '  %s [%s]: ' "$prompt" "$default" >&2
  else printf '  %s: ' "$prompt" >&2; fi
  IFS= read -r answer || true
  [ -z "$answer" ] && answer="$default"
  printf '%s' "$answer"
}

ask_secret() {
  local prompt="$1" answer=""
  printf '  %s: ' "$prompt" >&2
  if command -v stty >/dev/null 2>&1 && [ -t 0 ]; then
    stty -echo 2>/dev/null || true
    IFS= read -r answer || true
    stty echo 2>/dev/null || true
    printf '\n' >&2
  else
    IFS= read -r answer || true
  fi
  printf '%s' "$answer"
}

to_abs() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$ROOT" "${1#./}" ;;
  esac
}

ENV_FILE="deploy/.env"

EXISTING=0
if [ -f "$ENV_FILE" ]; then
  EXISTING=1
  info "检测到已有配置 deploy/.env"
  sed -n 's/^\(SCAGENT_[A-Z_]*\)=\(.*\)/      \1=\2/p' "$ENV_FILE" | head -12
  if [ "$FORCE" -eq 0 ] && [ "$YES" -eq 0 ] && [ "$PRINT_ONLY" -eq 0 ]; then
    ans="$(ask '保留现有配置？(K=保留 / o=重新配置)' 'K')"
    case "$ans" in
      o|O|overwrite|覆盖|重新) : ;;
      *) ok "保留现有配置，未做任何修改"; exit 0 ;;
    esac
  fi
fi

info "[1/3] 数据根目录"
if [ -z "$INSTALL_ROOT" ]; then
  if [ "$YES" -eq 1 ] || [ "$PRINT_ONLY" -eq 1 ]; then
    INSTALL_ROOT='/srv/scagent'
  else
    INSTALL_ROOT="$(ask '数据根目录（会在此建立 workspace / biodata / secrets）' '/srv/scagent')"
  fi
fi
INSTALL_ROOT="$(to_abs "$INSTALL_ROOT")"

IN_REPO=0
case "$INSTALL_ROOT" in
  "$ROOT"|"$ROOT"/*) IN_REPO=1 ;;
esac
if [ "$IN_REPO" -eq 1 ]; then
  warn "数据根目录在仓库内部（$INSTALL_ROOT）"
  step "建议放到仓库之外，例如 /srv/scagent —— 避免误打包/误删/误提交（G4）"
  if [ "$YES" -eq 0 ] && [ "$PRINT_ONLY" -eq 0 ]; then
    ans="$(ask '仍要使用它吗？(y/N)' 'N')"
    case "$ans" in y|Y|yes) : ;; *) die "已取消：请换一个仓库之外的目录" ;; esac
  fi
fi

WS="$INSTALL_ROOT/workspace"
BIO="$INSTALL_ROOT/biodata"
SECRETS="$INSTALL_ROOT/secrets"
ok "工作目录   $WS"
ok "参考数据   $BIO"
ok "密钥目录   $SECRETS"

info "[2/3] 镜像来源"
if [ -z "$IMAGE_SOURCE" ]; then
  if [ "$YES" -eq 1 ] || [ "$PRINT_ONLY" -eq 1 ]; then
    IMAGE_SOURCE='local'
  else
    IMAGE_SOURCE="$(ask '镜像来源 local=本机构建 / public=公开发布 / private=自有 registry' 'local')"
  fi
fi

PREFIX=""; VERSION="1.0.0"
OLD_SOURCE=""
if [ "$EXISTING" -eq 1 ]; then
  PREFIX="$(sed -n 's/^SCAGENT_IMAGE_PREFIX=//p' "$ENV_FILE" | tr -d '\r' | head -1)"
  OLD_SOURCE="$(sed -n 's/^SCAGENT_IMAGE_SOURCE=//p' "$ENV_FILE" | tr -d '\r' | head -1)"
  v="$(sed -n 's/^SCAGENT_VERSION=//p' "$ENV_FILE" | tr -d '\r' | head -1)"
  [ -n "$v" ] && VERSION="$v"
fi

# 换了镜像来源就不能沿用旧前缀（否则会出现"public 来源 + local 前缀"这种自相矛盾的配置）
if [ -n "$PREFIX" ] && [ -n "$OLD_SOURCE" ] && [ "$OLD_SOURCE" != "$IMAGE_SOURCE" ]; then
  step "镜像来源从 $OLD_SOURCE 改成 $IMAGE_SOURCE → 重新推导前缀（不沿用旧值 $PREFIX）"
  PREFIX=""
fi

# 用共享库推导（唯一实现）：子 shell 里跑，拿回 prefix 与 pull policy
derived="$( SCAGENT_LIB_SOFT_FAIL=1 SCAGENT_IMAGE_SOURCE="$IMAGE_SOURCE" SCAGENT_IMAGE_PREFIX="$PREFIX" SCAGENT_VERSION="$VERSION" bash -c '. "$1/deploy/lib/image-source.sh"; scagent_resolve_image >/dev/null 2>&1 && printf "%s %s" "$SCAGENT_IMAGE_PREFIX" "$SCAGENT_PULL_POLICY"' _ "$ROOT" 2>&1 )" || true

case "$derived" in
  *" "*)
    PREFIX="${derived% *}"; PULL_POLICY="${derived##* }"
    ok "来源 $IMAGE_SOURCE → 前缀 $PREFIX（拉取策略 $PULL_POLICY，版本 $VERSION）"
    if [ "$IMAGE_SOURCE" = "public" ] && ! printf '%s' "$PREFIX" | grep -q '[.:]'; then
      warn "public 模式下前缀通常应含域名（如 ghcr.io/你的账号/scagent）；当前是 $PREFIX，会去 Docker Hub 找同名仓库"
    fi
    ;;
  *)
    die "镜像来源配置无效：$derived
      可选：local（本机 build）/ public（如 ghcr.io/...）/ private（如 harbor.corp.local/scagent）"
    ;;
esac

info "[3/3] 密钥与访问令牌"
KEY_FILE="$SECRETS/deepseek_api_key"
TOKEN_FILE="$SECRETS/scagent_token"
KEY_ACTION='保留（已存在）'

if [ -s "$KEY_FILE" ] && [ "$FORCE" -eq 0 ]; then
  ok "LLM 密钥已存在（$KEY_FILE）"
else
  if [ -z "$DEEPSEEK_KEY" ] && [ "$YES" -eq 0 ] && [ "$PRINT_ONLY" -eq 0 ]; then
    printf '  到 https://platform.deepseek.com/api_keys 创建一个并粘贴（输入不回显）\n' >&2
    DEEPSEEK_KEY="$(ask_secret 'LLM API Key（可直接回车跳过）')"
  fi
  if [ -n "$DEEPSEEK_KEY" ]; then
    KEY_ACTION="写入 $KEY_FILE"
  else
    KEY_ACTION='跳过（未提供）'
    warn "未提供 LLM 密钥 —— 服务能启动，但无法规划分析步骤（可加 --force 重跑补上）"
  fi
fi

TOKEN_ACTION='保留（已存在）'
TOKEN_NEW=''
if [ -s "$TOKEN_FILE" ] && [ "$FORCE" -eq 0 ]; then
  ok "访问令牌已存在（$TOKEN_FILE）"
else
  if command -v openssl >/dev/null 2>&1; then
    TOKEN_NEW="$(openssl rand -hex 24)"
  else
    TOKEN_NEW="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
  TOKEN_ACTION="生成新令牌并写入 $TOKEN_FILE"
fi

ENV_BODY="# ===============================================================
#  scAgent 配置（由 deploy/configure.sh 生成）
#
#  ！必须保持 UTF-8 无 BOM、换行 LF —— 用编辑器另存成 CRLF 会让令牌带 CR，
#     表现为「令牌明明对却一直 401」。要改请用 VS Code，或重跑 configure。
#
#  密钥不在这里：LLM Key 与访问令牌是 secrets 目录下的两个文件。
# ===============================================================
SCAGENT_IMAGE_SOURCE=$IMAGE_SOURCE
SCAGENT_IMAGE_PREFIX=$PREFIX
SCAGENT_VERSION=$VERSION
SCAGENT_PULL_POLICY=$PULL_POLICY

SCAGENT_WORKSPACE=$WS
SCAGENT_BIODATA=$BIO
SCAGENT_SECRETS_DIR=$SECRETS

SCAGENT_BIND_ADDR=$BIND_ADDR
SCAGENT_PORT=$PORT"

if [ "$PRINT_ONLY" -eq 1 ]; then
  info "--print：以下内容不会落盘"
  printf '%s\n' "$ENV_BODY" | sed 's/^/      /'
  printf '      密钥动作：%s\n' "$KEY_ACTION"
  printf '      令牌动作：%s\n' "$TOKEN_ACTION"
  printf '      目录动作：mkdir -p %s %s/state %s/data/rawdata %s\n' "$WS" "$WS" "$WS" "$BIO"
  exit 0
fi

info "写入配置"
mkdir -p "$SECRETS" "$WS/data/rawdata" "$WS/state" "$BIO"
ok "已创建目录：$SECRETS、$WS/{data/rawdata,state}、$BIO"

if [ -n "$DEEPSEEK_KEY" ]; then
  printf '%s' "$DEEPSEEK_KEY" > "$KEY_FILE"
  chmod 600 "$KEY_FILE" 2>/dev/null || true
  ok "已写入 LLM 密钥：$KEY_FILE"
fi

if [ -n "$TOKEN_NEW" ]; then
  printf '%s' "$TOKEN_NEW" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE" 2>/dev/null || true
  ok "已生成访问令牌：$TOKEN_FILE"
fi

printf '%s\n' "$ENV_BODY" > "$ENV_FILE"
chmod 600 "$ENV_FILE" 2>/dev/null || true
ok "已写入 $ENV_FILE（LF、无 BOM、权限 600）"

printf '\n%s\n' "────────────────────────────────────────────────────────────"
ok "配置完成"
printf '    数据放这里: %s/data/rawdata/<样本名>/\n' "$WS"
printf '    ⚠️ 是上面这个工作目录，不是仓库目录里的 data/\n'
if [ -n "$TOKEN_NEW" ]; then
  printf '    访问令牌  : %s\n' "$TOKEN_NEW"
  printf '    （已保存到 %s；浏览器首次访问时粘贴它）\n' "$TOKEN_FILE"
fi
printf '    下一步    : ./deploy/up.sh        # 启动服务（local 模式会先提示构建镜像）\n'
printf '                ./deploy/doctor.sh    # 起不来时先跑体检\n'
