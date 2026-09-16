#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/push_registry.sh —— 构建并推送私有 registry（SCAGENT_IMAGE_SOURCE=private 形态）
#
#  本脚本**只在构建机上运行**。构建机需要外网（拉基础镜像 + 访问 PPM 装 R 包）；
#  服务器不需要外网，只从私有 registry 拉取（见 deploy/up.sh）。
#
#  镜像命名（与 deploy/docker-compose.yml 完全一致，全仓只此一套规则）：
#      <SCAGENT_IMAGE_PREFIX>/scagent-<runtime|seurat|agent>:<版本>
#  推送后把以下两行写进服务器的 deploy/.env：
#      SCAGENT_IMAGE_SOURCE=private
#      SCAGENT_IMAGE_PREFIX=$REG
#
#  用法：
#      ./scripts/push_registry.sh <version> <registry> [runtime-version]
#      例: ./scripts/push_registry.sh 1.0.0 harbor.corp.local/scagent
#
#      ./scripts/push_registry.sh --make-lock           # 只生成 Python 锁文件 + wheelhouse
#      ./scripts/push_registry.sh --pin-digests         # 把基础镜像 digest 写回 images.lock
#
#  分层构建（PROD_HANDOVER）：
#      base/tidyverse  →  scagent-runtime（≈4 GB，半年一次）
#                      →  scagent-seurat （≈10 MB，每次改代码）
#      base/python     →  scagent-agent  （≈0.4 GB）
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
info() { printf '\n%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '  %s\n' "${C_G}✅${C_0} $*"; }
warn() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; }
die()  { printf '  %s\n' "${C_R}❌${C_0} $*" >&2; exit 1; }

BASE_TIDYVERSE="rocker/tidyverse:4.5.2"
BASE_PYTHON="python:3.11-slim-bookworm"
WHEELS_DIR="vendor/wheels/linux-amd64-cp311"

# ── 子命令：生成 Python 锁文件与 wheelhouse（方案 Step 5，需要外网）───────────
make_lock() {
  info "生成 requirements.lock 与 wheelhouse（需要外网）"
  command -v python3 >/dev/null || die "需要 python3"
  python3 -m venv .lockenv 2>/dev/null || true
  # shellcheck disable=SC1091
  . .lockenv/bin/activate
  pip install --upgrade pip wheel >/dev/null
  pip install -r agent_core/requirements.txt
  info "依赖自检（API 是否真的存在）"
  python -c "from langchain.agents import create_agent; \
from langchain.agents.middleware import HumanInTheLoopMiddleware, SummarizationMiddleware, ToolCallLimitMiddleware; \
import fastapi, uvicorn, langgraph; print('OK')" \
    || die "依赖自检失败：langchain 版本与代码不兼容，请调整 requirements.txt 的版本约束"
  pip freeze > agent_core/requirements.lock
  ok "已写入 agent_core/requirements.lock（$(wc -l < agent_core/requirements.lock) 个包）"
  info "下载 wheel 到 $WHEELS_DIR"
  pip download -r agent_core/requirements.lock -d "$WHEELS_DIR" --only-binary=:all: \
    || warn "部分包没有 wheel，已跳过；离线安装时可能需要联网补齐"
  ok "wheelhouse: $(ls "$WHEELS_DIR" | wc -l) 个文件，$(du -sh "$WHEELS_DIR" | cut -f1)"
  deactivate
  rm -rf .lockenv
  warn "若要启用 --require-hashes，请改用 pip-compile --generate-hashes 重新生成 requirements.lock"
}

# ── 子命令：固定基础镜像 digest 并写回 images.lock ───────────────────────────
pin_digests() {
  info "固定基础镜像 digest"
  for img in "$BASE_TIDYVERSE" "$BASE_PYTHON"; do
    docker pull "$img" >/dev/null
    d=$(docker inspect --format='{{index .RepoDigests 0}}' "$img" | sed 's/.*@//')
    printf '  %-40s %s\n' "$img" "$d"
    python3 - "$img" "$d" <<'PY'
import re, sys, pathlib
img, digest = sys.argv[1], sys.argv[2]
p = pathlib.Path("deploy/images.lock"); s = p.read_text(encoding="utf-8")
pat = re.compile(r'(source:\s*' + re.escape("docker.io/" + img if "/" in img and not img.startswith("docker.io") else img) + r'\s*\n\s*digest:\s*)"[^"]*"')
s2, n = pat.subn(lambda m: m.group(1) + '"' + digest + '"', s)
if n == 0:
    print(f"    (未在 images.lock 中匹配到 {img}，请手工更新)")
else:
    p.write_text(s2, encoding="utf-8"); print(f"    已更新 images.lock: {img}")
PY
  done
}

if [ "${1:-}" = "--make-lock" ];    then make_lock;    exit 0; fi
if [ "${1:-}" = "--pin-digests" ];  then pin_digests;  exit 0; fi

VER="${1:?用法: push_registry.sh <version> <registry>   例如: push_registry.sh 1.0.0 harbor.corp.local/scagent}"
REG="${2:?缺少 registry 参数}"
RUNTIME_VER="${3:-$VER}"

case "$REG" in
  docker.io*|*.docker.io*|library/*) die "拒绝推送到公网 registry: $REG" ;;
esac

command -v docker >/dev/null || die "未安装 docker"
docker info >/dev/null 2>&1 || die "无法连接 Docker 守护进程"

# ── 0. 前置检查 ───────────────────────────────────────────────────────────────
info "[0/5] 前置检查"
if grep -q "PLACEHOLDER" agent_core/requirements.lock 2>/dev/null; then
  warn "agent_core/requirements.lock 仍是占位文件 —— agent 镜像将联网安装依赖。"
  warn "  建议先执行: ./scripts/push_registry.sh --make-lock"
fi
[ -d "$WHEELS_DIR" ] || warn "wheelhouse 目录不存在: $WHEELS_DIR"
ok "目标 registry: $REG  版本: $VER  runtime 版本: $RUNTIME_VER"

# ── 1. 搬运基础镜像（原封不动，只改标签）─────────────────────────────────────
info "[1/5] 搬运基础镜像到私有 registry"
docker pull "$BASE_TIDYVERSE"
docker tag  "$BASE_TIDYVERSE" "$REG/base/tidyverse:4.5.2"
docker push "$REG/base/tidyverse:4.5.2"
docker pull "$BASE_PYTHON"
docker tag  "$BASE_PYTHON" "$REG/base/python:3.11-slim-bookworm"
docker push "$REG/base/python:3.11-slim-bookworm"
ok "基础镜像已搬运"

# ── 2. 构建 R 运行时（重型，很少变）──────────────────────────────────────────
info "[2/5] 构建 R 运行时 $REG/scagent-runtime:$RUNTIME_VER"
info "     这一步会安装 108 个 R 包，首次约 30–90 分钟"
BUILD_ARGS=()
for v in PPM_CRAN CRAN_FALLBACK BIOC_ROOT R_BIOC_VERSION PIP_INDEX_URL PIP_OPTS APT_MIRROR; do
  [ -n "${!v:-}" ] && BUILD_ARGS+=(--build-arg "$v=${!v}")
done
docker build "${BUILD_ARGS[@]}" \
  -f seurat_backend/Dockerfile.runtime \
  -t "$REG/scagent-runtime:$RUNTIME_VER" .
docker push "$REG/scagent-runtime:$RUNTIME_VER"
ok "runtime 已推送"

# ── 3. 构建应用层（轻量，每次改代码）────────────────────────────────────────
info "[3/5] 构建应用层（只 COPY 代码，约 10 MB 增量）"
docker build \
  --build-arg RUNTIME="$REG/scagent-runtime:$RUNTIME_VER" \
  -f seurat_backend/Dockerfile \
  -t "$REG/scagent-seurat:$VER" .
docker build -f agent_core/Dockerfile -t "$REG/scagent-agent:$VER" .
ok "应用层构建完成"

# ── 4. 保留上一版（供 deploy/rollback.sh 回滚）并推送 ────────────────────────
info "[4/5] 保留上一版标签并推送"
for svc in scagent-runtime scagent-seurat scagent-agent; do
  case "$svc" in
    scagent-runtime) tag="$RUNTIME_VER" ;;
    *)               tag="$VER" ;;
  esac
  cur="$REG/${svc}:$tag"
  if docker image inspect "$cur" >/dev/null 2>&1; then
    docker tag "$cur" "$REG/${svc}:prev" || warn "打 :prev 标签失败：$cur"
  else
    warn "本地没有 $cur，跳过 :prev（回滚将不可用）"
  fi
  docker push "$cur"
  ok "已推送 $cur"
done

# ── 5. 校验搬运清单 ──────────────────────────────────────────────────────────
info "[5/5] 校验搬运清单"
if [ -x scripts/verify_vendoring.sh ] || [ -f scripts/verify_vendoring.sh ]; then
  SCAGENT_IMAGE_PREFIX="$REG" SCAGENT_VERSION="$VER" \
    RUNTIME_IMAGE="$REG/scagent-runtime:$RUNTIME_VER" \
    bash scripts/verify_vendoring.sh || warn "校验未全部通过，请检查上方输出"
fi

printf '\n%s\n' "────────────────────────────────────────────────────────────"
ok "构建并推送完成"
printf '    服务器侧部署：\n'
printf '      echo "SCAGENT_IMAGE_SOURCE=private" >> deploy/.env\n'
printf '      echo "SCAGENT_IMAGE_PREFIX=%s" >> deploy/.env\n' "$REG"
printf '      echo "SCAGENT_VERSION=%s" >> deploy/.env\n' "$VER"
printf '      ./deploy/up.sh\n'
