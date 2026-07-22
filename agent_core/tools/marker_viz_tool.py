"""
marker_viz_tool.py —— 标记基因表达可视化工具 (VlnPlot + DotPlot)
============================================================
- marker_genes 为强制参数，LLM 必须传入
- HTTP POST → 06_marker_viz.R
"""
import os
from typing import Optional, List

import requests
from pydantic import BaseModel, Field

from langchain_core.tools import tool

SEURAT_BASE_URL = os.getenv("SEURAT_API_BASE", "http://seurat:9000")


class RunMarkerVizInput(BaseModel):
    """标记基因可视化参数 —— marker_genes 为必须参数"""

    marker_genes: List[str] = Field(
        ...,
        description="【必须】需要可视化的基因名列表，如 ['CD3D','MS4A1','CD68']",
    )
    project: Optional[str] = Field(
        default="scRNA_project",
        description="项目名称",
    )
    group_by: Optional[str] = Field(
        default="cell_type",
        description="分组列名",
    )
    pt_size: Optional[float] = Field(
        default=0.1,
        description="小提琴图散点大小，0=隐藏散点",
    )
    ncol: Optional[int] = Field(
        default=2,
        description="多基因作图列数",
    )


def _call_api(tool_name: str, r_params: dict) -> dict:
    payload = {"tool_name": tool_name, "params": r_params}
    try:
        resp = requests.post(
            f"{SEURAT_BASE_URL}/api/execute_task",
            json=payload,
            timeout=600,
        )
        resp.raise_for_status()
        return resp.json()
    except requests.exceptions.RequestException as e:
        return {"status": "error", "message": str(e)}


@tool(parse_docstring=True, args_schema=RunMarkerVizInput)
def run_marker_visualization(
    marker_genes: List[str],
    project: str = "scRNA_project",
    group_by: str = "cell_type",
    pt_size: float = 0.1,
    ncol: int = 2,
) -> dict:
    """对指定标记基因生成小提琴图和气泡图。

    读取细胞注释阶段的 Seurat 对象，对提供的基因列表绘制 VlnPlot + DotPlot。
    **marker_genes 为必须参数**，由 LLM 根据上下文推断合适的标记基因传入。
    生成图片输出到 data/marker_viz/ 目录。

    Args:
        marker_genes: 【必须】基因名列表
        project: 项目名称
        group_by: 分组列名
        pt_size: 散点大小
        ncol: 列数
    """
    r_params = {
        "project": project,
        "marker_genes": marker_genes,
        "group_by": group_by,
        "pt_size": pt_size,
        "ncol": ncol,
    }

    return _call_api("marker_viz", r_params)
