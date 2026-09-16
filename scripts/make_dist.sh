#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/make_dist.sh —— 装配交付物（不含镜像）
#
#  产出的是一个「源码 + 可选包级」交付包：包含源码、配置模板、脚本与（若已填充）
#  vendor/ 下的 Python wheel 与 R 包仓。**镜像本身不进交付包** ——
#  镜像由 deploy/build.sh 本地构建，或走 registry 分发（scripts/push_registry.sh）。
#
#  ⚠️ 关于"离线重建"：仓库默认**不含** vendor/wheels（空目录），shared_data/ 也只覆盖
#     部分 R 包，因此默认情况下构建镜像**需要外网**（基础镜像 + R 包）。若要离线重建，
#     请自行补齐 vendor/wheels/ 与 shared_data/ 后再执行本脚本。
#
#  用法：
#      ./scripts/make_dist.sh 1.0.0
#      ./scripts/make_dist.sh 1.0.0 --out /tmp/dist
#      ./scripts/make_dist.sh 1.0.0 --with-docs     # 额外包含 docs/（默认**不含**）
#      ./scripts/make_dist.sh 1.0.0 --with-r-repo   # 额外包含 shared_data/ 的 R 源码包（默认**不含**，约 284 MB）
#
#  ⚠️ 默认不打包 docs/：其中含内部审计、安全分析与密钥前缀讨论，
#     不适合随交付物分发（见 docs/ISSUES_AND_PLAN.md §1 与 G 类）。
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VER="${1:?用法: make_dist.sh <version> [--out DIR]}"
shift

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
info() { printf '\n%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '  %s\n' "${C_G}✅${C_0} $*"; }
warn() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; }
die()  { printf '  %s\n' "${C_R}❌${C_0} $*" >&2; exit 1; }

OUT_ROOT="./dist"
WITH_DOCS=0
WITH_R_REPO=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out)       shift; OUT_ROOT="${1:?--out 需要目录}" ;;
    --with-docs) WITH_DOCS=1 ;;
    --with-r-repo) WITH_R_REPO=1 ;;
    *) die "未知参数: $1（可用：--out DIR、--with-docs、--with-r-repo）" ;;
  esac
  shift
done

OUT="$OUT_ROOT/scagent-deploy-$VER"

# 失败时**先清场再退出** —— 否则半个交付物（可能含密钥）会留在 dist/ 里，
# 随手 zip 一下就带出去了（见 docs/ISSUES_AND_PLAN.md G1）。
die_dist() {
  printf '  %s\n' "${C_R}❌${C_0} $*" >&2
  if [ -n "${OUT:-}" ] && [ -d "${OUT:-}" ]; then
    rm -rf "$OUT"
    printf '  %s\n' "${C_R}❌${C_0} 已删除未完成/不合格的交付物目录：$OUT" >&2
  fi
  exit 1
}

# 先删：把密钥类路径从交付物里彻底摘掉（白名单式的"必删清单"）
sanitize_dist() {
  local out="$1"
  rm -rf "$out/deploy/secrets" "$out/secrets"
  rm -f  "$out/deploy/.env"
  find "$out" -type f \
      \( -name '.env' -o \( -name '.env.*' ! -name '*.sample' \) \) -delete 2>/dev/null || true
}

# 后检：名称 + 内容双重拦截。名称规则与"合法文件名"对齐，避免误报
#   （docker-compose.secrets.yml / check_secrets.sh / setup_secrets.sh 均不会被误伤）
leak_scan() {
  local out="$1" hits=""
  hits="$(find "$out" \( -path '*/secrets/*' \
           -o -name '.env' -o \( -name '.env.*' ! -name '*.sample' \) \
           -o -name '*_api_key' -o -name '*_token' -o -name 'id_rsa*' \
           -o -name 'credentials*' -o -name '*.key' -o -name '*.pem' \
           -o -name '*.p12' -o -name '*.pfx' \) -print 2>/dev/null || true)"
  [ -n "$hits" ] && { printf '%s\n' "$hits" | sed 's/^/    /'; return 1; }
  # 不加 -I：密钥也可能藏在二进制/归档里（.rds、.tar.gz、.pyc）
  if grep -rlE 'sk-[A-Za-z0-9_-]{20,}' "$out" 2>/dev/null | head -5 | grep -q .; then
    grep -rlE 'sk-[A-Za-z0-9_-]{20,}' "$out" 2>/dev/null | head -5 | sed 's/^/    /'
    return 1
  fi
  return 0
}

info "[1/6] 准备目录 $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"/{vendor,deploy,client,scripts,docs}

info "[2/6] 收集可选包级资产（vendor/）"
if [ -d vendor/wheels ] && [ -n "$(ls -A vendor/wheels 2>/dev/null)" ]; then
  cp -r vendor/wheels "$OUT/vendor/"
  ok "已打包 vendor/wheels（$(find vendor/wheels -type f | wc -l) 个文件）"
else
  warn "vendor/wheels 为空 —— 未打包；构建镜像时将由 pip 从 PyPI 安装（需外网）"
fi
if [ "$WITH_R_REPO" -eq 1 ] && [ -d shared_data ]; then
  cp -r shared_data "$OUT/vendor/r-repo"
  rm -f "$OUT/vendor/r-repo/presto-master.zip" 2>/dev/null || true
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
    warn "R 源码包数量偏少（$n）。完整依赖闭包约 108 个包，当前 shared_data 只覆盖一部分，"
    warn "  因此**构建镜像仍需外网**（R 包从 PPM/CRAN 安装）。"
    warn "  如需离线重建，请先补齐 shared_data/ 中的 R 包并自建 wheelhouse。"
  fi
elif [ "$WITH_R_REPO" -eq 1 ]; then
  warn "shared_data 不存在，跳过 R 包仓"
else
  warn "已跳过 R 源码包仓（shared_data/，约 284 MB）—— 构建镜像时 R 包从 PPM/CRAN 安装"
  warn "  如需随交付包提供离线 R 包仓，加 --with-r-repo（注意：依赖闭包并不完整）"
fi

info "[3/6] 收集代码、配置与脚本"
cp -r agent_core  "$OUT/" && rm -rf "$OUT/agent_core/__pycache__" "$OUT/agent_core/tools/__pycache__"
cp -r seurat_backend "$OUT/" && rm -f "$OUT/seurat_backend/.Rhistory"
# deploy/ 用 tar 管道复制并**在复制阶段**就排除密钥 —— 不给"复制完再删"留窗口
( cd "$ROOT" && tar -cf - \
    --exclude='deploy/secrets' \
    --exclude='deploy/.env' \
    --exclude='deploy/.env.*' \
    --exclude='deploy/**/*.key' \
    --exclude='deploy/**/*.pem' \
    deploy ) | ( cd "$OUT" && tar -xf - )
[ -d "$OUT/deploy" ] || die_dist "复制 deploy/ 失败"
cp -r client   "$OUT/"
cp -r scripts  "$OUT/"
if [ "$WITH_DOCS" -eq 1 ]; then
  cp -r docs "$OUT/" 2>/dev/null || warn "docs 不存在"
  warn "已按 --with-docs 包含 docs/ —— 其中含内部审计与安全分析，请确认接收方范围"
else
  warn "已跳过内部文档 docs/（默认行为；如确需包含请加 --with-docs）"
fi
cp README.md TOOLS_HELP.txt "$OUT/" 2>/dev/null || true

# 配置模板必须保留，真实 .env 与密钥目录必须排除（复制后立刻清掉，不依赖后续检查）
sanitize_dist "$OUT"
if [ ! -f "$OUT/deploy/.env.sample" ]; then
  [ -f deploy/.env.sample ] || die "缺少 deploy/.env.sample"
  cp deploy/.env.sample "$OUT/deploy/.env.sample"
fi
ok "已收集（deploy/.env 与密钥目录已排除）"

info "[4/6] 写入版本信息"
{
  echo "version:   $VER"
  echo "built_at:  $(date -Iseconds)"
  echo "commit:    $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "branch:    $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
} > "$OUT/VERSION"
cat "$OUT/VERSION" | sed 's/^/  /'

info "[5/6] 密钥泄漏拦截（名称 + 内容双重检查）"
if ! leak_scan "$OUT"; then
  die_dist "交付物中检出密钥类文件或活密钥，已中止并清场。请检查上面列出的文件。"
fi
ok "未发现密钥 / .env / 私钥文件"

info "[6/6] 生成校验清单"
( cd "$OUT" && find . -type f ! -name MANIFEST.sha256 -print0 \
    | sort -z | xargs -0 sha256sum > MANIFEST.sha256 )
ok "MANIFEST.sha256 ($(wc -l < "$OUT/MANIFEST.sha256") 个文件)"

SIZE=$(du -sh "$OUT" | cut -f1)
printf '\n%s\n' "────────────────────────────────────────────────────────────"
ok "交付物已生成: $OUT  ($SIZE)"
printf '\n  内容：\n'
printf '    vendor/    可选包级资产（Python wheels + R 包仓；默认可能为空）\n'
printf '    agent_core/ seurat_backend/ client/ scripts/ deploy/\n'
printf '    MANIFEST.sha256  VERSION\n'
printf '\n  注意：本交付物**不含镜像**。镜像分发请使用：\n'
printf '    ./scripts/push_registry.sh %s <你的私有registry>\n' "$VER"
