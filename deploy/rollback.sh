#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  deploy/rollback.sh —— 回滚到上一个镜像版本
#
#  原理：up.sh 在升级前会把当前版本的镜像额外打一个 :prev 标签；
#        本脚本把 :prev 重新指向 SCAGENT_VERSION 并重启。
#
#  用法：
#      ./deploy/rollback.sh              # 回滚到上一个版本
#      ./deploy/rollback.sh --list       # 查看本地已有的镜像版本
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
info() { printf '%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '%s\n' "  ${C_G}✅${C_0} $*"; }
die()  { printf '%s\n' "  ${C_R}❌${C_0} $*" >&2; exit 1; }

[ -f deploy/.env ] || die "缺少 deploy/.env"
set -a; . deploy/.env; set +a
: "${SCAGENT_REGISTRY:?未设置 SCAGENT_REGISTRY}"
: "${SCAGENT_VERSION:?未设置 SCAGENT_VERSION}"

if [ "${1:-}" = "--list" ]; then
  info "本地已有的 scagent 镜像"
  docker images --format '{{.Repository}}:{{.Tag}}\t{{.CreatedSince}}\t{{.Size}}' \
    | grep -E "scagent-(seurat|agent|runtime)" || echo "  (无)"
  exit 0
fi

COMPOSE="docker compose -f deploy/docker-compose.yml"
ROLLED=0

for svc in scagent-runtime scagent-seurat scagent-agent; do
  cur="${SCAGENT_REGISTRY}/${svc}:${SCAGENT_VERSION}"
  prev="${SCAGENT_REGISTRY}/${svc}:prev"
  if docker image inspect "$prev" >/dev/null 2>&1; then
    info "回滚 $svc"
    docker tag "$prev" "$cur"
    docker image inspect "$cur" --format '    现在指向: {{.Id}}' | head -1
    ROLLED=$((ROLLED+1))
  else
    printf '  %s\n' "${C_Y}⚠️ ${C_0} $svc 没有 :prev 标签，跳过"
  fi
done

if [ "$ROLLED" -eq 0 ]; then
  die "没有任何可回滚的镜像。
      回滚依赖于每次升级前保留的 :prev 标签（由 scripts/push_registry.sh 打上）。
      若已丢失，请从 registry 重新拉取目标版本后手工 docker tag。"
fi

info "重启服务"
$COMPOSE up -d --force-recreate
$COMPOSE ps
ok "已回滚 $ROLLED 个镜像并重启。请运行 ./deploy/verify.sh 确认。"
