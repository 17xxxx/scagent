#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/make_dist.sh —— 装配交付物（不含镜像）
#
#  产出的是一个「源码级 + 包级」交付包：vendor/ 里带着全部 Python wheel 与 R 包仓，
#  便于他人审查、重建或离线安装。**镜像本身不进交付包** ——
#  镜像走私有 registry，见 scripts/push_registry.sh。
#
#  用法：
#      ./scripts/make_dist.sh 1.0.0
#      ./scripts/make_dist.sh 1.0.0 --out /tmp/dist
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VER="${1:?用法: make_dist.sh <version> [--out DIR]}"
OUT_ROOT="./dist"
[ "${2:-}" = "--out" ] && OUT_ROOT="${3:?--out 需要目录}"

OUT="$OUT_ROOT/scagent-deploy-$VER"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
info() { printf '\n%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '  %s\n' "${C_G}✅${C_0} $*"; }
warn() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; }
die()  { printf '  %s\n' "${C_R}❌${C_0} $*" >&2; exit 1; }

info "[1/6] 准备目录 $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"/{vendor,deploy,client,scripts,docs}

info "[2/6] 收集源码级离线资产"
cp -r vendor/wheels "$OUT/vendor/" 2>/dev/null || warn "vendor/wheels 不存在"
if [ -d shared_data ]; then
  cp -r shared_data "$OUT/vendor/r-repo"
  find "$OUT/vendor/r-repo" -name "*:Zone.Identifier" -delete 2>/dev/null || true
  # 生成 PACKAGES 索引 —— 没有索引时 install.packages(repos=...) 无法识别这些包
  if command -v Rscript >/dev/null 2>&1; then
    Rscript -e "tools::write_PACKAGES('$OUT/vendor/r-repo', type='source')" \
      && ok "已生成 R 包索引 PACKAGES"
  else
    warn "本机无 Rscript，未生成 PACKAGES 索引"
    warn "  请在装 R 的机器上执行： Rscript -e \"tools::write_PACKAGES('vendor/r-repo', type='source')\""
  fi
  n=$(ls "$OUT/vendor/r-repo"/*.tar.gz 2>/dev/null | wc -l)
  ok "R 包仓: $n 个源码包"
  if [ "$n" -lt 100 ]; then
    warn "源码包数量偏少（$n）。注意：完整依赖闭包为 108 个包，"
    warn "  当前 shared_data 只覆盖一部分，不足以支撑源码级离线重建。"
    warn "  如需源码级离线重建，请先补齐 shared_data/ 中的 R 包。"
  fi
else
  warn "shared_data 不存在，跳过 R 包仓"
fi

info "[3/6] 收集代码、配置与脚本"
cp -r agent_core  "$OUT/" && rm -rf "$OUT/agent_core/__pycache__" "$OUT/agent_core/tools/__pycache__"
cp -r seurat_backend "$OUT/" && rm -f "$OUT/seurat_backend/.Rhistory"
cp -r deploy   "$OUT/"
cp -r client   "$OUT/"
cp -r scripts  "$OUT/"
cp -r docs     "$OUT/" 2>/dev/null || warn "docs 不存在"
cp README.md TOOLS_HELP.txt "$OUT/" 2>/dev/null || true

# 配置模板必须保留，真实 .env 必须排除
[ -f "$OUT/deploy/.env" ] && rm -f "$OUT/deploy/.env"
[ -f deploy/.env.sample ] || die "缺少 deploy/.env.sample"
ok "已收集（deploy/.env 已排除）"

info "[4/6] 写入版本信息"
{
  echo "version:   $VER"
  echo "built_at:  $(date -Iseconds)"
  echo "commit:    $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "branch:    $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
} > "$OUT/VERSION"
cat "$OUT/VERSION" | sed 's/^/  /'

info "[5/6] 密钥泄漏拦截"
LEAK=0
if grep -rIlE 'sk-[A-Za-z0-9_-]{20,}' "$OUT" 2>/dev/null | grep -v '\.pyc$' | head -5; then
  die "交付物中检出疑似 API Key，已中止。请检查上面列出的文件。"
fi
for f in $(find "$OUT" -name '.env' -o -name '*.key' -o -name '*.pem' 2>/dev/null); do
  warn "发现敏感文件: $f"; LEAK=1
done
[ "$LEAK" -eq 0 ] && ok "未发现密钥或 .env 泄漏"

info "[6/6] 生成校验清单"
( cd "$OUT" && find . -type f ! -name MANIFEST.sha256 -print0 \
    | sort -z | xargs -0 sha256sum > MANIFEST.sha256 )
ok "MANIFEST.sha256 ($(wc -l < "$OUT/MANIFEST.sha256") 个文件)"

SIZE=$(du -sh "$OUT" | cut -f1)
printf '\n%s\n' "────────────────────────────────────────────────────────────"
ok "交付物已生成: $OUT  ($SIZE)"
printf '\n  内容：\n'
printf '    vendor/    源码级「包」（Python wheels + R 包仓）\n'
printf '    agent_core/ seurat_backend/ client/ scripts/ deploy/\n'
printf '    MANIFEST.sha256  VERSION\n'
printf '\n  注意：本交付物**不含镜像**。镜像分发请使用：\n'
printf '    ./scripts/push_registry.sh %s <你的私有registry>\n' "$VER"
