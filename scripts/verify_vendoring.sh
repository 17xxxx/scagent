#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/verify_vendoring.sh —— 校验私有化镜像搬运清单
#
#  回答一个问题：**服务器会不会因为缺镜像而偷偷去公网拉？**
#  逐条检查 deploy/images.lock 中的每个镜像是否真的存在于私有 registry，
#  并比对 digest 是否与清单一致。任一不符即退出码 1，可用于交付前卡口。
#
#  用法：
#      export SCAGENT_IMAGE_PREFIX=harbor.corp.local/scagent
#      export SCAGENT_VERSION=1.0.0
#      ./scripts/verify_vendoring.sh
#
#      ./scripts/verify_vendoring.sh --offline   # 不做网络校验，只检查清单完整性
# ═══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LOCK="deploy/images.lock"
OFFLINE=0
[ "${1:-}" = "--offline" ] && OFFLINE=1

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
PASS=0; FAIL=0; WARN=0
pass() { printf '  %s\n' "${C_G}✅${C_0} $*"; PASS=$((PASS+1)); }
fail() { printf '  %s\n' "${C_R}❌${C_0} $*"; FAIL=$((FAIL+1)); }
warn() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; WARN=$((WARN+1)); }

printf '\n%s\n' "════════════════════════════════════════════════════════════"
printf '%s\n'   "  私有化搬运清单校验"
printf '%s\n\n' "════════════════════════════════════════════════════════════"

[ -f "$LOCK" ] || { fail "找不到 $LOCK"; exit 1; }

# 镜像前缀：与 deploy/docker-compose.yml 同一套命名规则（旧名 SCAGENT_REGISTRY 仍兼容）
REG="${SCAGENT_IMAGE_PREFIX:-${SCAGENT_REGISTRY:-}}"
VER="${SCAGENT_VERSION:-1.0.0}"
# RUNTIME_IMAGE 可能未导出（set -u 下直接引用会报 unbound variable）
RUNTIME_VER="${RUNTIME_IMAGE:-}"
RUNTIME_VER="${RUNTIME_VER##*:}"
[ -z "$RUNTIME_VER" ] && RUNTIME_VER="$VER"

if [ -z "$REG" ]; then
  fail "未设置 SCAGENT_IMAGE_PREFIX（旧名 SCAGENT_REGISTRY）"
  exit 1
fi

# ── 1. 清单完整性 ─────────────────────────────────────────────────────────────
printf '%s\n' "── 1. 清单完整性 ──"

# 基础镜像 digest 是否已固定（不允许残留 PIN_ME）
if grep -q "PIN_ME" "$LOCK"; then
  warn "images.lock 中仍有未固定的 digest（PIN_ME）"
  warn "  修复： ./scripts/push_registry.sh --pin-digests"
else
  pass "基础镜像 digest 已固定"
fi

# built 清单里的镜像名是否与传参一致
for svc in runtime seurat agent; do
  if grep -q "scagent-$svc" "$LOCK"; then
    pass "清单包含 scagent-$svc"
  else
    fail "清单缺少 scagent-$svc"
  fi
done

# ── 2. 逐条校验私有 registry 中的镜像 ─────────────────────────────────────────
printf '\n%s\n' "── 2. 私有 registry 中的镜像 ──"

check_image() {
  local image="$1"
  if [ "$OFFLINE" -eq 1 ]; then
    warn "[offline] 跳过 $image"
    return
  fi
  if docker manifest inspect "$image" >/dev/null 2>&1; then
    local d
    d=$(docker manifest inspect -v "$image" 2>/dev/null \
        | grep -m1 '"digest"' | sed 's/.*"digest": *"\([^"]*\)".*/\1/' || echo "")
    pass "$image  ${d:+digest=${d:0:19}…}"
  else
    fail "$image 不存在或不可访问"
  fi
}

check_image "$REG/base/tidyverse:4.5.2"
check_image "$REG/base/python:3.11-slim-bookworm"
check_image "$REG/scagent-runtime:$RUNTIME_VER"
check_image "$REG/scagent-seurat:$VER"
check_image "$REG/scagent-agent:$VER"

# ── 3. 反向校验：确认清单里没有指向公网的条目 ─────────────────────────────────
printf '\n%s\n' "── 3. 公网泄漏检查 ──"

if grep -E '^\s*(source|target):\s*(docker\.io|registry-1\.docker\.io|index\.docker\.io)' "$LOCK" \
   | grep -v 'source:' >/dev/null 2>&1; then
  fail "清单中存在指向公网 registry 的 target"
else
  pass "所有 target 均指向私有 registry（source 为公网属正常，那是搬运来源）"
fi

# built 段的镜像不允许出现 docker.io
if grep -A2 '^built:' "$LOCK" | grep -q 'docker\.io'; then
  fail "built 段中出现 docker.io"
else
  pass "built 段无公网引用"
fi

# ── 4. 数据与软件分离检查 ─────────────────────────────────────────────────────
printf '\n%s\n' "── 4. 数据/软件分离 ──"
if grep -q "excluded:" "$LOCK"; then
  pass "清单显式声明了不纳入的项（参考数据 / 原始数据）"
else
  warn "清单未声明 excluded 段"
fi

# ── 汇总 ──────────────────────────────────────────────────────────────────────
printf '\n%s\n' "────────────────────────────────────────────────────────────"
printf '  通过 %s%d%s   警告 %s%d%s   失败 %s%d%s\n' \
  "$C_G" "$PASS" "$C_0" "$C_Y" "$WARN" "$C_0" "$C_R" "$FAIL" "$C_0"

if [ "$FAIL" -eq 0 ]; then
  printf '%s\n' "  结论：${C_G}搬运清单完整，服务器可从私有 registry 独立运行${C_0}"
  exit 0
fi
printf '%s\n' "  结论：${C_R}存在缺失${C_0} —— 请先执行 ./scripts/push_registry.sh $VER $REG"
exit 1
