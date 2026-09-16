#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  deploy/doctor.sh —— 部署体检（中文报告 + 修复建议）
#
#  与 verify.sh 的分工：
#    · doctor  —— 环境与配置**能不能跑起来**（Docker/资源/端口/镜像/密钥/数据/网络）
#    · verify  —— 服务**本身是否可用**（容器健康、端点、令牌、产物目录）
#  两者互补：装之前跑 doctor，装之后跑 verify；出问题先 doctor 再 verify。
#
#  用法：
#      ./deploy/doctor.sh              # 完整体检
#      ./deploy/doctor.sh --quick      # 跳过网络连通性与容器探测（快）
#
#  退出码：0 全部通过 · 1 环境不满足 · 2 配置错误 · 3 运行期/服务问题
#  ⚠️ 本脚本**只读**：不修改配置、不启停容器、不做备份。
# ═══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_D=$'\033[2m'; C_0=$'\033[0m'
PASS=0; WARN=0; FAIL=0
ENV_BAD=0; CFG_BAD=0; SVC_BAD=0

item()  { printf '  %-30s' "$1"; }
pass()  { printf '%s\n' "${C_G}✅${C_0} $*"; PASS=$((PASS+1)); }
warn()  { printf '%s\n' "${C_Y}⚠️ ${C_0} $*"; WARN=$((WARN+1)); }
fail()  { printf '%s\n' "${C_R}❌${C_0} $*"; FAIL=$((FAIL+1)); }
hint()  { printf '      %s%s%s\n' "$C_D" "$*" "$C_0"; }
group() { printf '\n%s\n' "${C_B}── $* ──${C_0}"; }

printf '\n%s\n' "════════════════════════════════════════════════════════════"
printf '%s\n'   "  scAgent 部署体检（doctor）"
printf '%s\n'   "════════════════════════════════════════════════════════════"

# 共享库（软失败：本脚本只统计不中断）
SCAGENT_LIB_SOFT_FAIL=1
export SCAGENT_LIB_SOFT_FAIL
# shellcheck source=lib/image-source.sh
. "$ROOT/deploy/lib/image-source.sh"

ENV_FILE="deploy/.env"

# ── 1. 环境与资源 ─────────────────────────────────────────────────────────────
group "1. 环境与资源"

if command -v docker >/dev/null 2>&1; then
  pass "docker CLI $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,)"
else
  fail "未找到 docker 命令 —— 请先安装 Docker Desktop / Docker Engine"; ENV_BAD=1
  hint "Windows： https://www.docker.com/products/docker-desktop/"
  hint "Linux  ： curl -fsSL https://get.docker.com | sudo sh"
fi

if docker compose version >/dev/null 2>&1; then
  pass "$(docker compose version 2>/dev/null | head -1)"
else
  fail "缺少 docker compose 插件（需要 v2）"; ENV_BAD=1
fi

DOCKER_OK=0
if docker info >/dev/null 2>&1; then
  DOCKER_OK=1
  pass "Docker 守护进程可访问"
else
  fail "无法连接 Docker 守护进程"; ENV_BAD=1
  hint "Windows：确认 Docker Desktop 已启动（任务栏鲸鱼图标为绿色）"
  hint "Linux  ： sudo systemctl start docker（并确认当前用户在 docker 组）"
fi

if [ "$DOCKER_OK" -eq 1 ]; then
  mem_bytes="$(docker info -f '{{.MemTotal}}' 2>/dev/null | tr -dc '0-9' || true)"
  if [ -n "$mem_bytes" ] && [ "$mem_bytes" -gt 0 ] 2>/dev/null; then
    mem_gb=$((mem_bytes / 1073741824))
    if   [ "$mem_gb" -ge 32 ]; then pass "可用内存 ${mem_gb} GB（推荐）"
    elif [ "$mem_gb" -ge 16 ]; then warn "可用内存 ${mem_gb} GB（可用；并发建议设为 1）"
    else warn "可用内存仅 ${mem_gb} GB（单个 Seurat 对象约 1.6 GB）"; fi
  else
    warn "无法从 Docker 读取内存信息"
  fi

  items_n="$(docker info -f '{{.NCPU}}' 2>/dev/null | tr -dc '0-9' || true)"
  [ -n "$items_n" ] && { [ "$items_n" -ge 8 ] && pass "可用 CPU ${items_n} 核" || warn "可用 CPU ${items_n} 核（建议 ≥8）"; }

  docker_root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null | tr -d '\r' || true)"
  if [ -n "$docker_root" ] && [ -d "$docker_root" ]; then
    dgb=$(df -BG --output=avail "$docker_root" 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
    [ -n "$dgb" ] && { [ "$dgb" -ge 20 ] && pass "镜像盘可用 ${dgb} GB" || warn "镜像盘可用仅 ${dgb} GB（镜像约 4–10 GB）"; }
  fi
fi

PORT="${SCAGENT_PORT:-8080}"
port_busy=0
if command -v ss >/dev/null 2>&1; then
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${PORT}$" && port_busy=1
elif command -v lsof >/dev/null 2>&1; then
  lsof -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1 && port_busy=1
fi
if [ "$port_busy" -eq 1 ]; then
  # 端口被占用可能是"服务正在跑"，不一定是问题
  warn "端口 ${PORT} 已被占用（若服务已在运行属正常；否则请改 SCAGENT_PORT）"
else
  pass "端口 ${PORT} 空闲"
fi

# ── 2. 配置 ───────────────────────────────────────────────────────────────────
group "2. 配置（deploy/.env）"

if [ ! -f "$ENV_FILE" ]; then
  fail "缺少 deploy/.env"; CFG_BAD=1
  hint "Linux ： cp deploy/.env.sample deploy/.env && chmod 600 deploy/.env"
  hint "Windows： deploy\\install.cmd（会自动生成）"
else
  scagent_load_env "$ENV_FILE"
  pass "已加载（$(grep -cvE '^\s*(#|$)' "$ENV_FILE" 2>/dev/null || echo '?') 个有效项）"

  # 注意：**不能**写成 image_info="$(scagent_resolve_image)" —— 命令替换是子 shell，
  # 它在里面导出的 SCAGENT_IMAGE_PREFIX / SCAGENT_PULL_POLICY 回不到父 shell，
  # 而 doctor 用 set -u，那些变量就成了 unbound（手写 .env 未写 SCAGENT_PULL_POLICY 时会直接中断）。
  # verify.sh 用的是"直接调用"，这里保持一致。
  if scagent_resolve_image 2>/dev/null; then
    pass "镜像来源 $SCAGENT_IMAGE_SOURCE → $SCAGENT_IMAGE_PREFIX:$SCAGENT_VERSION（pull=$SCAGENT_PULL_POLICY）"
  else
    fail "镜像来源配置无效（SCAGENT_IMAGE_SOURCE / PREFIX / VERSION）"; CFG_BAD=1
  fi

  for k in SCAGENT_WORKSPACE SCAGENT_BIODATA; do
    item "必填项 $k"
    if [ -n "$(eval printf '%s' "\${$k:-}")" ]; then pass "已设置"; else fail "未设置"; CFG_BAD=1; fi
  done
fi

# ── 3. 镜像 ───────────────────────────────────────────────────────────────────
group "3. 镜像"

if [ "$DOCKER_OK" -eq 1 ] && [ -n "${SCAGENT_IMAGE_PREFIX:-}" ] && [ -n "${SCAGENT_VERSION:-}" ]; then
  have=0
  for svc in seurat agent; do
    img="$(scagent_image "$svc" 2>/dev/null || true)"
    item "镜像 scagent-$svc"
    if [ -n "$img" ] && docker image inspect "$img" >/dev/null 2>&1; then pass "$img"; have=$((have+1)); else warn "本地没有 $img"; fi
  done
  item "回滚标签 :prev"
  if docker image inspect "${SCAGENT_IMAGE_PREFIX}/scagent-seurat:prev" >/dev/null 2>&1; then
    pass "存在（可用 ./deploy/rollback.sh 回滚）"
  else
    warn "尚无 :prev（首次部署正常；每次 up 会自动保留上一版）"
  fi
  if [ "$have" -eq 0 ] && [ "$SCAGENT_PULL_POLICY" = "never" ]; then
    fail "local 模式下没有任何本地镜像 —— 先构建： ./deploy/build.sh 或 deploy\\scagent.cmd build"
  fi
else
  warn "跳过（Docker 不可用或镜像来源未配置）"
fi

# ── 4. 密钥 ───────────────────────────────────────────────────────────────────
group "4. 密钥"

SECRETS_DIR="$(scagent_resolve_path "${SCAGENT_SECRETS_DIR:-./secrets}" 2>/dev/null || printf '%s' "${SCAGENT_SECRETS_DIR:-./secrets}")"
item "密钥目录"
if [ -d "$SECRETS_DIR" ]; then pass "$SECRETS_DIR"; else warn "不存在：$SECRETS_DIR（首次部署时 install 会创建）"; fi

for f in deepseek_api_key scagent_token; do
  item "密钥文件 $f"
  p="$SECRETS_DIR/$f"
  if [ -d "$p" ]; then
    # Docker 在 secret 源文件缺失时会自动建一个【同名目录】占位（file 型 secret 底层是 bind mount），
    # 之后往里写真密钥会撞 Permission denied —— 这里显式指出来，别让它伪装成"缺失"
    fail "是一个目录（不是文件）—— Docker 在源文件缺失时创建的占位目录"; CFG_BAD=1
    hint "修复： rmdir '$p'   然后重新放入密钥（ ./deploy/configure.sh --force  或 Windows 的 deploy\\scagent.cmd secrets ）"
  elif [ ! -f "$p" ]; then
    warn "缺失（install/secrets 会生成）"
  elif [ ! -r "$p" ]; then
    fail "存在但不可读 —— ACL/属主问题"; CFG_BAD=1
    hint "修复： sudo chown $(id -u):$(id -g) '$p' && chmod 600 '$p'"
  else
    pass "可读（$(wc -c < "$p" | tr -d ' ') 字节）"
  fi
done

item "密钥是否在仓库内"
case "$SECRETS_DIR" in
  "$ROOT"/*) warn "在仓库目录内（建议放到仓库之外，避免误打包/误提交）"
             hint "改 deploy/.env 的 SCAGENT_SECRETS_DIR 到仓库外，例如 /srv/scagent/secrets" ;;
  *)         pass "在仓库之外" ;;
esac

# ── 5. 数据 ───────────────────────────────────────────────────────────────────
group "5. 数据目录"

WS="$(scagent_resolve_path "${SCAGENT_WORKSPACE:-}" 2>/dev/null || true)"
if [ -z "$WS" ]; then
  warn "未设置 SCAGENT_WORKSPACE —— 跳过数据检查"
else
  item "工作目录"
  if [ -d "$WS" ]; then pass "$WS"; else warn "不存在：$WS（up/install 会创建）"; fi

  item "10X 原始数据"
  n=$(find "$WS/data/rawdata" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
  if [ "${n:-0}" -gt 0 ]; then
    pass "$n 个样本目录"
  else
    warn "没有样本 —— 质控及后续步骤都无法执行"
    hint "把每个样本放到 $WS/data/rawdata/<样本名>/（含 barcodes/features/matrix 三个文件）"
    hint "⚠️ 是工作目录，不是仓库目录里的 data/ —— 实测最常见的放错位置"
  fi

  BIO="$(scagent_resolve_path "${SCAGENT_BIODATA:-}" 2>/dev/null || true)"
  item "参考数据（celldex）"
  if [ -n "$BIO" ] && [ -d "$BIO" ]; then
    n=$(find "$BIO" -name '*.rds' 2>/dev/null | wc -l)
    if [ "${n:-0}" -gt 0 ]; then pass "$n 个 .rds"
    else warn "目录为空 —— 细胞类型注释（Step 4）会失败"
         hint "一次性获取（需要外网）： ./scripts/fetch_refdata.sh"; fi
  else
    warn "不存在：${BIO:-未设置} —— 细胞类型注释（Step 4）会失败"
    hint "一次性获取（需要外网）： ./scripts/fetch_refdata.sh"
  fi

  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) : ;;
    *)
      item "数据目录属主"
      if [ -d "$WS" ]; then
        me="$(id -u)"
        foreign=$(find "$WS" -maxdepth 3 \! -uid "$me" 2>/dev/null | head -1 | wc -l)
        if [ "${foreign:-0}" -eq 0 ]; then pass "全部属于 uid $me"
        else warn "有非 uid $me 的条目（历史遗留），容器可能写不进去"
             hint "修复： sudo chown -R $me:$(id -g) $WS"; fi
      fi
      ;;
  esac
fi

# ── 6. 服务 ───────────────────────────────────────────────────────────────────
group "6. 服务"

if [ "$DOCKER_OK" -eq 1 ] && [ -f "$ENV_FILE" ]; then
  COMPOSE_FILES=(-f deploy/docker-compose.yml)
  if [ -f "$SECRETS_DIR/deepseek_api_key" ] && [ -f "$SECRETS_DIR/scagent_token" ]; then
    export SCAGENT_SECRETS_DIR
    COMPOSE_FILES+=(-f deploy/docker-compose.secrets.yml)
  elif [ -f "$SECRETS_DIR/scagent_token" ]; then
    # 只有令牌没有 LLM 密钥：up.sh 会挂"仅令牌"的叠加文件，这里必须一致，
    # 否则 doctor 看到的容器与实际情况不符（同样的两文件假设，up.sh 已修）
    export SCAGENT_SECRETS_DIR
    COMPOSE_FILES+=(-f deploy/docker-compose.secrets-token.yml)
  fi
  COMPOSE=(docker compose "${COMPOSE_FILES[@]}")

  running="$("${COMPOSE[@]}" ps -q 2>/dev/null | wc -l)"
  item "运行中的容器"
  if [ "${running:-0}" -ge 2 ]; then pass "${running} 个"; else warn "${running} 个（尚未启动？执行 ./deploy/up.sh）"; fi

  if [ "${running:-0}" -ge 1 ]; then
    unhealthy="$("${COMPOSE[@]}" ps --format json 2>/dev/null | grep -c '"unhealthy"' || true)"
    item "容器健康"
    if [ "${unhealthy:-0}" -eq 0 ]; then pass "全部 healthy"
    else fail "${unhealthy} 个 unhealthy"; SVC_BAD=1
         hint "看日志： ${COMPOSE[*]} logs --tail 100 seurat"; fi

    # 一致性：运行中的容器挂的是哪个宿主目录（Windows 与 WSL 共用一个 daemon 时尤其重要）
    sid="$("${COMPOSE[@]}" ps -q seurat 2>/dev/null | head -1)"
    if [ -n "$sid" ]; then
      mnt="$(docker inspect "$sid" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)"
      item "挂载一致性"
      if [ -z "$mnt" ]; then
        warn "读不到容器的 /data 挂载源"
      elif [ "$mnt" = "$WS/data" ]; then
        pass "容器的 /data 就是 .env 里的工作目录"
      else
        fail "容器挂的是 $mnt，而 .env 写的是 $WS/data —— 不是同一套部署"; CFG_BAD=1
        hint "Windows 与 WSL 共用 Docker 引擎，容易混；用对应的一套脚本重启即可（./deploy/up.sh 或 deploy\\scagent.cmd up）"
      fi
    fi
  fi

  TOKEN=""
  [ -f "$SECRETS_DIR/scagent_token" ] && TOKEN="$(cat "$SECRETS_DIR/scagent_token" 2>/dev/null | tr -d '\r\n')"
  [ -z "$TOKEN" ] && TOKEN="${SCAGENT_TOKEN:-}"
  BASE="http://127.0.0.1:${PORT}"

  item "agent 端点 /v1/health"
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: Bearer ${TOKEN}" "$BASE/v1/health" 2>/dev/null || echo 000)"
  case "$code" in
    200) pass "200（令牌有效）" ;;
    401) fail "401 —— 令牌不对（检查 $SECRETS_DIR/scagent_token 与 .env 是否一致）"; SVC_BAD=1 ;;
    000) [ "${running:-0}" -ge 2 ] && { fail "无响应 —— 容器在跑但端点不通"; SVC_BAD=1; } || warn "服务未启动" ;;
    *)   warn "返回 $code" ;;
  esac

  item "网页界面"
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$BASE/" 2>/dev/null || echo 000)"
  [ "$code" = "200" ] && pass "可访问（$BASE）" || { [ "${running:-0}" -ge 2 ] && warn "返回 $code" || warn "服务未启动"; }
else
  warn "跳过（Docker 不可用或没有 deploy/.env）"
fi

# ── 7. 网络（LLM）─────────────────────────────────────────────────────────────
group "7. 网络与 LLM"

if [ "$QUICK" -eq 1 ]; then
  warn "已跳过（--quick）"
else
  LLM_HOST="${SCAGENT_LLM_BASE_URL:-https://api.deepseek.com}"
  item "LLM 端点可达性"
  lc="$(curl -4 -s -o /dev/null -m 10 -w '%{http_code}' "$LLM_HOST/v1/models" 2>/dev/null || echo 000)"
  case "$lc" in
    200|401|403) pass "可达（$LLM_HOST → $lc）" ;;
    000) warn "不可达（$LLM_HOST）—— 防火墙/代理/DNS 或离线环境"
         hint "离线可用：把 SCAGENT_LLM_PROVIDER 设为 ollama 或 none" ;;
    *) warn "返回 $lc（$LLM_HOST）" ;;
  esac

  item "容器出网（egress）"
  if [ "$DOCKER_OK" -eq 1 ] && [ "${running:-0}" -ge 1 ]; then
    if docker exec scagent-agent-1 python -c "import socket;socket.create_connection(('api.deepseek.com',443),5)" >/dev/null 2>&1; then
      pass "agent 容器可出网"
    else
      warn "agent 容器出网失败（容器名可能不同，或网络受限）—— LLM 调用会失败"
    fi
  else
    warn "跳过（服务未运行）"
  fi
fi

# ── 汇总 ──────────────────────────────────────────────────────────────────────
printf '\n%s\n' "────────────────────────────────────────────────────────────"
printf '  通过 %s%d%s   警告 %s%d%s   失败 %s%d%s\n' \
  "$C_G" "$PASS" "$C_0" "$C_Y" "$WARN" "$C_0" "$C_R" "$FAIL" "$C_0"

if [ "$FAIL" -eq 0 ]; then
  printf '%s\n' "  ${C_G}结论：体检通过${C_0} —— 可以正常使用"
  printf '%s\n' "  接着建议： ./deploy/verify.sh（服务可用性自检）"
  exit 0
fi

if [ "$ENV_BAD" -eq 1 ]; then
  printf '%s\n' "  ${C_R}结论：环境不满足${C_0} —— 先按上面提示处理 Docker/资源问题"
  exit 1
elif [ "$CFG_BAD" -eq 1 ]; then
  printf '%s\n' "  ${C_R}结论：配置错误${C_0} —— 按上面提示修 deploy/.env 或密钥"
  exit 2
else
  printf '%s\n' "  ${C_R}结论：服务/运行期问题${C_0} —— 按上面提示逐项处理"
  printf '%s\n' "  排查提示： docker compose -f deploy/docker-compose.yml logs --tail 100 seurat"
  exit 3
fi
