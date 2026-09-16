#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  deploy/lib/image-source.sh —— 镜像来源解析（bash 侧唯一实现）
#
#  作用：把 SCAGENT_IMAGE_SOURCE 解析成 [SCAGENT_IMAGE_PREFIX + SCAGENT_PULL_POLICY]，
#        并做公网回落防护。**所有** 需要镜像名的脚本都从这里取值 ——
#        这是 A4（命名空间不一致）的根治办法：全仓只有一套拼接规则。
#
#  用法：
#      set -a; . deploy/.env; set +a
#      . "$ROOT/deploy/lib/image-source.sh"
#      scagent_resolve_image          # → 导出 SCAGENT_IMAGE_PREFIX / SCAGENT_PULL_POLICY
#      img="$(scagent_image seurat)"  # → <prefix>/scagent-seurat:<version>
#      img="$(scagent_image runtime)"
#
#  来源语义：
#      local    本机 build 产物；前缀是本地镜像名（不得含 registry 主机名）；不拉取
#      public   公开发布的镜像；前缀默认 ghcr.io/17xxxx/scagent
#      private  自有 registry；前缀必须显式设置且含主机名
#
#  运行环境要求：SCAGENT_VERSION 必须已设置；die() 可省略（本文件会补一个兜底）。
# ═══════════════════════════════════════════════════════════════════════════════

# 兜底：调用方若没定义 die，则补一个（verify.sh 这类只统计不中断的脚本也能 source）
if ! declare -F die >/dev/null 2>&1; then
  die() { printf '  ❌ %s\n' "$*" >&2; exit 1; }
fi

# 失败出口：
#   默认 → die（直接退出；up.sh / install.sh / rollback.sh 期望的行为）
#   SCAGENT_LIB_SOFT_FAIL=1 → 只返回 1，让 verify.sh 这类"只统计不中断"的脚本能自己记一笔失败
_scagent_fail() {
  if [ "${SCAGENT_LIB_SOFT_FAIL:-0}" = "1" ]; then
    printf '  ❌ %s\n' "$*" >&2
    return 1
  fi
  die "$*"
}

# 公网 Docker Hub 命名空间：任何来源都不允许（防"偷偷摸公网"）
_scagent_reject_public_hub() {
  case "$1" in
    docker.io*|*.docker.io*|index.docker.io*|registry-1.docker.io*|library/*|*/library/*)
      _scagent_fail "拒绝使用公网 Docker Hub 命名空间：$1
      请改成自有 registry（如 harbor.corp.local/scagent）或公开发布前缀（如 ghcr.io/17xxxx/scagent）。" ;;
  esac
}

scagent_resolve_image() {
  local src="${SCAGENT_IMAGE_SOURCE:-local}"
  local prefix="${SCAGENT_IMAGE_PREFIX:-}"

  if [ -z "${SCAGENT_VERSION:-}" ]; then
    _scagent_fail "未设置 SCAGENT_VERSION（镜像标签，见 deploy/.env.sample）"
    return 1
  fi

  case "$src" in
    local)
      prefix="${prefix:-scagent}"
      _scagent_reject_public_hub "$prefix" || return 1
      case "$prefix" in
        *.*|*:*)
          _scagent_fail "local 模式的 SCAGENT_IMAGE_PREFIX 是本地镜像名，不应含 registry 主机名：$prefix
      若镜像来自 registry，请把 SCAGENT_IMAGE_SOURCE 改成 private 或 public。"
          return 1 ;;
      esac
      # local 强制不拉取 —— 即使 .env 里误留了 missing，也不会去公网找同名镜像
      SCAGENT_PULL_POLICY="never"
      ;;
    public)
      prefix="${prefix:-ghcr.io/17xxxx/scagent}"
      _scagent_reject_public_hub "$prefix" || return 1
      SCAGENT_PULL_POLICY="${SCAGENT_PULL_POLICY:-missing}"
      ;;
    private)
      if [ -z "$prefix" ]; then
      _scagent_fail "private 模式必须显式设置 SCAGENT_IMAGE_PREFIX（如 harbor.corp.local/scagent）"
      return 1
      fi
      _scagent_reject_public_hub "$prefix" || return 1
      case "$prefix" in
        *.*|*:*|localhost*) ;;
        *) _scagent_fail "private 模式的 SCAGENT_IMAGE_PREFIX 必须含 registry 主机名（含点或冒号）：$prefix"
           return 1 ;;
      esac
      SCAGENT_PULL_POLICY="${SCAGENT_PULL_POLICY:-missing}"
      ;;
    *)
      _scagent_fail "SCAGENT_IMAGE_SOURCE 只能是 local / public / private（当前：$src）"
      return 1 ;;
  esac

  SCAGENT_IMAGE_SOURCE="$src"
  # 三个变量都要导出：没有 deploy/.env 时（例如 build.sh 在未配置环境里跑），
  # docker compose 只能从进程环境里取插值变量 —— 漏一个就会报
  # "required variable ... is missing a value"（版本号曾漏掉，已修）。
  export SCAGENT_IMAGE_SOURCE SCAGENT_IMAGE_PREFIX="$prefix" \
         SCAGENT_VERSION="$SCAGENT_VERSION" SCAGENT_PULL_POLICY
}

# 拼镜像名：scagent_image seurat | scagent_image agent | scagent_image runtime
scagent_image() {
  : "${SCAGENT_IMAGE_PREFIX:?先调用 scagent_resolve_image}"
  : "${SCAGENT_VERSION:?未设置 SCAGENT_VERSION}"
  printf '%s/scagent-%s:%s' "$SCAGENT_IMAGE_PREFIX" "$1" "$SCAGENT_VERSION"
}

# 取 .env 的加载方式：统一去掉 Windows 编辑器可能带进来的 CR（C8）
#  用法：scagent_load_env deploy/.env
scagent_load_env() {
  local f="${1:-deploy/.env}"
  [ -f "$f" ] || die "缺少 $f"
  set -a
  # shellcheck disable=SC1090
  . <(tr -d '\r' < "$f")
  set +a
}

# 解析宿主机路径（调用方需先设置 $ROOT）：
#   /srv/scagent/...        → 绝对路径，原样返回
#   D:/scagent/...          → Windows 盘符路径
#   ../workspace、./secrets → 相对 deploy/ 解析（与 docker compose 的规则一致）
# 盘符路径在 WSL/Linux 上会直接报错 —— 否则会在 Linux 上建出一个名为 "D:" 的目录。
scagent_resolve_path() {
  local p="${1:-}"
  case "$p" in
    "")
      _scagent_fail "路径为空"
      return 1
      ;;
    [A-Za-z]:[\\/]*)
      if [ -n "${MSYSTEM:-}" ]; then printf '%s' "$p"; return 0; fi      # Git Bash：MSYS 认识盘符路径
      if grep -qi microsoft /proc/version 2>/dev/null; then
        _scagent_fail "检测到 Windows 盘符路径，但当前 shell 是 WSL/Linux：$p
      WSL 下请写成 /mnt/d/... （例：/mnt/d/scagent/workspace）；
      D:/... 形式请交给 Windows 侧的 deploy\\scagent.ps1 使用。"
        return 1
      fi
      printf '%s' "$p"
      ;;
    /*)
      printf '%s' "$p"
      ;;
    *)
      printf '%s' "${ROOT:?scagent_resolve_path 需要调用方先设置 ROOT}/deploy/${p#./}"
      ;;
  esac
}
