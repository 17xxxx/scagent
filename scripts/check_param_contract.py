#!/usr/bin/env python3
"""
check_param_contract.py —— Python↔R 参数契约校验
==================================================
**背景（很重要）**：Python 工具把参数以平铺 JSON 发给 R：
    {"tool_name": "qc", "params": {"project": ..., "min_cells": ...}}
R 端 api.R 用 do.call(fn, params) 调用，R 函数以 `if (!is.null(json$xxx))` 逐个覆盖默认值。

因此**参数名是跨语言契约**：
  · 改坏名字 → 静默失效（旧行为）或被白名单拦下（新行为）
  · 少传参数 → R 用默认值，通常无害
  · 多传/拼错 → 现在会被 api.R 的 PARAM_WHITELIST 拒绝

本脚本在改动工具后运行，确认两层契约仍然一致：
  1. 每个 Python 工具发出的 r_params 键
  2. api.R 中 PARAM_WHITELIST 声明的允许键（由 R 脚本的 json$ 引用生成）
  任何一个 Python 键不在白名单里 → 运行期会被拒绝 → 报错退出码 1。

用法：
    python3 scripts/check_param_contract.py
    python3 scripts/check_param_contract.py --baseline   # 同时对比 git 基线，确认没改坏
"""
from __future__ import annotations

import argparse
import ast
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SNAPSHOT = REPO / "scripts" / "param_contract.snapshot.json"
TOOLS_DIR = REPO / "agent_core" / "tools"
API_R = REPO / "seurat_backend" / "api.R"
BASELINE = "baseline-before-refactor"


# ── 从 Python 工具源码抽取 r_params 键与 tool_name ────────────────────────────

def _dict_keys(node: ast.AST) -> list[str]:
    if isinstance(node, ast.Dict):
        return [k.value for k in node.keys if isinstance(k, ast.Constant)]
    return []


def extract_defaults(src: str) -> dict[str, object]:
    """抽取 args_schema 各字段的默认值 —— 默认值变化同样会改变 R 收到的内容。

    例：dimplot 的 split_by 由 "orig.ident" 改成 None 后，
    Python 不再发送该键，R 就回落到自己的默认值（不拆分），
    输出从 9 张子图变成 1 张图 —— 参数名没变，但行为变了。
    """
    tree = ast.parse(src)
    out: dict[str, object] = {}
    for cls in [n for n in tree.body if isinstance(n, ast.ClassDef)]:
        if "BaseModel" not in [ast.unparse(b) for b in cls.bases]:
            continue
        for node in cls.body:
            if not (isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name)):
                continue
            v = node.value
            if isinstance(v, ast.Call):
                for kw in v.keywords:
                    if kw.arg == "default":
                        try:
                            out[node.target.id] = ast.literal_eval(kw.value)
                        except Exception:            # noqa: BLE001
                            out[node.target.id] = ast.unparse(kw.value)
            elif v is not None:
                try:
                    out[node.target.id] = ast.literal_eval(v)
                except Exception:                    # noqa: BLE001
                    out[node.target.id] = ast.unparse(v)
    return out


def extract_python(src: str) -> tuple[str | None, set[str]]:
    tree = ast.parse(src)
    tool_name: str | None = None
    keys: set[str] = set()

    for node in ast.walk(tree):
        # payload = {"tool_name": "qc", ...}
        if isinstance(node, ast.Dict):
            for k, v in zip(node.keys, node.values):
                if isinstance(k, ast.Constant) and k.value == "tool_name" \
                        and isinstance(v, ast.Constant):
                    tool_name = v.value
        # _call_api("cell_ratio", r_params)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) \
                and node.func.id == "_call_api" and node.args \
                and isinstance(node.args[0], ast.Constant):
            tool_name = node.args[0].value
        # r_params = { "a": ..., "b": ... }
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == "r_params":
                    keys |= set(_dict_keys(node.value))
                # r_params["max_cells_per_ident"] = ...
                if isinstance(t, ast.Subscript) and isinstance(t.value, ast.Name) \
                        and t.value.id == "r_params" and isinstance(t.slice, ast.Constant):
                    keys.add(t.slice.value)
    return tool_name, keys


# ── 从 api.R 抽取 PARAM_WHITELIST ─────────────────────────────────────────────

def extract_whitelist(src: str) -> dict[str, set[str]]:
    m = re.search(r"PARAM_WHITELIST\s*<-\s*list\((.*?)\n\)", src, re.S)
    if not m:
        raise SystemExit("❌ 无法在 api.R 中定位 PARAM_WHITELIST")
    body = m.group(1)

    wl: dict[str, set[str]] = {}
    # 形如：  qc = c("project", "min_cells", ...),
    for entry in re.finditer(r"(\w+)\s*=\s*c\(([^)]*)\)", body, re.S):
        name, items = entry.group(1), entry.group(2)
        wl[name] = set(re.findall(r'"([^"]+)"', items))
    return wl


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", action="store_true",
                    help="额外对比 git 基线（仅信息性，不作为失败依据）")
    ap.add_argument("--accept", action="store_true",
                    help="把当前契约写入快照（有意的改动经确认后用）")
    args = ap.parse_args()

    if not API_R.exists():
        print(f"❌ 找不到 {API_R}", file=sys.stderr)
        return 1

    wl = extract_whitelist(API_R.read_text(encoding="utf-8"))
    # api.R 会给所有工具追加 data_root
    for k in wl:
        wl[k].add("data_root")

    print("═══ Python → R 参数契约 ═══\n")
    problems: list[str] = []
    no_r_call: list[str] = []

    for p in sorted(TOOLS_DIR.glob("*_tool.py")):
        src = p.read_text(encoding="utf-8")
        tool_name, keys = extract_python(src)

        if not keys:
            no_r_call.append(p.name)
            print(f"  ──  {p.name:26} 不调用 R（本地工具），跳过")
            continue

        allowed = wl.get(tool_name or "", set())
        unknown = sorted(keys - allowed)
        missing_phys = sorted(allowed - keys)   # R 允许但 Python 没发（正常，属可选参数）

        if unknown:
            problems.append(f"{p.name} (tool_name={tool_name}): 发送了白名单外的键 {unknown}")
            print(f"  ❌ {p.name:26} tool_name={tool_name}")
            print(f"       未在白名单中: {unknown}")
        else:
            print(f"  ✅ {p.name:26} tool_name={tool_name:12} "
                  f"发送 {len(keys)} 个键，全部在白名单内")

    print()
    if no_r_call:
        print(f"  本地工具（不涉及 R 契约）: {', '.join(no_r_call)}\n")

    # ── 与「已接受的契约快照」对比 ──
    #  为什么不用 git 基线作失败依据：重构过程中会有**有意**的默认值调整，
    #  每次都拿老基线比会一直报红，最终被忽略。改为快照后，
    #  任何偏离都必须显式 --accept 确认一次。
    import json

    current: dict[str, dict[str, object]] = {}
    for p in sorted(TOOLS_DIR.glob("*_tool.py")):
        src = p.read_text(encoding="utf-8")
        tname, keys = extract_python(src)
        if not keys:
            continue
        current[p.name] = {"tool_name": tname,
                           "keys": sorted(keys),
                           "defaults": {k: str(v) for k, v in extract_defaults(src).items()}}

    print("═══ 与契约快照对比 ═══\n")
    if args.accept:
        SNAPSHOT.write_text(json.dumps(current, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
                            encoding="utf-8")
        print(f"  ✅ 已写入快照 {SNAPSHOT.relative_to(REPO)}（{len(current)} 个工具）")
    elif not SNAPSHOT.exists():
        SNAPSHOT.write_text(json.dumps(current, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
                            encoding="utf-8")
        print(f"  ⚠️  快照不存在，已按当前状态生成 {SNAPSHOT.relative_to(REPO)}")
        print("      请人工核对无误后提交，之后任何偏离都会被拦下。")
    else:
        snap = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
        for name in sorted(set(snap) | set(current)):
            a, b = snap.get(name), current.get(name)
            if a == b:
                print(f"  ✅ {name:26} 与快照一致")
                continue
            if a is None:
                print(f"  ⚠️  {name:26} 快照中不存在（新增工具）")
            elif b is None:
                print(f"  ⚠️  {name:26} 快照中存在但当前缺失")
            else:
                ka, kb = set(a.get("keys", [])), set(b.get("keys", []))
                if ka != kb:
                    print(f"  ❌ {name:26} 参数键变化：移除={sorted(ka-kb)} 新增={sorted(kb-ka)}")
                da, db = a.get("defaults", {}), b.get("defaults", {})
                dd = [k for k in set(da) | set(db) if da.get(k) != db.get(k)]
                if dd:
                    print(f"  ⚠️  {name:26} 默认值变化：")
                    for k in sorted(dd):
                        print(f"        {k:22} {da.get(k, '<无>')!r} → {db.get(k, '<无>')!r}")
            problems.append(f"{name} 与契约快照不一致（确认是有意改动后执行 --accept）")
        print()

    # ── 可选：与 git 基线对比（仅信息性）──
    if args.baseline:
        print(f"═══ 与 git 基线 {BASELINE} 对比（信息性，不影响结论）═══\n")
        for p in sorted(TOOLS_DIR.glob("*_tool.py")):
            rel = p.relative_to(REPO).as_posix()
            try:
                old = subprocess.run(["git", "show", f"{BASELINE}:{rel}"],
                                     capture_output=True, text=True, check=True,
                                     cwd=REPO).stdout
            except subprocess.CalledProcessError:
                print(f"  ──  {p.name:26} 基线中不存在")
                continue
            _, ok_old = extract_python(old)
            _, ok_new = extract_python(p.read_text(encoding="utf-8"))
            mark = "✅" if ok_old == ok_new else "ℹ️ "
            print(f"  {mark} {p.name:26} 参数键"
                  f"{'未变' if ok_old == ok_new else '有变化（已由快照确认）'}")
        print()

    if problems:
        print("❌ 契约校验未通过：", file=sys.stderr)
        for x in problems:
            print(f"    {x}", file=sys.stderr)
        print("\n  提示：参数名是 Python↔R 的跨语言契约。若确实要改，"
              "必须同步修改 seurat_backend/0*.R 中的 json$ 覆盖项，"
              "并更新 api.R 的 PARAM_WHITELIST。", file=sys.stderr)
        return 1

    print("✅ 参数契约一致：Python 发送的键全部被 R 端白名单接受")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
