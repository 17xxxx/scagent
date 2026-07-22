"""
cell_ratio_tool.py —— 细胞类型比例可视化工具 (堆叠柱状图)
============================================================
- HTTP POST → 07_cell_ratio.R
"""
import os
from typing import Optional

import requests
from pydantic import BaseModel, Field

from langchain_core.tools import tool

SEURAT_BASE_URL = os.getenv("SEURAT_API_BASE", "http://seurat:9000")


class RunCellRatioInput(BaseModel):
    """细胞类型比例参数 —— 所有字段均为可选"""

    project: Optional[str] = Field(
        default="scRNA_project",
        description="项目名称",
    )
    group_by_sample: Optional[str] = Field(
        default="orig.ident",
        description="样本分组的列名，默认 orig.ident",
    )
    group_by_celltype: Optional[str] = Field(
        default="cell_type",
        description="细胞类型列名，默认 cell_type",
    )
    position: Optional[str] = Field(
        default="stack",
        description="柱状图类型: stack(堆叠) 或 fill(100%填充)",
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


@tool(parse_docstring=True, args_schema=RunCellRatioInput)
def run_cell_ratio_viz(
    project: str = "scRNA_project",
    group_by_sample: str = "orig.ident",
    group_by_celltype: str = "cell_type",
    position: str = "stack",
) -> dict:
    """按样本统计细胞类型比例，绘制堆叠柱状图。

    读取细胞注释阶段的 Seurat 对象，按样本分组统计各细胞类型比例，
    绘制堆叠柱状图，输出到 data/cell_ratio/ 目录。
    **所有参数均为可选。**

    Args:
        project: 项目名称
        group_by_sample: 样本分组的 meta.data 列名
        group_by_celltype: 细胞类型的 meta.data 列名
        position: stack 或 fill
    """
    r_params = {
        "project": project,
        "group_by_sample": group_by_sample,
        "group_by_celltype": group_by_celltype,
        "position": position,
    }
    return _call_api("cell_ratio", r_params)
