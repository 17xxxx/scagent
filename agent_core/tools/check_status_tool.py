"""
check_status_tool.py —— 流水线进度查询工具
=============================================
- 检查各步骤的 seuratobject.json / object.json 是否存在，判断进度
- 返回当前完成状态及下一步建议
"""
import os
import json

from pydantic import BaseModel, Field
from langchain_core.tools import tool

# 数据根目录（与 R 容器共享的挂载路径）
DATA_DIR = os.getenv("DATA_DIR", "/workspace/data")

# 各步骤的完成标记文件
STEP_FLAGS = {
    1: ("qc",               "object.json"),        # 01_qc.R 输出的是 object.json
    2: ("pca_umap",         "seuratobject.json"),
    3: ("snn_cluster",      "seuratobject.json"),
    4: ("cell_annotation",  "seuratobject.json"),
}

STEP_NAMES = {
    1: "QC 质控",
    2: "PCA/UMAP 降维",
    3: "SNN 聚类",
    4: "细胞注释",
}

NEXT_TOOLS = {
    0: "run_qc_for_all_samples",
    1: "run_pca_umap",
    2: "run_snn_cluster",
    3: "run_cell_type_annotation",
    4: None,  # 流水线完成
}


class CheckStatusInput(BaseModel):
    """进度查询参数 —— 所有字段均为可选"""
    project: str = Field(default="scRNA_project", description="项目名称")
    data_dir: str = Field(default=DATA_DIR, description="数据根目录")


@tool(parse_docstring=True, args_schema=CheckStatusInput)
def check_pipeline_status(
    project: str = "scRNA_project",
    data_dir: str = DATA_DIR,
) -> str:
    """查询单细胞分析流水线的当前进度和下一步建议。

    当用户询问"到哪一步了"、"当前进度"、"还要做什么"，或者你不确定该调用哪个工具时，
    调用此工具查看各步骤的完成状态。
    """
    lines = [f"项目: {project}"]

    for step in range(1, 5):
        subdir, flag_file = STEP_FLAGS[step]
        flag_path = os.path.join(data_dir, subdir, flag_file)
        if os.path.exists(flag_path):
            lines.append(f"  Step {step} ({STEP_NAMES[step]}): 已完成")
        else:
            next_tool = NEXT_TOOLS[step - 1]
            lines.append(f"  Step {step} ({STEP_NAMES[step]}): 未完成")
            lines.append(f"")
            lines.append(f"当前进度: {STEP_NAMES[step - 1] if step > 1 else '未开始'}")
            lines.append(f"下一步: 调用 {next_tool}")
            return "\n".join(lines)

    # 全部完成
    lines.append("")
    lines.append("流水线基础步骤（1-4）已全部完成。可以调用以下可视化工具：")
    lines.append("  - run_dimplot              (UMAP 散点图)")
    lines.append("  - run_marker_visualization (标记基因小提琴图+气泡图)")
    lines.append("  - run_cell_ratio_viz       (细胞类型比例柱状图)")
    lines.append("  - run_heatmap              (标记基因热图)")
    lines.append("  - run_enrichment_analysis  (GO 功能富集分析)")

    return "\n".join(lines)
