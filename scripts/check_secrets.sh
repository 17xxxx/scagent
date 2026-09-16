#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/check_secrets.sh —— 密钥可读性预检（宿主机侧）
#
#  为什么需要它：
#    Docker Compose 的 file 型 secret 底层就是 bind mount，容器能不能读
#    完全由【宿主机文件的属主 + 权限位 + 强制访问控制】三者共同决定。
#    而 services.secrets 的 uid/gid/mode 属性在该实现下【不被支持】，
#    所以只能从宿主机侧对齐。任一不匹配都会让 agent 启动即失败，
#    且报错往往只有一句 Permission denied。
#
#  本脚本检查：
#    1. 容器有效 UID —— 用 `docker run --rm --entrypoint id <image> -u` 运行时探测
#    2. 密钥文件属主是否等于该 UID
#    3. 文件/目录权限
#    4. SELinux 状态；Enforcing 时检查文件标签是否为 container_file_t
#    5. 项目内是否仍残留活密钥（迁移后忘记清理会让 secrets 收益归零）
#
#  用法：
#      ./scripts/check_secrets.sh                    # 自动检查 dev + prod 两套
#      ./scripts/check_secrets.sh --dev              # 只查开发环境
#      ./scripts/check_secrets.sh --prod             # 只查生产环境
#      ./scripts/check_secrets.sh --dir DIR          # 指定密钥目录
# ═══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
PASS=0; WARN=0; FAIL=0
info() { printf '\n%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '  %s\n' "${C_G}✅${C_0} $*"; PASS=$((PASS+1)); }
warn() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; WARN=$((WARN+1)); }
bad()  { printf '  %s\n' "${C_R}❌${C_0} $*"; FAIL=$((FAIL+1)); }
hint() { printf '       %s\n' "$*"; }

CHECK_DEV=0; CHECK_PROD=0; EXPLICIT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dev)  CHECK_DEV=1 ;;
    --prod) CHECK_PROD=1 ;;
    --dir)  shift; EXPLICIT_DIR="${1:?--dir 需要目录}" ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
[ "$CHECK_DEV" -eq 0 ] && [ "$CHECK_PROD" -eq 0 ] && { CHECK_DEV=1; CHECK_PROD=1; }

printf '\n%s\n' "════════════════════════════════════════════════════════════"
printf '%s\n'   "  密钥可读性预检"
printf '%s\n'   "════════════════════════════════════════════════════════════"

# ── 1. 探测容器有效 UID（不硬编码，不依赖 Config.User）───────────────────────
CONTAINER_UID=""; UID_SOURCE=""

probe_uid() {   # probe_uid <image>
  local img="$1"
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1 || return 1
  docker image inspect "$img" >/dev/null 2>&1 || return 1
  # 运行时探测：最可靠，能正确处理 USER 写用户名、以及 ENTRYPOINT 场景
  docker run --rm --entrypoint id "$img" -u 2>/dev/null | tr -dc '0-9'
}

# 回退：从 Dockerfile 静态解析（仅作估算，会明确标注）
guess_uid_from_dockerfile() {
  awk '/^RUN.*useradd/ {for(i=1;i<=NF;i++) if($i=="-u") print $(i+1)}' \
    agent_core/Dockerfile 2>/dev/null | head -1
}

info "[1/4] 探测容器有效 UID"
# 候选镜像：开发 tag → .env 里的发布镜像（前缀 + 版本）
CANDIDATE_IMAGES=("scagent-agent:dev")
if [ -n "${SCAGENT_IMAGE_PREFIX:-}" ] && [ -n "${SCAGENT_VERSION:-}" ]; then
  CANDIDATE_IMAGES+=("${SCAGENT_IMAGE_PREFIX}/scagent-agent:${SCAGENT_VERSION}")
fi
for img in "${CANDIDATE_IMAGES[@]}"; do
  [ -z "$img" ] && continue
  u="$(probe_uid "$img")" && [ -n "$u" ] && { CONTAINER_UID="$u"; UID_SOURCE="运行时探测 ($img)"; break; }
done
if [ -z "$CONTAINER_UID" ]; then
  g="$(guess_uid_from_dockerfile)"
  if [ -n "$g" ]; then
    CONTAINER_UID="$g"; UID_SOURCE="Dockerfile 静态解析（估算）"
    warn "无法运行时探测（镜像不存在或 Docker 不可用），改用 $UID_SOURCE"
    hint "构建镜像后重跑本脚本可获得准确值"
  else
    bad "无法确定容器 UID —— Docker 不可用且 Dockerfile 中未找到 useradd -u"
    hint "请先 ./scripts/dev_build.sh 构建镜像，或手动指定"
  fi
fi
[ -n "$CONTAINER_UID" ] && ok "容器有效 UID = $CONTAINER_UID   （来源：$UID_SOURCE）"

# ── 2. SELinux ────────────────────────────────────────────────────────────────
info "[2/4] 强制访问控制（SELinux）"
SELINUX=""
if command -v getenforce >/dev/null 2>&1; then
  SELINUX="$(getenforce 2>/dev/null)"
elif [ -r /sys/fs/selinux/enforce ]; then
  [ "$(cat /sys/fs/selinux/enforce 2>/dev/null)" = "1" ] && SELINUX="Enforcing" || SELINUX="Permissive"
fi
if [ "$SELINUX" = "Enforcing" ]; then
  warn "SELinux = Enforcing —— 这是 bind mount 密钥最常见的隐形失败原因"
  hint "标签不匹配会报 EPERM，而 ls -l 看上去完全正常"
  hint "Compose 的 secrets 语法【不支持】:z/:Z，无法靠挂载选项自动打标签"
  hint "需预先打标签："
  hint "    sudo chcon -t container_file_t <宿主机密钥文件>"
  hint "  或（持久化）sudo semanage fcontext -a -t container_file_t '<路径>' && sudo restorecon -v '<路径>'"
elif [ -n "$SELINUX" ]; then
  ok "SELinux = $SELINUX（非 Enforcing，不构成阻碍）"
elif command -v aa-status >/dev/null 2>&1; then
  ok "无 SELinux；检测到 AppArmor（对 bind mount 通常不构成阻碍）"
else
  ok "未检测到 SELinux"
fi

# ── 3. 逐套检查密钥文件 ───────────────────────────────────────────────────────
# 权限位是否可靠：drvfs（/mnt/*）、Git Bash、Windows 容器都不保留 POSIX 权限位，
# 此时把"权限不是 600"降级为警告，否则会把用户引向一个改不动的方向（见 C3）。
PERM_ENFORCE=1
case "${SCAGENT_SECRETS_DIR:-}" in /mnt/*) PERM_ENFORCE=0 ;; esac
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) PERM_ENFORCE=0 ;;
esac
if [ "$PERM_ENFORCE" -eq 0 ]; then
  warn "当前文件系统/平台不保留 POSIX 权限位（drvfs / Git Bash / Windows）"
  hint "权限相关项降级为警告；Windows 下请用 icacls 限制目录访问（deploy\\scagent.ps1 secrets 会自动做）"
fi

check_one_set() {   # check_one_set <名称> <目录>
  local label="$1" dir="$2"
  info "[3/4] $label 密钥目录: $dir"

  if [ ! -d "$dir" ]; then
    warn "目录不存在（若这套尚未初始化，属正常）"
    return
  fi
  local dperm downer
  dperm="$(stat -c '%a' "$dir" 2>/dev/null)"
  downer="$(stat -c '%u' "$dir" 2>/dev/null)"
  [ "$dperm" = "700" ] && ok "目录权限 700" || warn "目录权限 $dperm（建议 700）"
  hint "目录属主 UID = $downer"

  local found=0
  for f in "$dir"/deepseek_api_key "$dir"/scagent_token; do
    [ -e "$f" ] || continue
    found=1
    local perm owner size
    local name; name="$(basename "$f")"

    # Docker 在 secret 源文件缺失时会建同名【目录】占位（bind mount 行为）。
    # 目录的 size 是 4096，会被误判成"文件非空、容器可读" —— 必须单独拦。
    if [ -d "$f" ]; then
      bad "$name 是一个目录（不是文件）—— Docker 在源文件缺失时创建的占位目录"
      hint "修复： rmdir $f   然后重新放入密钥文件"
      continue
    fi

    perm="$(stat -c '%a' "$f" 2>/dev/null)"
    owner="$(stat -c '%u' "$f" 2>/dev/null)"
    size="$(wc -c < "$f" 2>/dev/null)"

    local problems=()

    if [ "$PERM_ENFORCE" -eq 1 ]; then
      [ "$perm" = "600" ] || problems+=("权限 $perm（建议 600）")
    elif [ "$perm" != "600" ]; then
      warn "$name 权限 $perm —— 当前文件系统不保留权限位，已降级为警告"
    fi
    if [ -n "$CONTAINER_UID" ] && [ "$owner" != "$CONTAINER_UID" ]; then
      problems+=("属主 UID=$owner ≠ 容器 UID=$CONTAINER_UID")
    fi
    [ "${size:-0}" -gt 0 ] || problems+=("文件为空")

    if [ "${#problems[@]}" -eq 0 ]; then
      ok "$name  权限 $perm  属主 $owner  长度 $size  → 容器可读"
    else
      bad "$name  ${problems[*]}"
      if [ -n "$CONTAINER_UID" ]; then
        hint "修复： sudo chown $CONTAINER_UID:$CONTAINER_UID $f && chmod 600 $f"
      fi
      [ "$SELINUX" = "Enforcing" ] && hint "SELinux Enforcing：另需 sudo chcon -t container_file_t $f"
    fi
  done
  [ "$found" -eq 0 ] && warn "目录存在但未找到密钥文件（deepseek_api_key / scagent_token）"
}

[ -n "$EXPLICIT_DIR" ] && check_one_set "指定" "$EXPLICIT_DIR"
[ "$CHECK_DEV"  -eq 1 ] && check_one_set "开发环境" "${HOME}/.config/scagent"
if [ "$CHECK_PROD" -eq 1 ]; then
  PROD_DIR="$ROOT/deploy/secrets"
  if [ -f "$ROOT/deploy/.env" ]; then
    _d="$(sed -n 's/^[[:space:]]*SCAGENT_SECRETS_DIR[[:space:]]*=[[:space:]]*//p' "$ROOT/deploy/.env" | tail -1 | tr -d '"'"'"'\r')"
    case "$_d" in
      /*) PROD_DIR="$_d" ;;
      "") ;;
      *)  PROD_DIR="$ROOT/deploy/$_d" ;;
    esac
  fi
  check_one_set "生产环境" "$PROD_DIR"
fi

# ── 4. 项目内是否残留活密钥 ───────────────────────────────────────────────────
info "[4/4] 项目内活密钥残留检查"
# 只看会随 ..:/workspace 挂进容器的位置；gitignored 文件也算（这正是盲区）
LEAK=""
for f in "$ROOT/.env" "$ROOT"/.env.* ; do
  [ -f "$f" ] || continue
  case "$f" in *.sample) continue ;; esac
  if grep -qE 'sk-[A-Za-z0-9]{20,}' "$f" 2>/dev/null; then
    LEAK="$f"
  fi
done

if [ -z "$LEAK" ]; then
  ok "项目根目录未发现活密钥"
else
  bad "发现活密钥残留： $LEAK"
  hint "该文件会随 compose 的 ..:/workspace 挂进容器，"
  hint "使 Docker secrets 的安全收益归零（容器内任何进程都能读到）。"
  hint "修复： ./scripts/setup_secrets.sh --sanitize"
fi

# ── 汇总 ──────────────────────────────────────────────────────────────────────
printf '\n%s\n' "────────────────────────────────────────────────────────────"
printf '  通过 %s%d%s   警告 %s%d%s   失败 %s%d%s\n' \
  "$C_G" "$PASS" "$C_0" "$C_Y" "$WARN" "$C_0" "$C_R" "$FAIL" "$C_0"
if [ "$FAIL" -eq 0 ]; then
  printf '  %s\n' "${C_G}未发现阻塞问题${C_0}"
  exit 0
fi
printf '  %s\n' "${C_R}存在阻塞问题，请按上面提示修复${C_0}"
exit 1
