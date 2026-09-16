#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/check_ps_syntax.sh —— PowerShell 脚本的**静态**体检（无需 Windows）
#
#  为什么需要它：本项目在 Linux/WSL 侧开发，但 PS 脚本只能在 Windows 上真跑。
#  而 PowerShell 有一类错误是**解析期**的 —— 一旦文件里有，整文件都加载不了，
#  表现为调用处刷屏 CommandNotFound，真正的原因被埋掉。
#  实测踩过：字符串里的 "$me:(OI)(CI)F" 被当成"盘符变量"（$me:）→ 解析失败。
#
#  本脚本检查（静态、不执行）：
#    1. UTF-8 with BOM（PS 5.1 读无 BOM 的中文脚本会乱码/报错）
#    2. 花括号 / 圆括号 平衡
#    3. 字符串内形如 "$变量:" 的盘符式引用（合法前缀除外：$env:/$script:/$global: 等）
#    4. 常见 PS7 专有语法（?? / ?. / -SkipCertificateCheck）
#    5. 单引号与双引号数量是否为偶数（粗查）
#
#  用法：
#      ./scripts/check_ps_syntax.sh                 # 检查 deploy 下全部 .ps1
#      ./scripts/check_ps_syntax.sh path/to/x.ps1   # 检查指定文件
# ═══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
PASS=0; FAIL=0; WARN=0
ok()   { printf '  %s\n' "${C_G}✅${C_0} $*"; PASS=$((PASS+1)); }
bad()  { printf '  %s\n' "${C_R}❌${C_0} $*"; FAIL=$((FAIL+1)); }
warn() { printf '  %s\n' "${C_Y}⚠️ ${C_0} $*"; WARN=$((WARN+1)); }

if [ "$#" -gt 0 ]; then
  FILES=("$@")
else
  mapfile -t FILES < <(find deploy scripts -name '*.ps1' 2>/dev/null | sort)
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "没有找到 .ps1 文件"
  exit 0
fi

printf '\n%s\n' "════════════════════════════════════════════════════════════"
printf '%s\n'   "  PowerShell 静态体检（${#FILES[@]} 个文件）"
printf '%s\n\n' "════════════════════════════════════════════════════════════"

for f in "${FILES[@]}"; do
  printf '%s\n' "${C_B}── $f ──${C_0}"

  if [ ! -f "$f" ]; then bad "文件不存在"; continue; fi

  # 1. BOM
  if [ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
    ok "UTF-8 BOM 存在"
  else
    bad "缺少 UTF-8 BOM（PS 5.1 会把中文按 ANSI 解码 → 乱码或语法错误）"
  fi

  # 2. 括号平衡
  #    先去掉"整行注释"与"引号包裹的内容"再数 —— 否则注释里的 `# 1)` 这类编号
  #    会让右括号多出来（实测误报过一次），字符串里的括号同理。
  cleaned="$(sed -e '/^[[:space:]]*#/d' -e "s/'[^']*'//g" -e 's/"[^"]*"//g' "$f")"
  ob=$(printf '%s' "$cleaned" | tr -cd '{' | wc -c); cb=$(printf '%s' "$cleaned" | tr -cd '}' | wc -c)
  op=$(printf '%s' "$cleaned" | tr -cd '(' | wc -c); cp=$(printf '%s' "$cleaned" | tr -cd ')' | wc -c)
  if [ "$ob" -eq "$cb" ] && [ "$op" -eq "$cp" ]; then
    ok "括号平衡（{} $ob/$cb，() $op/$cp）"
  else
    bad "括号不平衡（{} $ob/$cb，() $op/$cp）"
  fi

  # 3. 盘符式变量引用：$var:  （合法的 $env:/$script:/$global:/$local:/$private:/$using: 除外）
  hits=$(grep -nE '\$[A-Za-z_][A-Za-z0-9_]*:' "$f" \
           | grep -vE '\$(env|script|global|local|private|using):' \
           | grep -vE '^\s*[0-9]+:\s*#' || true)
  if [ -z "$hits" ]; then
    ok "无盘符式变量引用（\$var: 这种会导致整文件解析失败）"
  else
    bad "发现疑似盘符式变量引用（应写成 \${var}: 或 \$(...)：）"
    printf '%s\n' "$hits" | sed 's/^/      /'
  fi

  # 4. PS7 专有语法
  hits7=$(grep -nE '\?\?|\?\.|-SkipCertificateCheck|-Parallel\b' "$f" | grep -vE '^\s*[0-9]+:\s*#' || true)
  if [ -z "$hits7" ]; then ok "无 PS7 专有语法"; else
    warn "疑似 PS7 专有语法（PS 5.1 不支持）："; printf '%s\n' "$hits7" | sed 's/^/      /'
  fi

  # 5. 双引号奇偶粗查：**先剥掉单引号包起来的内容**再数，
  #    否则 `'"key"\s*:'` 这类"单引号里含双引号"的正则会误报（实测踩过）。
  #    这里只作粗查（不做真正的语法分析），奇数时提示人工确认。
  dq=0
  while IFS= read -r line; do
    stripped=$(printf '%s' "$line" | sed "s/'[^']*'//g")
    n=$(printf '%s' "$stripped" | tr -cd '"' | wc -c)
    dq=$((dq + n))
  done < "$f"
  sq=$(tr -cd "'" < "$f" | wc -c)
  if [ $((dq % 2)) -eq 0 ]; then
    ok "双引号配对正常（双 $dq，单 $sq）"
  else
    warn "双引号数量为奇数（双 $dq，单 $sq）—— 可能是跨行字符串/Here-String，也可能是笔误，请人工确认"
  fi
done

printf '\n%s\n' "────────────────────────────────────────────────────────────"
printf '  通过 %s%d%s   警告 %s%d%s   失败 %s%d%s\n' "$C_G" "$PASS" "$C_0" "$C_Y" "$WARN" "$C_0" "$C_R" "$FAIL" "$C_0"
if [ "$FAIL" -eq 0 ]; then
  printf '%s\n' "  结论：静态检查通过（注意：这**不能**替代在 Windows 上真跑一次）"
  exit 0
else
  printf '%s\n' "  结论：存在会阻断脚本加载的问题，请先修"
  exit 1
fi
