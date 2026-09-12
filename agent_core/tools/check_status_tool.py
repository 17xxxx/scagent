"""
check_status_tool.py —— 流水线进度查询工具
=============================================
- 检查全部 9 个步骤的产物是否存在，并**校验索引内容**（不只看文件在不在）
- 返回当前完成状态与下一步建议

与旧版的区别：
  1. 从只覆盖步骤 1-4 扩展到 1-9
  2. 不再只判断"文件是否存在"，还会解析索引 JSON、确认其中的 RDS 真实存在
     （旧版会把一个损坏/过期的索引误报成"已完成"）
  3. 路径来自 SCAGENT_DATA_DIR，不再硬编码
"""
import glob
import json
import os
from typing import Dict, List, Optional, Tuple

from pydantic import BaseModel, Field
from langchain_core.tools import tool

def _data_dir() -> str:
    """数据根目录。

    在**调用时**读取环境变量，而不是 import 时固化成常量 ——
    否则 pipeline_cli.py 的 --data-dir 与服务端多租户切换都不会生效。
    """
    return os.getenv("SCAGENT_DATA_DIR", "/workspace/data")


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  步骤定义                                                                     ║
# ║  (序号, 目录, 显示名, 对应的工具, 完成标记 glob, 是否校验索引)                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
STEPS: List[Tuple[int, str, str, str, str, bool]] = [
    (1, "qc",              "QC 质控",      "run_qc_for_all_samples",    "object.json",          True),
    (2, "pca_umap",        "PCA/UMAP 降维", "run_pca_umap",              "seuratobject.json",    True),
    (3, "snn_cluster",     "SNN 聚类",     "run_snn_cluster",           "seuratobject.json",    True),
    (4, "cell_annotation", "细胞注释",      "run_cell_type_annotation",  "seuratobject.json",    True),
    # 步骤 5-9 是独立可视化，不写索引，用产物文件判定
    (5, "dimplot",         "散点图",       "run_dimplot",               "*_dimplot.pdf",        False),
    (6, "marker_viz",      "标记基因可视化", "run_marker_visualization",  "*_marker_vln.pdf",     False),
    (7, "cell_ratio",      "细胞比例图",    "run_cell_ratio_viz",        "*_cell_ratio.pdf",     False),
    (8, "heatmap",         "标记基因热图",  "run_heatmap",               "*_heatmap.pdf",        False),
    (9, "enrichment",      "GO 富集分析",   "run_enrichment_analysis",   "*_go_enrich.pdf",      False),
]

PIPELINE_STEPS = [s for s in STEPS if s[0] <= 4]      # 必须按顺序执行
VIZ_STEPS = [s for s in STEPS if s[0] >= 5]           # 依赖步骤 4


def _check_step(step: Tuple, data_dir: str) -> Tuple[str, str]:
    """检查单个步骤。

    Returns:
        (状态, 说明) —— 状态取值: "done" / "missing" / "invalid"
    """
    _, subdir, _name, _tool, pattern, check_index = step
    step_dir = os.path.join(data_dir, subdir)

    if not os.path.isdir(step_dir):
        return "missing", f"目录不存在: {step_dir}"

    matches = sorted(glob.glob(os.path.join(step_dir, pattern)))
    if not matches:
        return "missing", f"未找到产物: {subdir}/{pattern}"

    if not check_index:
        return "done", os.path.basename(matches[0])

    # ── 索引内容校验：确认 latest_rds 指向的文件真的存在 ──
    index_path = matches[0]
    try:
        with open(index_path, "r", encoding="utf-8") as fh:
            info = json.load(fh)
    except (json.JSONDecodeError, OSError) as exc:
        return "invalid", f"索引损坏，无法解析: {os.path.basename(index_path)} ({exc})"

    rds_name = info.get("latest_rds")
    if not rds_name:
        return "invalid", f"索引缺少 latest_rds 字段: {os.path.basename(index_path)}"

    rds_path = os.path.join(step_dir, rds_name)
    if not os.path.exists(rds_path):
        return "invalid", f"索引指向的 RDS 不存在: {subdir}/{rds_name}（可能是过期索引）"

    size_mb = os.path.getsize(rds_path) / 1048576
    return "done", f"{rds_name} ({size_mb:.0f} MB)"


def _render(project: str, data_dir: str, results: Dict[int, Tuple[str, str]]) -> str:
    icons = {"done": "✅ 已完成", "missing": "⬜ 未完成", "invalid": "⚠️  索引异常"}
    lines = [f"项目: {project}", f"数据目录: {data_dir}", ""]

    lines.append("── 流水线（必须按顺序执行）──")
    for step in PIPELINE_STEPS:
        st, note = results[step[0]]
        lines.append(f"  Step {step[0]} {step[2]:<14} {icons[st]}   {note}")

    lines.append("")
    lines.append("── 可视化（均依赖 Step 4 的注释结果）──")
    for step in VIZ_STEPS:
        st, note = results[step[0]]
        lines.append(f"  Step {step[0]} {step[2]:<14} {icons[st]}   {note}")

    # ── 下一步建议 ──
    lines.append("")
    blocked = None
    for step in PIPELINE_STEPS:
        st, _ = results[step[0]]
        if st != "done":
            blocked = step
            break

    if blocked is not None:
        idx, _sub, name, tool, _pat, _ci = blocked
        prev = "未开始" if idx == 1 else f"Step {idx - 1} 已完成"
        lines.append(f"当前进度: {prev}")
        lines.append(f"下一步:   调用 {tool} 以完成「{name}」")
        if idx > 1:
            lines.append("注意:     流水线步骤必须按顺序执行，请勿跳步。")
        return "\n".join(lines)

    anno_done = results[4][0] == "done"
    if anno_done:
        pending = [s for s in VIZ_STEPS if results[s[0]][0] != "done"]
        if pending:
            lines.append("流水线（Step 1-4）已全部完成。可执行的可视化工具：")
            for s in pending:
                lines.append(f"  - {s[3]:<28} ({s[2]})")
        else:
            lines.append("全部 9 个步骤均已完成。")
    return "\n".join(lines)


class CheckStatusInput(BaseModel):
    """进度查询参数 —— 所有字段均为可选"""

    project: Optional[str] = Field(default=None, description="项目名称")
    # Optional 且默认 None：调用方（如 pipeline_cli）可能显式传 None，
    # 若声明为必填 str 会触发 pydantic ValidationError
    data_dir: Optional[str] = Field(
        default=None,
        description="数据根目录；不传则读 SCAGENT_DATA_DIR 环境变量",
    )


@tool(parse_docstring=True, args_schema=CheckStatusInput)
def check_pipeline_status(
    project: Optional[str] = None,
    data_dir: Optional[str] = None,
) -> str:
    """查询单细胞分析流水线的当前进度和下一步建议。

    当用户询问"到哪一步了"、"当前进度"、"还要做什么"，或者你不确定该调用哪个工具时，
    调用此工具查看各步骤的完成状态。

    会校验索引文件内容与对应的 RDS 是否真实存在，因此不会把损坏或过期的索引
    误报为"已完成"。

    Args:
        project: 项目名称
        data_dir: 数据根目录（默认取 SCAGENT_DATA_DIR 环境变量）
    """
    # 调用时解析：显式传参 > 环境变量 > 默认值
    project = project or "scRNA_project"
    data_dir = data_dir or _data_dir()
    results = {step[0]: _check_step(step, data_dir) for step in STEPS}
    return _render(project, data_dir, results)
