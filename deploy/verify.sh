#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  deploy/verify.sh —— 部署自检
#
#  逐项检查部署是否可用，并对失败项给出中文处置建议。
#  同时覆盖方案中的 Vendoring 专项验收项：
#    V2  默认值不回落到公网（compose 变量必填）
#    V3  镜像中不含参考数据（.rds）
#    V7  参考集缺失时快速失败
# ═══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
PASS=0; FAIL=0; WARN=0
item() { printf '  %-34s' "$1"; }
pass() { printf '%s\n' "${C_G}✅${C_0} $*"; PASS=$((PASS+1)); }
fail() { printf '%s\n' "${C_R}❌${C_0} $*"; FAIL=$((FAIL+1)); }
warn() { printf '%s\n' "${C_Y}⚠️ ${C_0} $*"; WARN=$((WARN+1)); }

printf '\n%s\n' "════════════════════════════════════════════════════════════"
printf '%s\n'   "  scAgent 部署自检"
printf '%s\n\n' "════════════════════════════════════════════════════════════"

# ── 配置 ──────────────────────────────────────────────────────────────────────
if [ -f deploy/.env ]; then
  set -a; . deploy/.env; set +a
  # 若走 Docker secrets，deploy/.env 里没有 SCAGENT_TOKEN，从宿主侧文件补上
  if [ -z "${SCAGENT_TOKEN:-}" ]; then
    _sd="${SCAGENT_SECRETS_DIR:-./secrets}"
    case "$_sd" in /*) ;; *) _sd="$ROOT/${_sd#./}" ;; esac
    [ -f "$_sd/scagent_token" ] && SCAGENT_TOKEN="$(cat "$_sd/scagent_token")"
  fi
  item "配置文件 deploy/.env"
  pass "已加载"
  perms=$(stat -c '%a' deploy/.env 2>/dev/null || echo "?")
  item ".env 权限"
  [ "$perms" = "600" ] && pass "600" || warn "当前 $perms（建议 chmod 600）"
else
  item "配置文件 deploy/.env"; fail "缺失（cp deploy/.env.sample deploy/.env）"
fi

# ── V2：compose 变量必填，不会静默回落公网 ────────────────────────────────────
item "V2 compose 强制要求 SCAGENT_REGISTRY"
if ( unset SCAGENT_REGISTRY; docker compose -f deploy/docker-compose.yml config >/dev/null 2>&1 ); then
  fail "未设置 SCAGENT_REGISTRY 时 compose 竟然通过了 —— 存在回落公网风险"
else
  pass "未设置时正确报错"
fi

# ── 容器状态 ──────────────────────────────────────────────────────────────────
COMPOSE="docker compose -f deploy/docker-compose.yml"
if $COMPOSE ps -q >/dev/null 2>&1; then
  running=$($COMPOSE ps -q | wc -l)
  item "运行中的容器"
  [ "$running" -ge 2 ] && pass "$running 个" || fail "只有 $running 个（期望 2）"

  unhealthy=$($COMPOSE ps --format json 2>/dev/null | grep -c '"unhealthy"' || true)
  item "容器健康状态"
  [ "${unhealthy:-0}" -eq 0 ] && pass "全部 healthy" \
    || fail "$unhealthy 个 unhealthy（docker compose logs 查看）"
else
  item "容器状态"; fail "docker compose 不可用或未启动"
fi

# ── agent 服务 ────────────────────────────────────────────────────────────────
PORT="${SCAGENT_PORT:-8080}"
BASE="http://127.0.0.1:${PORT}"

item "agent /v1/health（带鉴权）"
HEALTH=$(curl -s -m 15 -H "Authorization: Bearer ${SCAGENT_TOKEN:-}" "$BASE/v1/health" 2>/dev/null || echo "")
if [ -n "$HEALTH" ] && ! printf '%s' "$HEALTH" | grep -q '"detail"'; then
  pass "$(printf '%s' "$HEALTH" | head -c 90)…"
else
  fail "无响应或鉴权失败：$(printf '%s' "$HEALTH" | head -c 120)"
fi

item "未带令牌应被拒绝（401）"
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$BASE/v1/health" 2>/dev/null || echo 000)
[ "$code" = "401" ] && pass "401" || fail "返回 $code（期望 401）"

item "内置网页界面"
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$BASE/" 2>/dev/null || echo 000)
[ "$code" = "200" ] && pass "可访问" || warn "返回 $code"

# ── seurat 服务 ───────────────────────────────────────────────────────────────
item "seurat /api/ping"
PING=$($COMPOSE exec -T seurat Rscript -e \
  "cat(tryCatch(jsonlite::toJSON(jsonlite::fromJSON('http://127.0.0.1:9000/api/ping')), error=function(e) 'FAIL'))" \
  2>/dev/null || echo "")
printf '\r'
if printf '%s' "$PING" | grep -q '"status":"ok"'; then
  item "seurat /api/ping"
  pass "ok（R $(printf '%s' "$PING" | grep -o '"r_version":"[^"]*"' | cut -d'"' -f4)）"
else
  item "seurat /api/ping"
  fail "无响应：$(printf '%s' "$PING" | head -c 100)"
fi

# ── V3：镜像内不含参考数据 ────────────────────────────────────────────────────
item "V3 镜像内无 .rds"
if [ -n "${SCAGENT_REGISTRY:-}" ] && [ -n "${SCAGENT_VERSION:-}" ]; then
  found=$(docker run --rm --entrypoint sh \
            "${SCAGENT_REGISTRY}/scagent-seurat:${SCAGENT_VERSION}" \
            -c 'find / -name "*.rds" -o -name "*.RDS" 2>/dev/null | head -3' 2>/dev/null || echo "SKIP")
  if [ "$found" = "SKIP" ] || [ -z "$found" ]; then
    [ "$found" = "SKIP" ] && warn "无法检查（镜像不在本地）" || pass "无 .rds 文件"
  else
    fail "发现参考数据文件：$found"
  fi
else
  warn "跳过（未配置 registry/version）"
fi

# ── 参考数据卷 ────────────────────────────────────────────────────────────────
BIODATA="${SCAGENT_BIODATA:-/data/biodata}"
item "参考数据目录 $BIODATA"
if [ -d "$BIODATA" ]; then
  n=$(find "$BIODATA" -name "*.rds" 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] && pass "$n 个 .rds" || warn "目录存在但没有 .rds（请跑 download_data.sh）"
else
  warn "不存在 —— 细胞注释会失败，请跑 scripts/download_data.sh"
fi

# ── 数据目录 ──────────────────────────────────────────────────────────────────
# 相对路径统一以 deploy/ 为基准（与 docker compose 的解析规则一致）
resolve_workspace() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s' "$ROOT/deploy/$1" ;;
  esac
}

WORKSPACE="$(resolve_workspace "${SCAGENT_WORKSPACE:-../workspace}")"
item "10X 原始数据"
n=$(find "$WORKSPACE/data/rawdata" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
[ "$n" -gt 0 ] && pass "$n 个样本目录" || warn "暂无样本（放入 $WORKSPACE/data/rawdata/<样本名>/）"

# ── 汇总 ──────────────────────────────────────────────────────────────────────
printf '\n%s\n' "────────────────────────────────────────────────────────────"
printf '  通过 %s%d%s   警告 %s%d%s   失败 %s%d%s\n' \
  "$C_G" "$PASS" "$C_0" "$C_Y" "$WARN" "$C_0" "$C_R" "$FAIL" "$C_0"

if [ "$FAIL" -eq 0 ]; then
  printf '%s\n' "  结论：${C_G}可以正常使用${C_0}"
  exit 0
else
  printf '%s\n' "  结论：${C_R}存在阻塞问题${C_0} —— 请按上面提示逐项处理"
  printf '%s\n' "  排查提示： docker compose -f deploy/docker-compose.yml logs --tail 100 seurat"
  exit 1
fi
