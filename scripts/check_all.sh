#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/check_all.sh —— 一键静态自检
#
#  在提交改动前、或部署到服务器前跑一遍。覆盖方案里最容易出错、且静态可查的项。
#  全部检查都在本机完成，不需要 Docker / R / 网络。
#
#  用法：
#      ./scripts/check_all.sh
#      ./scripts/check_all.sh --quick    # 跳过与 git 基线对比的部分
# ═══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
PASS=0; FAIL=0
step() { printf '\n%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '  %s\n' "${C_G}✅${C_0} $*"; PASS=$((PASS+1)); }
bad()  { printf '  %s\n' "${C_R}❌${C_0} $*"; FAIL=$((FAIL+1)); }
note() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; }

printf '%s\n' "════════════════════════════════════════════════════════════"
printf '%s\n' "  scAgent 静态自检"
printf '%s\n' "════════════════════════════════════════════════════════════"

# ── 1. Python 语法 ────────────────────────────────────────────────────────────
step "[1/8] Python 语法"
pyfail=0
for f in agent_core/*.py agent_core/tools/*.py client/*.py scripts/*.py; do
  python3 -m py_compile "$f" 2>/dev/null || { bad "$f"; pyfail=1; }
done
[ $pyfail -eq 0 ] && ok "全部通过（$(ls agent_core/*.py agent_core/tools/*.py client/*.py scripts/*.py | wc -l) 个文件）"

# ── 2. Shell 语法 ─────────────────────────────────────────────────────────────
step "[2/8] Shell 语法"
shfail=0
for f in scripts/*.sh deploy/*.sh; do
  bash -n "$f" 2>/dev/null || { bad "$f"; shfail=1; }
done
[ $shfail -eq 0 ] && ok "全部通过（$(ls scripts/*.sh deploy/*.sh | wc -l) 个文件）"

# ── 3. Python↔R 参数契约 ──────────────────────────────────────────────────────
step "[3/8] Python → R 参数契约"
out=$(python3 scripts/check_param_contract.py 2>&1)
if printf '%s' "$out" | grep -q "契约校验未通过"; then
  bad "参数契约偏离快照（若确为有意改动，执行 --accept 后提交）："
  printf '%s\n' "$out" | grep -E "❌|⚠️" | sed 's/^/      /'
else
  ok "参数键与默认值均与快照一致，且全部被 R 白名单接受"
fi
if [ "$QUICK" -eq 0 ]; then
  printf '%s\n' "      （如需查看相对 git 基线的差异：python3 scripts/check_param_contract.py --baseline）"
fi

# ── 4. 工具 schema（空参 / None 容忍）─────────────────────────────────────────
step "[4/8] 工具 args_schema 容忍度"
if python3 -c "import langchain" 2>/dev/null; then
  python3 scripts/check_tool_schemas.py >/dev/null 2>&1 \
    && ok "空参数与 None 均可通过校验" || bad "存在必填字段，运行期会崩"
else
  note "本机未装 langchain，跳过（容器内构建时会自动执行该断言）"
fi

# ── 5. TOOLS_HELP 与代码一致 ──────────────────────────────────────────────────
step "[5/8] TOOLS_HELP.txt 一致性"
python3 scripts/gen_tools_help.py --check >/dev/null 2>&1 \
  && ok "与代码一致" || bad "已过期，请运行 python3 scripts/gen_tools_help.py"

# ── 6. R 脚本运行期禁止装包 ───────────────────────────────────────────────────
step "[6/8] R 步骤脚本无运行期装包"
if grep -rnE "install\.packages|BiocManager::install|pak::pkg_install|remotes::install" \
     seurat_backend/*.R >/dev/null 2>&1; then
  bad "发现运行期装包调用（会破坏离线保证）"
  grep -rnE "install\.packages|BiocManager::install|pak::pkg_install|remotes::install" \
    seurat_backend/*.R | sed 's/^/      /'
else
  ok "无（与应用层 Dockerfile 的构建期断言一致）"
fi

# ── 7. 硬编码路径与已知错误地址 ───────────────────────────────────────────────
step "[7/8] 硬编码路径 / 已知错误地址"
hard=$(grep -rn '"/workspace\|"/data/' --include=*.R --include=*.py . 2>/dev/null \
       | grep -vE 'Sys\.getenv|os\.getenv|_get\(|# |_config\.R:' | grep -v '^\./\.git')
if [ -n "$hard" ]; then
  bad "发现硬编码路径："; printf '%s\n' "$hard" | sed 's/^/      /'
else
  ok "无（全部走 SCAGENT_* 环境变量）"
fi

# 注意排除本脚本自身：它的 grep 行里就含有该字面量（曾因此自我误报）
if grep -rn "packagemanager.posit.co/bioconductor" --include=*.R --include=*.sh \
     --include=*.py --include=Dockerfile* --exclude=check_all.sh . 2>/dev/null \
   | grep -vE '^[^:]+:[0-9]+: *#' | grep -q .; then
  bad "仍在使用已证实 404 的 PPM Bioconductor 地址"
else
  ok "无已知 404 的仓库地址"
fi

# ── 8. 密钥不外泄 ─────────────────────────────────────────────────────────────
step "[8/8] 密钥泄漏"
if git ls-files -z 2>/dev/null | xargs -0 grep -lE 'sk-[A-Za-z0-9_-]{20,}' 2>/dev/null | head -3 | grep -q .; then
  bad "追踪文件中检出疑似 API Key"
else
  ok "追踪文件中无密钥"
fi
git ls-files --error-unmatch .env >/dev/null 2>&1 \
  && bad ".env 被 git 追踪了！" || ok ".env 未被追踪"

# ── 汇总 ──────────────────────────────────────────────────────────────────────
printf '\n%s\n' "────────────────────────────────────────────────────────────"
printf '  通过 %s%d%s   失败 %s%d%s\n' "$C_G" "$PASS" "$C_0" "$C_R" "$FAIL" "$C_0"
if [ "$FAIL" -eq 0 ]; then
  printf '%s\n' "  ${C_G}全部通过${C_0}"
  exit 0
fi
printf '%s\n' "  ${C_R}存在失败项，请按上面提示处理${C_0}"
exit 1
