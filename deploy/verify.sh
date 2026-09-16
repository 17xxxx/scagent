#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  deploy/verify.sh —— 部署自检
#
#  逐项检查部署是否可用，并对失败项给出中文处置建议。
#  其中包含三项分发相关的检查：
#    · 默认值不回落到公网（compose 变量必填）
#    · 镜像中不含参考数据（.rds）
#    · 参考集缺失时快速失败
# ═══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 共享库：镜像来源解析（软失败模式 —— 本脚本只统计、不中断）
SCAGENT_LIB_SOFT_FAIL=1
export SCAGENT_LIB_SOFT_FAIL
# shellcheck source=lib/image-source.sh
. "$ROOT/deploy/lib/image-source.sh"

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
  scagent_load_env deploy/.env
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

# ── 镜像来源配置 ──────────────────────────────────────────────────────────────
item "镜像来源配置"
if scagent_resolve_image 2>/dev/null; then
  pass "$SCAGENT_IMAGE_SOURCE → $SCAGENT_IMAGE_PREFIX（pull=$SCAGENT_PULL_POLICY）"
else
  fail "SCAGENT_IMAGE_SOURCE / SCAGENT_IMAGE_PREFIX 无效（详见 deploy/.env.sample）"
fi

# ── V2：compose 变量必填，不会静默回落公网 ────────────────────────────────────
#  用空 env 文件 + 清空相关变量，确保测的是 compose 自己的 `:?` 守卫，
#  而不是被 deploy/.env 里的值"帮"过去了；同时校验报错信息里确实提到必填变量，
#  否则可能因为别的原因失败而"假通过"。
item "V2 compose 强制要求镜像与路径变量"
V2_OUT="$( env -u SCAGENT_IMAGE_PREFIX -u SCAGENT_VERSION -u SCAGENT_WORKSPACE -u SCAGENT_BIODATA \
             docker compose --env-file /dev/null -f deploy/docker-compose.yml config 2>&1 )"
V2_RC=$?
if [ "$V2_RC" -eq 0 ]; then
  fail "未设置 SCAGENT_IMAGE_PREFIX / SCAGENT_VERSION / SCAGENT_WORKSPACE / SCAGENT_BIODATA 时 compose 竟然通过了"
elif printf '%s' "$V2_OUT" | grep -qE 'SCAGENT_IMAGE_PREFIX|SCAGENT_VERSION|SCAGENT_WORKSPACE|SCAGENT_BIODATA|required variable|必须设置'; then
  pass "缺变量时报错，且提示了变量名"
else
  warn "报错了，但原因不是必填变量（请人工确认）：$(printf '%s' "$V2_OUT" | head -2 | tr '\n' ' ')"
fi

# ── 是否部署过 ────────────────────────────────────────────────────────────────
#  没部署过时，不要把"容器 0 个 / 健康无响应"报成阻塞 —— 那是还没装，不是坏了
COMPOSE="docker compose -f deploy/docker-compose.yml"
DEPLOYED=0
if [ -n "${SCAGENT_IMAGE_PREFIX:-}" ] && [ -n "${SCAGENT_VERSION:-}" ]; then
  if [ "$( $COMPOSE ps -q 2>/dev/null | wc -l )" -gt 0 ] 2>/dev/null; then
    DEPLOYED=1
  elif docker image inspect "$(scagent_image seurat)" >/dev/null 2>&1 \
    || docker image inspect "$(scagent_image agent)"  >/dev/null 2>&1; then
    DEPLOYED=1
  fi
fi
item "部署状态"
if [ "$DEPLOYED" -eq 1 ]; then pass "已部署过"; else warn "尚未部署（没有容器，也没找到本地镜像）"; fi

# ── 容器状态 ──────────────────────────────────────────────────────────────────
if $COMPOSE ps -q >/dev/null 2>&1; then
  # "运行中"必须按 State=running 数 —— `ps -q` 会把崩溃重启的容器也算进去
  running=$($COMPOSE ps --status running -q 2>/dev/null | wc -l)
  item "运行中的容器"
  if [ "$running" -ge 2 ]; then pass "$running 个"
  elif [ "$DEPLOYED" -eq 0 ]; then warn "未部署（先运行 ./deploy/up.sh）"
  else fail "只有 $running 个（期望 2）"; fi

  # 健康判定见 up.sh 里的同名注释：只看 "unhealthy" 会漏掉崩溃重启
  # （那种容器没有 Health 字段）。这里同时校验 State 与 Health。
  ps_json="$($COMPOSE ps --format json 2>/dev/null || true)"
  bad_state="$(printf '%s\n' "$ps_json" | grep -oE '"State":"[a-z]+"' | grep -cv '"State":"running"' || true)"
  bad_health="$(printf '%s\n' "$ps_json" | grep -oE '"Health":"[a-z]+"' | grep -cv '"Health":"healthy"' || true)"
  item "容器健康状态"
  if [ "$running" -eq 0 ] && [ "$DEPLOYED" -eq 0 ]; then warn "未部署"
  elif [ "${bad_state:-0}" -eq 0 ] && [ "${bad_health:-0}" -eq 0 ]; then pass "全部 running 且 healthy"
  else
    fail "有容器未在运行或未达 healthy（未运行 ${bad_state:-0} 个 / 不健康 ${bad_health:-0} 个）"
    printf '%s\n' "  排查提示： docker compose -f deploy/docker-compose.yml logs --tail 100 agent"
  fi
else
  item "容器状态"; warn "docker compose 不可用或 Docker 未启动"
fi

# ── agent 服务 ────────────────────────────────────────────────────────────────
PORT="${SCAGENT_PORT:-8080}"
BASE="http://127.0.0.1:${PORT}"

item "agent /v1/health（带鉴权）"
HEALTH=$(curl -s -m 15 -H "Authorization: Bearer ${SCAGENT_TOKEN:-}" "$BASE/v1/health" 2>/dev/null || echo "")
if [ -n "$HEALTH" ] && ! printf '%s' "$HEALTH" | grep -q '"detail"'; then
  pass "$(printf '%s' "$HEALTH" | head -c 90)…"
elif [ "$DEPLOYED" -eq 0 ]; then
  warn "未部署（服务未启动）"
else
  fail "无响应或鉴权失败：$(printf '%s' "$HEALTH" | head -c 120)"
fi

item "未带令牌应被拒绝（401）"
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$BASE/v1/health" 2>/dev/null || echo 000)
if [ "$code" = "401" ]; then pass "401"
elif [ "$DEPLOYED" -eq 0 ]; then warn "未部署（服务未启动）"
else fail "返回 $code（期望 401）"; fi

item "内置网页界面"
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$BASE/" 2>/dev/null || echo 000)
if [ "$code" = "200" ]; then pass "可访问"
elif [ "$DEPLOYED" -eq 0 ]; then warn "未部署（服务未启动）"
else warn "返回 $code"; fi

# ── seurat 服务 ───────────────────────────────────────────────────────────────
if [ "$DEPLOYED" -eq 0 ]; then
  item "seurat /api/ping"; warn "未部署（服务未启动）"
else
  PING=$($COMPOSE exec -T seurat Rscript -e \
    "cat(tryCatch(jsonlite::toJSON(jsonlite::fromJSON('http://127.0.0.1:9000/api/ping')), error=function(e) 'FAIL'))" \
    2>/dev/null || echo "")
# 注意：plumber/jsonlite 把标量序列化成**数组**（"status":["ok"]），不是 "status":"ok"
  if printf '%s' "$PING" | grep -qE '"status"[[:space:]]*:[[:space:]]*\[?"ok"'; then
    rver=$(printf '%s' "$PING" \
             | grep -oE '"r_version"[[:space:]]*:[[:space:]]*\[?"[^"]*"' \
             | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    item "seurat /api/ping"
    pass "ok（R ${rver:-未知}，data_dir=$(printf '%s' "$PING" | grep -oE '"data_dir"[[:space:]]*:[[:space:]]*\[?"[^"]*"' | cut -d'"' -f4)）"
  else
    item "seurat /api/ping"
    fail "无响应：$(printf '%s' "$PING" | head -c 100)"
  fi
fi

# ── V3：镜像内不含参考数据 ────────────────────────────────────────────────────
item "V3 镜像内无 .rds"
if [ -n "${SCAGENT_IMAGE_PREFIX:-}" ] && [ -n "${SCAGENT_VERSION:-}" ]; then
  found=$(docker run --rm --entrypoint sh \
            "$(scagent_image seurat)" \
            -c 'find /workspace \( -name "*.rds" -o -name "*.RDS" \) 2>/dev/null | head -3' 2>/dev/null || echo "SKIP")
  if [ "$found" = "SKIP" ] || [ -z "$found" ]; then
    [ "$found" = "SKIP" ] && warn "无法检查（镜像不在本地）" || pass "无 .rds 文件"
  else
    fail "发现参考数据文件：$found"
  fi
else
  warn "跳过（未配置镜像前缀 / 版本）"
fi

# ── 参考数据卷 ────────────────────────────────────────────────────────────────
BIODATA="${SCAGENT_BIODATA:-}"
item "参考数据目录"
if [ -z "$BIODATA" ]; then
  warn "未设置 SCAGENT_BIODATA（deploy/.env）"
elif [ -d "$BIODATA" ]; then
  n=$(find "$BIODATA" -name "*.rds" 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] && pass "$n 个 .rds" || warn "目录存在但没有 .rds（请跑 download_data.sh）"
else
  warn "不存在：$BIODATA —— 细胞注释会失败；一次性获取： ./scripts/fetch_refdata.sh"
fi

# ── 数据目录 ──────────────────────────────────────────────────────────────────
# 路径解析统一走共享库（相对路径以 deploy/ 为基准；Windows 盘符路径在 WSL 下会报错）
WORKSPACE="$(scagent_resolve_path "${SCAGENT_WORKSPACE:-}" 2>/dev/null || true)"
item "10X 原始数据"
if [ -z "$WORKSPACE" ]; then
  warn "未设置 SCAGENT_WORKSPACE（deploy/.env）"
else
  n=$(find "$WORKSPACE/data/rawdata" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] && pass "$n 个样本目录" || warn "暂无样本（放入 $WORKSPACE/data/rawdata/<样本名>/）"
fi

# ── 数据目录属主 ──────────────────────────────────────────────────────────────
#   seurat 容器以 uid 1000 运行；数据目录里若有 root 所有的文件，容器会写不进去。
#   Git Bash / Windows 下无 POSIX 属主语义，跳过。
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) : ;;
  *)
    if [ -n "$WORKSPACE" ] && [ -d "$WORKSPACE" ]; then
      item "数据目录属主"
      me="$(id -u)"
      foreign=$(find "$WORKSPACE" -maxdepth 3 \! -uid "$me" 2>/dev/null | head -5 | wc -l)
      if [ "${foreign:-0}" -eq 0 ]; then
        pass "全部属于当前用户（uid $me）"
      else
        warn "有 $(find "$WORKSPACE" -maxdepth 3 \! -uid "$me" 2>/dev/null | wc -l) 个条目不属于 uid $me"
        printf '      容器以 uid %s 运行时可能写不进去；修复： sudo chown -R %s:%s %s\n' \
               "$me" "$me" "$(id -g)" "$WORKSPACE"
      fi
    fi
    ;;
esac

# ── 汇总 ──────────────────────────────────────────────────────────────────────
printf '\n%s\n' "────────────────────────────────────────────────────────────"
printf '  通过 %s%d%s   警告 %s%d%s   失败 %s%d%s\n' \
  "$C_G" "$PASS" "$C_0" "$C_Y" "$WARN" "$C_0" "$C_R" "$FAIL" "$C_0"

if [ "$DEPLOYED" -eq 0 ]; then
  printf '%s\n' "  结论：${C_Y}尚未部署${C_0} —— 先运行 ./deploy/up.sh（或 ./deploy/install.sh）"
  printf '%s\n' "        上面标「未部署」的项不是故障；装完再跑一次本脚本即可复检。"
  exit 1
elif [ "$FAIL" -eq 0 ]; then
  printf '%s\n' "  结论：${C_G}可以正常使用${C_0}"
  exit 0
else
  printf '%s\n' "  结论：${C_R}存在阻塞问题${C_0} —— 请按上面提示逐项处理"
  printf '%s\n' "  排查提示： docker compose -f deploy/docker-compose.yml logs --tail 100 seurat"
  exit 1
fi
