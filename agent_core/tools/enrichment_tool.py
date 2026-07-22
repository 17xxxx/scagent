"""
enrichment_tool.py —— 功能富集可视化工具 (GO/KEGG)
============================================================
- cell_group_names 为强制参数，LLM 必须传入
- HTTP POST → 09_enrichment.R
"""
import os
from typing import Optional, List

import requests
from pydantic import BaseModel, Field

from langchain_core.tools import tool

SEURAT_BASE_URL = os.getenv("SEURAT_API_BASE", "http://seurat:9000")


class RunEnrichmentInput(BaseModel):
    """功能富集参数 —— cell_group_names 为必须参数"""

    cell_group_names: List[str] = Field(
        ...,
        description="【必须】目标细胞类型名称列表，如 ['T_cells', 'B_cells']",
    )
    project: Optional[str] = Field(
        default="scRNA_project",
        description="项目名称",
    )
    species: Optional[str] = Field(
        default="mouse",
        description="物种: mouse 或 human",
    )
    ont: Optional[str] = Field(
        default="BP",
        description="GO 本体: BP(生物过程)/CC(细胞组分)/MF(分子功能)/ALL",
    )
    qvalue_cutoff: Optional[float] = Field(
        default=0.05,
        description="q 值过滤阈值",
    )
    show_category: Optional[int] = Field(
        default=10,
        description="展示的 Top N 通路数",
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


@tool(parse_docstring=True, args_schema=RunEnrichmentInput)
def run_enrichment_analysis(
    cell_group_names: List[str],
    project: str = "scRNA_project",
    species: str = "mouse",
    ont: str = "BP",
    qvalue_cutoff: float = 0.05,
    show_category: int = 10,
) -> dict:
    """对指定细胞群做 GO 生物学功能富集分析。

    读取细胞注释阶段的 Seurat 对象和 cluster_markers.csv，
    对指定细胞群的标记基因做 GO 富集分析并生成柱状图。
    输出到 data/enrichment/ 目录。

    **cell_group_names 为必须参数**，由 LLM 从上下文推断。
    如果用户没有指定细胞群，LLM 应使用细胞注释结果中发现的细胞类型名称。

    Args:
        cell_group_names: 【必须】目标细胞类型名称列表
        project: 项目名称
        species: mouse 或 human
        ont: BP/CC/MF/ALL
        qvalue_cutoff: q 值阈值
        show_category: 展示通路数
    """
    r_params = {
        "project": project,
        "cell_group_names": cell_group_names,
        "species": species,
        "ont": ont,
        "qvalue_cutoff": qvalue_cutoff,
        "show_category": show_category,
    }
    if species == "human":
        r_params["org_db"] = "org.Hs.eg.db"
    else:
        r_params["org_db"] = "org.Mm.eg.db"

    return _call_api("enrichment", r_params)
