#!/usr/bin/env python3
"""
check_tool_schemas.py —— 工具参数 schema 自检（构建期执行）
=============================================================
背景：曾经出现过这样一次运行期崩溃 ——

    pipeline_cli.py status
    → tool.invoke({"project": "x", "data_dir": None})
    → pydantic ValidationError: data_dir
        Input should be a valid string [type=string_type, input_value=None]

原因是某个 args_schema 字段被声明成了**必填 str**，而调用方合理地传了 None
（CLI 的 --data-dir 默认值就是 None）。这类错误在构建期完全可以拦住，
不必等到用户第一次下指令才炸。

本脚本检查三件事（对每个工具）：
  1. 空参数 {} 能否通过校验 —— 所有字段都应有默认值
  2. 所有字段显式传 None 能否通过 —— Optional 字段必须容忍 None
  3. 只传 project 的常见调用方式能否通过

用法：
    python3 scripts/check_tool_schemas.py     # 退出码 0 = 全部通过

在 agent_core/Dockerfile 中作为构建期断言执行，任何一项失败即中断构建。
"""
from __future__ import annotations

import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "agent_core"))

try:
    from agent_factory import ALL_TOOLS          # noqa: E402
except Exception as exc:                          # noqa: BLE001
    print(f"❌ 无法导入工具集: {exc}", file=sys.stderr)
    raise SystemExit(1)


def _fields(schema) -> list[str]:
    fields = getattr(schema, "model_fields", None)
    if fields is None:                            # pydantic v1 兼容
        fields = getattr(schema, "__fields__", {})
    return list(fields.keys())


def main() -> int:
    failures: list[tuple[str, str, str]] = []
    checked = 0

    for tool in ALL_TOOLS:
        schema = getattr(tool, "args_schema", None)
        if schema is None:
            print(f"  ⚠️  {tool.name}: 没有 args_schema（无参数工具），跳过")
            continue

        fields = _fields(schema)
        checked += 1

        cases = [
            ("空参数 {}", {}),
            (f"全部 {len(fields)} 个字段显式传 None", {f: None for f in fields}),
        ]
        if "project" in fields:
            cases.append(("仅传 project", {"project": "scRNA_project"}))

        for label, payload in cases:
            try:
                schema.model_validate(payload)
            except Exception as exc:              # noqa: BLE001
                failures.append((tool.name, label, str(exc).replace("\n", " ")[:200]))

    print(f"\n── 工具参数 schema 自检（{checked} 个工具）──")
    for name, label, err in failures:
        print(f"  ❌ {name}  ←  {label}")
        print(f"       {err}")

    if failures:
        print(f"\n❌ {len(failures)} 项校验失败。\n"
              f"   典型原因：某个字段被声明为必填类型（如 `data_dir: str`），\n"
              f"   而调用方会合理地传 None。请改为 `Optional[...] = Field(default=None, ...)`，\n"
              f"   并在函数体内用 `x = x or <默认值>` 兜底。", file=sys.stderr)
        return 1

    print(f"  ✅ 全部通过（{checked} 个工具 × 3 种调用方式）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
