"""
dimplot_tool.py —— 细胞分群可视化工具 (DimPlot)
============================================================
- 通过 Pydantic args_schema 定义可选结构化输入参数
- HTTP POST 调用 R 容器 /api/execute_task → 05_dimplot.R
- 返回 dict 供 Agent 解读
"""
import os
from typing import Optional, List

import requests
from pydantic import BaseModel, Field

from langchain_core.tools import tool

from ._log import log_api_call

SEURAT_BASE_URL = os.getenv("SEURAT_API_BASE", "http://seurat:9000")


class RunDimplotInput(BaseModel):
    """DimPlot 参数 —— 所有字段均为可选"""

    project: Optional[str] = Field(
        default="scRNA_project",
        description="项目名称，默认 scRNA_project",
    )
    reduction: Optional[str] = Field(
        default="umap",
        description="降维类型: umap, tsne, pca，默认 umap",
    )
    group_by: Optional[List[str]] = Field(
        default=["orig.ident", "cell_type"],
        description="分组着色列，默认 [orig.ident, cell_type]",
    )
    split_by: Optional[str] = Field(
        default="orig.ident",
        description="按该列拆分子图，如 orig.ident，默认拆分",
    )
    pt_size: Optional[float] = Field(
        default=0.3,
        description="点大小",
    )
    label: Optional[bool] = Field(
        default=True,
        description="显示聚类/细胞类型标签",
    )
    repel: Optional[bool] = Field(
        default=True,
        description="标签防重叠",
    )


def _call_api(tool_name: str, r_params: dict) -> dict:
    payload = {"tool_name": tool_name, "params": r_params}

    log_api_call(tool_name, r_params)

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


@tool(parse_docstring=True, args_schema=RunDimplotInput)
def run_dimplot(
    project: str = "scRNA_project",
    reduction: str = "umap",
    group_by: Optional[List[str]] = None,
    split_by: Optional[str] = None,
    pt_size: float = 0.3,
    label: bool = True,
    repel: bool = True,
) -> dict:
    """对已完成细胞注释的数据生成 UMAP/tSNE DimPlot 分群可视化。

    读取细胞注释阶段（工具 4）的输出对象，支持多分组着色和样本拆分。
    **所有参数均为可选**，不传则使用默认值。

    Args:
        project: 项目名称
        reduction: 降维类型 umap/tsne/pca
        group_by: 分组着色列列表
        split_by: 拆分子图的列名
        pt_size: 点大小
        label: 是否显示标签
        repel: 标签防重叠
    """
    r_params = {
        "project": project,
        "reduction": reduction,
        "pt_size": pt_size,
        "label": label,
        "repel": repel,
    }
    if group_by is not None:
        r_params["group_by"] = group_by
    if split_by is not None:
        r_params["split_by"] = split_by

    return _call_api("dimplot", r_params)
