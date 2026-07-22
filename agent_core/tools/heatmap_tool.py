"""
heatmap_tool.py —— 标记基因热图工具 (DoHeatmap)
============================================================
- HTTP POST → 08_heatmap.R
"""
import os
from typing import Optional

import requests
from pydantic import BaseModel, Field

from langchain_core.tools import tool

SEURAT_BASE_URL = os.getenv("SEURAT_API_BASE", "http://seurat:9000")


class RunHeatmapInput(BaseModel):
    """标记基因热图参数 —— 所有字段均为可选"""

    project: Optional[str] = Field(
        default="scRNA_project",
        description="项目名称",
    )
    top_n: Optional[int] = Field(
        default=5,
        description="每个聚类的 Top N 标记基因",
    )
    group_by: Optional[str] = Field(
        default="cell_type",
        description="分组列名",
    )
    sample_n: Optional[int] = Field(
        default=None,
        description="随机抽样细胞数（NULL=全部），大规模数据建议设5000",
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


@tool(parse_docstring=True, args_schema=RunHeatmapInput)
def run_heatmap(
    project: str = "scRNA_project",
    top_n: int = 5,
    group_by: str = "cell_type",
    sample_n: Optional[int] = None,
) -> dict:
    """对各细胞群的 Top N 标记基因绘制热图。

    读取细胞注释阶段的 Seurat 对象和 cluster_markers.csv，
    提取每个聚类的 Top N 标记基因，绘制 DoHeatmap 热图。
    输出到 data/heatmap/ 目录。
    **所有参数均为可选。**

    Args:
        project: 项目名称
        top_n: 每个聚类的 Top N 标记基因
        group_by: 分组列名
        sample_n: 随机抽样细胞数
    """
    r_params = {
        "project": project,
        "top_n": top_n,
        "group_by": group_by,
    }
    if sample_n is not None:
        r_params["sample_n"] = sample_n
    return _call_api("heatmap", r_params)
