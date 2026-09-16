#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  deploy/install.sh —— 服务器首次部署
#
#  做三件事：
#    1. 环境体检（Docker / 内存 / 磁盘 / 端口 / 出网）
#    2. 生成或检查 deploy/.env
#    3. 调用 up.sh 拉镜像并启动
#
#  用法：
#      ./deploy/install.sh                 # 完整流程
#      ./deploy/install.sh --check-only    # 只做环境体检
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHECK_ONLY=0
[ "${1:-}" = "--check-only" ] && CHECK_ONLY=1

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
info() { printf '\n%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '  %s\n' "${C_G}✅${C_0} $*"; }
warn() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; }
die()  { printf '  %s\n' "${C_R}❌${C_0} $*" >&2; exit 1; }

# 共享库：镜像来源解析 + .env 安全加载（去 CR）
# shellcheck source=lib/image-source.sh
. "$ROOT/deploy/lib/image-source.sh"

printf '\n%s\n' "════════════════════════════════════════════════════════════"
printf '%s\n'   "  scAgent 安装向导"
printf '%s\n'   "════════════════════════════════════════════════════════════"

# ═══════════════════════════════════════════════════════════════════════════════
# 1. 环境体检
# ═══════════════════════════════════════════════════════════════════════════════
info "[1/3] 环境体检"

# ── Docker ──
if ! command -v docker >/dev/null 2>&1; then
  die "未安装 Docker。Ubuntu/Debian 一键安装：
      curl -fsSL https://get.docker.com | sudo sh
      sudo usermod -aG docker \$USER && newgrp docker"
fi
ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"

if ! docker compose version >/dev/null 2>&1; then
  die "缺少 docker compose 插件（需要 v2）。请升级 Docker 或安装 docker-compose-plugin。"
fi
ok "$(docker compose version | head -1)"

if ! docker info >/dev/null 2>&1; then
  die "无法连接 Docker 守护进程。可能原因：
      · 当前用户不在 docker 组：sudo usermod -aG docker \$USER && newgrp docker
      · 服务未启动：sudo systemctl start docker"
fi
ok "Docker 守护进程可访问"

# ── 内存 ──
# 优先问 Docker 引擎（WSL2 的 /proc/meminfo 是 WSL VM 的内存，与 Docker VM 不是一回事，见 C5）
mem_bytes="$(docker info -f '{{.MemTotal}}' 2>/dev/null | tr -dc '0-9' || true)"
if [ -n "$mem_bytes" ] && [ "$mem_bytes" -gt 0 ] 2>/dev/null; then
  mem_gb=$((mem_bytes / 1073741824)); mem_src="Docker 引擎"
else
  mem_gb=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || echo 0)
  mem_src="/proc/meminfo（估算，Docker 未就绪）"
fi
if [ "$mem_gb" -ge 32 ]; then    ok "内存 ${mem_gb} GB（推荐配置，来源 $mem_src）"
elif [ "$mem_gb" -ge 16 ]; then  warn "内存 ${mem_gb} GB（可用，但并发请设为 1：SCAGENT_MAX_CONCURRENT_RUNS=1，来源 $mem_src）"
elif [ "$mem_gb" -ge 8 ]; then   warn "内存 ${mem_gb} GB（偏紧。单个 Seurat 对象 1.6 GB，分析峰值数倍，来源 $mem_src）"
else                             die  "内存仅 ${mem_gb} GB，不足以运行分析（建议 ≥16 GB，来源 $mem_src）"; fi

# ── 磁盘 ──
# 镜像落在 Docker 的数据根（Windows 上是 vhdx，默认在 C 盘），产物落在工作目录 —— 两个都要看
check_disk() {   # check_disk <路径> <标签>
  local path="$1" label="$2" gb
  [ -d "$path" ] || return 0
  gb=$(df -BG --output=avail "$path" 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
  [ -z "$gb" ] && return 0
  if [ "$gb" -ge 50 ]; then        ok "$label 可用 ${gb} GB（$path）"
  elif [ "$gb" -ge 20 ]; then      warn "$label 可用仅 ${gb} GB（$path；镜像 ≈4–5 GB + 分析产物）"
  else                             die  "$label 可用仅 ${gb} GB，不足（建议 ≥50 GB；$path）"; fi
}
docker_root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null | tr -d '\r' || true)"
check_disk "${docker_root:-/var/lib/docker}" "Docker 数据盘"
check_disk . "项目/工作盘"

# ── CPU ──
cores="$(docker info -f '{{.NCPU}}' 2>/dev/null | tr -dc '0-9' || true)"
[ -n "$cores" ] || cores=$(nproc 2>/dev/null || echo 1)
[ "$cores" -ge 8 ] && ok "CPU ${cores} 核" || warn "CPU ${cores} 核（分析会较慢，建议 ≥8 核）"

# ── 端口 ──
# ss 在 Git Bash / 精简发行版里可能不存在；退化为"端口是否已被本机进程监听"的保守判断
PORT="${SCAGENT_PORT:-8080}"
if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${PORT}$"; then
    warn "端口 ${PORT} 已被占用（可在 .env 中改 SCAGENT_PORT）"
  else
    ok "端口 ${PORT} 空闲"
  fi
elif command -v lsof >/dev/null 2>&1; then
  if lsof -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    warn "端口 ${PORT} 已被占用（可在 .env 中改 SCAGENT_PORT）"
  else
    ok "端口 ${PORT} 空闲"
  fi
else
  warn "无法检测端口 ${PORT}（缺少 ss / lsof）—— 若启动失败请先确认端口未被占用"
fi

# ── 出网（唯一允许的外部依赖：LLM）──
if curl -4 -s -o /dev/null -m 10 -w '%{http_code}' https://api.deepseek.com/v1/models 2>/dev/null | grep -qE '^(200|401|403)$'; then
  ok "LLM 端点可达（api.deepseek.com）"
else
  warn "无法访问 api.deepseek.com —— agent 将无法规划分析步骤。
      若已改用本地模型，请忽略；否则请检查安全组/代理。"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  info "仅体检模式，结束"
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 2. 配置
# ═══════════════════════════════════════════════════════════════════════════════
info "[2/3] 配置 deploy/.env"

if [ ! -f deploy/.env ]; then
  cp deploy/.env.sample deploy/.env
  chmod 600 deploy/.env
  warn "已从模板生成 deploy/.env，但其中是占位符，必须填写后才能启动。"
  printf '\n  请编辑 deploy/.env，至少填写这 4 项：\n'
  printf '    DEEPSEEK_API_KEY   （https://platform.deepseek.com/api_keys）\n'
  printf '    SCAGENT_TOKEN      （生成：openssl rand -hex 24）\n'
  printf '    SCAGENT_IMAGE_SOURCE + SCAGENT_IMAGE_PREFIX\n'
  printf '                       （local 本机构建 / public 公开发布 / private 自有 registry）\n'
  printf '    SCAGENT_VERSION    （镜像版本，如 1.0.0）\n\n'
  printf '  另外必须设置（绝对路径，Windows 用 D:/... 形式）：\n'
  printf '    SCAGENT_WORKSPACE、SCAGENT_BIODATA、SCAGENT_SECRETS_DIR\n\n'
  printf '  生成令牌可执行：\n'
  printf '    sed -i "s|^SCAGENT_TOKEN=.*|SCAGENT_TOKEN=%s|" deploy/.env\n\n' "$(openssl rand -hex 24 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  exit 0
fi

chmod 600 deploy/.env
ok "deploy/.env 已存在（权限 600）"

scagent_load_env deploy/.env

# 判断密钥走 secrets 还是环境变量
_sd="${SCAGENT_SECRETS_DIR:-./secrets}"
case "$_sd" in /*) ;; *) _sd="$ROOT/${_sd#./}" ;; esac
if [ -f "$_sd/deepseek_api_key" ] && [ -f "$_sd/scagent_token" ]; then
  ok "检测到 Docker secrets：$_sd（密钥无需写进 deploy/.env）"
  REQUIRED="SCAGENT_VERSION SCAGENT_WORKSPACE SCAGENT_BIODATA"
else
  ok "密钥方式：环境变量（deploy/.env）"
  REQUIRED="DEEPSEEK_API_KEY SCAGENT_TOKEN SCAGENT_VERSION SCAGENT_WORKSPACE SCAGENT_BIODATA"
fi

missing=""
for v in $REQUIRED; do
  val="${!v:-}"
  case "$val" in
    ""|*请替换*|*example.com*|sk-请*|harbor.example.com*) missing="$missing $v" ;;
  esac
done
if [ -n "$missing" ]; then
  die "以下必填项仍是占位符或为空：$missing
      请编辑 deploy/.env 后再运行本脚本。
      若想改用 Docker secrets（推荐），执行：
          ./scripts/setup_secrets.sh --target \$SCAGENT_SECRETS_DIR"
fi
ok "必填项已填写"

# 镜像来源解析（local / public / private）—— 只在这里推导前缀与拉取策略
scagent_resolve_image
ok "镜像来源: $SCAGENT_IMAGE_SOURCE（前缀 $SCAGENT_IMAGE_PREFIX，策略 $SCAGENT_PULL_POLICY）"

# ═══════════════════════════════════════════════════════════════════════════════
# 3. 启动
# ═══════════════════════════════════════════════════════════════════════════════
info "[3/3] 拉起服务"
exec bash deploy/up.sh
