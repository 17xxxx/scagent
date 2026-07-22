"""
cell_annotation_tool.py —— 单细胞标记基因识别与细胞类型注释工具
============================================================
- 通过 Pydantic args_schema 定义可选结构化输入参数
- 自动从 data/snn_cluster/seuratobject.json 读取 SNN 聚类输出的 Seurat 对象
- 通过 HTTP POST 调用 R 容器 (seurat:9000) 的 /api/execute_task 接口
- 最终触发 04_cell_annotation.R 中的 run_cell_annotation() 执行注释分析
- 返回 JSON 格式的 dict 供 Agent 解读
"""
import os
from typing import Optional

import requests
from pydantic import BaseModel, Field

from langchain_core.tools import tool

from ._log import log_api_call

# R 容器地址（docker-compose 内网，服务名即主机名）
SEURAT_BASE_URL = os.getenv("SEURAT_API_BASE", "http://seurat:9000")


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║    结构化输入参数（全部 Optional，LLM 不强制索要）                           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

class RunAnnotationInput(BaseModel):
    """单细胞注释参数 —— 所有字段均为可选，不传则使用默认值（小鼠物种）。"""

    project: Optional[str] = Field(
        default="scRNA_project",
        description="项目名称，决定输出文件前缀，默认 scRNA_project",
    )
    species: Optional[str] = Field(
        default="mouse",
        description="物种：mouse（默认，MouseRNAseqData）或 human（HumanPrimaryCellAtlasData）",
    )
    logfc_threshold: Optional[float] = Field(
        default=0.25,
        description="差异表达 logFC 阈值，默认 0.25（Seurat 官方值，不宜设太高）",
    )
    max_cells_per_ident: Optional[int] = Field(
        default=None,
        description="每个聚类最多采样细胞数，设 500-1000 可加速，默认不限",
    )
    singler_de_method: Optional[str] = Field(
        default="classic",
        description="SingleR 差异分析方法：classic / wilcox / t，默认 classic",
    )


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║          @tool 工具函数（全部参数可选，不传则使用默认值）                     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

@tool(parse_docstring=True, args_schema=RunAnnotationInput)
def run_cell_type_annotation(
    project: str = "scRNA_project",
    species: str = "mouse",
    logfc_threshold: float = 0.25,
    max_cells_per_ident: Optional[int] = None,
    singler_de_method: str = "classic",
) -> dict:
    """对 SNN 聚类完成的 Seurat 对象执行标记基因识别与细胞类型自动注释。

    此工具会自动从 data/snn_cluster/seuratobject.json 读取上一次聚类分析的 Seurat 对象，
    然后调用 R 后端执行 FindAllMarkers + SingleR 注释流水线。

    **所有参数均为可选**，不传则使用内部默认值（小鼠物种）。
    用户说"做细胞注释"或"识别细胞类型"即可直接调用，无需提供任何参数。

    分析流程包括：
      Step 1 - 从 data/snn_cluster/seuratobject.json 读取 Seurat 对象
      Step 2 - FindAllMarkers 寻找每个聚类的标记基因
      Step 3 - 标记基因统计 + 保存 CSV
      Step 4 - SingleR 参考数据集自动注释（小鼠用 MouseRNAseqData）
      Step 5 - 注释结果写入 Seurat 对象元数据
      Step 6 - DimPlot UMAP 细胞类型可视化

    所有图片、CSV、日志和 .rds 对象均输出到 data/cell_annotation/ 目录。

    Args:
        project: 项目名称，默认 scRNA_project
        species: 物种（mouse 或 human），默认 mouse
        logfc_threshold: 标记基因 logFC 阈值，默认 1
        max_cells_per_ident: 每个聚类最大采样细胞数（NULL=不限），默认不限
        singler_de_method: SingleR 差异分析方法，默认 classic
    """
    # 构建平铺 JSON 参数包（None 值不发送，R 侧用默认值）
    r_params = {
        "project":          project,
        "species":          species,
        "logfc_threshold":  logfc_threshold,
        "singler_de_method": singler_de_method,
    }
    if max_cells_per_ident is not None:
        r_params["max_cells_per_ident"] = max_cells_per_ident

    payload = {"tool_name": "anno", "params": r_params}

    log_api_call("anno", r_params)

    try:
        resp = requests.post(
            f"{SEURAT_BASE_URL}/api/execute_task",
            json=payload,
            timeout=3600,
        )
        resp.raise_for_status()
        return resp.json()
    except requests.exceptions.RequestException as e:
        return {"status": "error", "message": str(e)}
