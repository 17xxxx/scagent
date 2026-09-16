#!/usr/bin/env python3
"""
gen_tools_help.py —— 自动生成 TOOLS_HELP.txt
==============================================
目的：避免「文档与代码漂移」——TOOLS_HELP.txt 由源码直接生成，
工具清单、参数与索引文件名都取自代码事实，不再依赖人工同步。

实现方式：**静态 AST 解析**，不 import 任何工具模块 ——
因此不需要安装 langchain / pydantic 也能运行（可在任意机器、CI 里执行）。

用法：
    python3 scripts/gen_tools_help.py            # 重新生成 TOOLS_HELP.txt
    python3 scripts/gen_tools_help.py --check    # 仅校验是否最新（CI 用，不一致则退出码 1）
    python3 scripts/gen_tools_help.py --stdout   # 打印到标准输出
"""

from __future__ import annotations

import argparse
import ast
import datetime
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
TOOLS_DIR = REPO / "agent_core" / "tools"
OUT_FILE = REPO / "TOOLS_HELP.txt"

WIDTH = 80


# ── 工具函数 ──────────────────────────────────────────────────────────────────

def _simplify_annotation(node: ast.expr | None) -> str:
    """把 Optional[List[str]] 之类简写成 list[str] / str / int / bool / float。"""
    if node is None:
        return "any"
    text = ast.unparse(node)
    text = re.sub(r"^Optional\[(.*)\]$", r"\1", text)
    text = re.sub(r"^List\[(.*)\]$", r"list[\1]", text)
    text = re.sub(r"^Dict\[(.*)\]$", r"dict[\1]", text)
    return text.replace("typing.", "").lower()


def _literal(node: ast.expr | None) -> str:
    """尽力把默认值渲染成人类可读字符串。"""
    if node is None:
        return "—"
    if isinstance(node, ast.Constant) and node.value is None:
        return "None"
    try:
        val = ast.literal_eval(node)
    except Exception:
        return ast.unparse(node)
    if isinstance(val, str):
        return val            # 字符串不加引号，表格更清爽
    return repr(val)


def _dwidth(text: str) -> int:
    """显示宽度（中文按 2 列计）。"""
    return sum(2 if ord(c) > 0x2E80 else 1 for c in text)


def _pad(text: str, width: int) -> str:
    """按显示宽度左对齐补空格。"""
    return text + " " * max(0, width - _dwidth(text))


def _first_paragraph(docstring: str | None) -> str:
    if not docstring:
        return "(无说明)"
    lines = []
    for raw in docstring.strip().splitlines():
        line = raw.strip()
        if line.startswith("Args:") or line.startswith("参数"):
            break
        if not line and lines:
            break
        if line:
            lines.append(line)
    return " ".join(lines) if lines else "(无说明)"


def _args_from_docstring(docstring: str | None) -> dict[str, str]:
    """从 Google 风格 docstring 的 Args 段抽取参数说明（作为 Field 描述的补充）。"""
    out: dict[str, str] = {}
    if not docstring or "Args:" not in docstring:
        return out
    tail = docstring.split("Args:", 1)[1]
    current = None
    for raw in tail.splitlines():
        line = raw.rstrip()
        m = re.match(r"^\s{4,}(\w+)\s*:\s*(.*)$", line)
        if m:
            current = m.group(1)
            out[current] = m.group(2).strip()
        elif current and line.strip():
            out[current] += " " + line.strip()
    return out


# ── 解析 ──────────────────────────────────────────────────────────────────────

class ToolInfo:
    def __init__(self, name, module, purpose, params, order):
        self.name = name
        self.module = module
        self.purpose = purpose
        self.params = params          # list[(name, type, default, description)]
        self.order = order


def _fields_of_class(cls: ast.ClassDef) -> list[tuple]:
    params = []
    for node in cls.body:
        if not isinstance(node, ast.AnnAssign) or not isinstance(node.target, ast.Name):
            continue
        fname = node.target.id
        if fname.startswith("_") or fname == "model_config":
            continue
        ftype = _simplify_annotation(node.annotation)

        default_node = node.value
        description = ""
        if isinstance(default_node, ast.Call):
            for kw in default_node.keywords:
                if kw.arg == "default":
                    default_node = kw.value
                elif kw.arg == "description" and isinstance(kw.value, ast.Constant):
                    description = str(kw.value.value)
        params.append((fname, ftype, _literal(default_node), description))
    return params


def _import_order() -> dict[str, int]:
    """按 tools/__init__.py 的导入顺序给工具排序（那是权威顺序）。"""
    init = TOOLS_DIR / "__init__.py"
    order: dict[str, int] = {}
    if not init.exists():
        return order
    src = init.read_text(encoding="utf-8")
    idx = 0
    for m in re.finditer(r"^from\s+\.(\w+)\s+import\s+(\w+)", src, re.M):
        order[m.group(2)] = idx
        idx += 1
    return order


def collect() -> list[ToolInfo]:
    order_map = _import_order()
    tools: list[ToolInfo] = []

    for path in sorted(TOOLS_DIR.glob("*_tool.py")):
        try:
            tree = ast.parse(path.read_text(encoding="utf-8"))
        except SyntaxError as exc:
            print(f"  !! 语法错误 {path.name}: {exc}", file=sys.stderr)
            continue

        classes = {n.name: n for n in tree.body if isinstance(n, ast.ClassDef)}

        for node in tree.body:
            if not isinstance(node, ast.FunctionDef):
                continue
            is_tool = any(
                (isinstance(d, ast.Call) and getattr(d.func, "id", "") == "tool")
                or getattr(d, "id", "") == "tool"
                for d in node.decorator_list
            )
            if not is_tool:
                continue

            schema_cls = None
            for d in node.decorator_list:
                if isinstance(d, ast.Call):
                    for kw in d.keywords:
                        if kw.arg == "args_schema" and isinstance(kw.value, ast.Name):
                            schema_cls = kw.value.id

            params = _fields_of_class(classes[schema_cls]) if schema_cls in classes else []

            # Field 没有 description 时，用 docstring 的 Args 兜底
            doc_args = _args_from_docstring(ast.get_docstring(node))
            params = [
                (n, t, d, desc or doc_args.get(n, ""))
                for (n, t, d, desc) in params
            ]

            tools.append(ToolInfo(
                name=node.name,
                module=path.stem,
                purpose=_first_paragraph(ast.get_docstring(node)),
                params=params,
                order=order_map.get(node.name, 999),
            ))

    tools.sort(key=lambda t: (t.order, t.name))
    return tools


# ── 渲染 ──────────────────────────────────────────────────────────────────────

def render(tools: list[ToolInfo]) -> str:
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    out: list[str] = []
    bar = "=" * WIDTH

    out.append(bar)
    out.append("  scAgent 工具参数帮助文档")
    out.append(f"  工具总数: {len(tools)}  |  生成时间: {stamp}")
    out.append("  本文件由 scripts/gen_tools_help.py 自动生成，请勿手工编辑。")
    out.append(bar)
    out.append("")
    out.append("  分析流程: QC → PCA/UMAP → SNN聚类 → 细胞注释")
    out.append("            └→ DimPlot / 标记基因可视化 / 细胞比例 / 热图 / 功能富集")
    out.append("")
    out.append("  调用规则:")
    out.append("    · 工具 1-4 为流水线，必须按顺序执行，前一步成功后才能调用下一步")
    out.append("    · 工具 5-9 为独立可视化，均依赖工具 4 的输出")
    out.append("    · 不确定当前进度时，先调用 check_pipeline_status")
    out.append("    · 所有参数均可省略，省略时使用下表中的默认值")
    out.append("")

    for i, t in enumerate(tools, 1):
        out.append(bar)
        out.append(f"  {i}. {t.name}")
        out.append(bar)
        out.append(f"  模块: tools/{t.module}.py")
        out.append("")
        out.append("  用途:")
        for line in _wrap(t.purpose, WIDTH - 8):
            out.append(f"    {line}")
        out.append("")

        if t.params:
            out.append("  参数:")
            out.append("  " + _pad("参数名", 22) + _pad("类型", 10) + _pad("默认值", 18) + "说明")
            out.append("  " + "─" * (WIDTH - 4))
            for (n, ty, dv, desc) in t.params:
                desc_lines = _wrap(desc or "—", WIDTH - 54) or ["—"]
                out.append("  " + _pad(n, 22) + _pad(ty, 10) + _pad(dv, 18) + desc_lines[0])
                for extra in desc_lines[1:]:
                    out.append("  " + _pad("", 22) + _pad("", 10) + _pad("", 18) + extra)
            out.append("")
        else:
            out.append("  参数: 无")
            out.append("")

    out.append(bar)
    out.append("  文档结束")
    out.append(bar)
    return "\n".join(out) + "\n"


def _wrap(text: str, width: int) -> list[str]:
    """按显示宽度折行（中文按 2 列计）。"""
    if not text:
        return []
    NO_LEAD = "，。、；：）】》”’!?,.;:)]}"
    lines, cur, w = [], "", 0
    for ch in text:
        cw = 2 if ord(ch) > 0x2E80 else 1
        if w + cw > width and cur and ch not in NO_LEAD:
            lines.append(cur)
            cur, w = "", 0
        cur += ch
        w += cw
    if cur:
        lines.append(cur)
    return lines


# ── 入口 ──────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description="生成 TOOLS_HELP.txt")
    ap.add_argument("--check", action="store_true", help="只校验，不写文件")
    ap.add_argument("--stdout", action="store_true", help="输出到标准输出")
    args = ap.parse_args()

    tools = collect()
    if not tools:
        print("未发现任何工具；请检查 agent_core/tools/ 目录", file=sys.stderr)
        return 1

    content = render(tools)

    if args.stdout:
        sys.stdout.write(content)
        return 0

    if args.check:
        current = OUT_FILE.read_text(encoding="utf-8") if OUT_FILE.exists() else ""
        # 忽略生成时间那一行，避免每次运行都判定为不一致
        norm = lambda s: re.sub(r"生成时间: [\d\- :]+", "生成时间: X", s)
        if norm(current) != norm(content):
            print("❌ TOOLS_HELP.txt 与代码不一致，请运行: "
                  "python3 scripts/gen_tools_help.py", file=sys.stderr)
            return 1
        print("✅ TOOLS_HELP.txt 与代码一致")
        return 0

    OUT_FILE.write_text(content, encoding="utf-8")
    print(f"✅ 已生成 {OUT_FILE.relative_to(REPO)}（{len(tools)} 个工具，"
          f"{len(content.splitlines())} 行）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
