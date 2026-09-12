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
mem_gb=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || echo 0)
if [ "$mem_gb" -ge 32 ]; then    ok "内存 ${mem_gb} GB（推荐配置）"
elif [ "$mem_gb" -ge 16 ]; then  warn "内存 ${mem_gb} GB（可用，但并发请设为 1：SCAGENT_MAX_CONCURRENT_RUNS=1）"
elif [ "$mem_gb" -ge 8 ]; then   warn "内存 ${mem_gb} GB（偏紧。单个 Seurat 对象 1.6 GB，分析峰值数倍）"
else                             die  "内存仅 ${mem_gb} GB，不足以运行分析（建议 ≥16 GB）"; fi

# ── 磁盘 ──
disk_gb=$(df -BG --output=avail . 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
if [ "$disk_gb" -ge 50 ]; then   ok "磁盘可用 ${disk_gb} GB"
elif [ "$disk_gb" -ge 20 ]; then warn "磁盘可用仅 ${disk_gb} GB（镜像 ≈4–5 GB + 分析产物）"
else                             die  "磁盘可用仅 ${disk_gb} GB，不足（建议 ≥50 GB）"; fi

# ── CPU ──
cores=$(nproc 2>/dev/null || echo 1)
[ "$cores" -ge 8 ] && ok "CPU ${cores} 核" || warn "CPU ${cores} 核（分析会较慢，建议 ≥8 核）"

# ── 端口 ──
PORT="${SCAGENT_PORT:-8080}"
if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${PORT}$"; then
  warn "端口 ${PORT} 已被占用（可在 .env 中改 SCAGENT_PORT）"
else
  ok "端口 ${PORT} 空闲"
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
  printf '    SCAGENT_REGISTRY   （你的私有 registry，如 harbor.corp.local/scagent）\n'
  printf '    SCAGENT_VERSION    （镜像版本，如 1.0.0）\n\n'
  printf '  生成令牌可执行：\n'
  printf '    sed -i "s|^SCAGENT_TOKEN=.*|SCAGENT_TOKEN=%s|" deploy/.env\n\n' "$(openssl rand -hex 24 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  exit 0
fi

chmod 600 deploy/.env
ok "deploy/.env 已存在（权限 600）"

set -a; . deploy/.env; set +a
missing=""
for v in DEEPSEEK_API_KEY SCAGENT_TOKEN SCAGENT_REGISTRY SCAGENT_VERSION; do
  val="${!v:-}"
  case "$val" in
    ""|*请替换*|*example.com*|sk-请*|harbor.example.com*) missing="$missing $v" ;;
  esac
done
if [ -n "$missing" ]; then
  die "deploy/.env 中以下项仍是占位符或为空：$missing
      请编辑 deploy/.env 后再运行本脚本。"
fi
ok "必填项已填写"

# ═══════════════════════════════════════════════════════════════════════════════
# 3. 启动
# ═══════════════════════════════════════════════════════════════════════════════
info "[3/3] 拉起服务"
exec bash deploy/up.sh
