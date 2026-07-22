"""
pca_umap_tool.py —— 单细胞降维与可视化工具
============================================================
- 通过 Pydantic args_schema 定义可选结构化输入参数
- 自动从 data/qc/object.json 读取 QC 输出的 Seurat 对象
- 通过 HTTP POST 调用 R 容器 (seurat:9000) 的 /api/execute_task 接口
- 最终触发 02_pca_umap.R 中的 run_pca_umap_analysis() 执行降维分析
- 返回 JSON 格式的 dict 供 Agent 解读
"""
import os
from typing import Optional

import requests
from pydantic import BaseModel, Field

from langchain_core.tools import tool

# R 容器地址（docker-compose 内网，服务名即主机名）
SEURAT_BASE_URL = os.getenv("SEURAT_API_BASE", "http://seurat:9000")


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║    结构化输入参数（全部 Optional，LLM 不强制索要）                           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

class RunPcaUmapInput(BaseModel):
    """单细胞降维可视化参数 —— 所有字段均为可选，不传则使用默认值。"""

    project: Optional[str] = Field(
        default="scRNA_project",
        description="项目名称，决定输出文件前缀，默认 scRNA_project",
    )
    elbow_ndims: Optional[int] = Field(
        default=50,
        description="ElbowPlot 展示的主成分数，默认 50",
    )
    umap_dims: Optional[str] = Field(
        default="1:15",
        description="UMAP 输入的前 N 个主成分，如 '1:15'，默认 1:15",
    )
    umap_n_neighbors: Optional[int] = Field(
        default=30,
        description="UMAP 邻近数，越大越保留全局结构，默认 30",
    )
    umap_min_dist: Optional[float] = Field(
        default=0.3,
        description="UMAP 点间最小距离，越小细胞越抱团，默认 0.3",
    )
    # run_tsne: Optional[bool] = Field(
    #     default=True,
    #     description="是否同时运行 tSNE，默认 true",
    # )
    # tsne_perplexity: Optional[int] = Field(
    #     default=30,
    #     description="tSNE perplexity，默认 30",
    # )
    dimplot_group_by: Optional[str] = Field(
        default="orig.ident",
        description="DimPlot 分组列名，默认 orig.ident（按样本着色）",
    )


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║          @tool 工具函数（全部参数可选，不传则使用默认值）                     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

@tool(parse_docstring=True, args_schema=RunPcaUmapInput)
def run_pca_umap(
    project: str = "scRNA_project",
    elbow_ndims: int = 50,
    umap_dims: str = "1:15",
    umap_n_neighbors: int = 30,
    umap_min_dist: float = 0.3,
    # run_tsne: bool = True,
    # tsne_perplexity: int = 30,
    dimplot_group_by: str = "orig.ident",
) -> dict:
    """对 QC 完成的 Seurat 对象执行降维与可视化分析。

    此工具会自动从 data/qc/object.json 读取上一次质控输出的 Seurat 对象，
    然后调用 R 后端执行降维分析流水线。

    **所有参数均为可选**，不传则使用内部默认值。
    用户说"做降维分析"或"跑 PCA UMAP"即可直接调用，无需提供任何参数。

    分析流程包括：
      Step 1 - 从 data/qc/object.json 读取 Seurat 对象
      Step 2 - 自动检测可用降维方法（harmony > pca）
      Step 3 - ElbowPlot 评估主成分
      Step 4 - RunUMAP 非线性降维
      Step 5 - DimPlot UMAP 可视化

    所有图片、日志和 .rds 对象均输出到 data/pca_umap/ 目录。

    Args:
        project: 项目名称，默认 scRNA_project
        elbow_ndims: ElbowPlot 展示的主成分数，默认 50
        umap_dims: UMAP 输入 PCA 维度范围，如 '1:15'，默认 '1:15'
        umap_n_neighbors: UMAP 邻近数，默认 30
        umap_min_dist: UMAP 点间最小距离，默认 0.3
        dimplot_group_by: 分组着色列名，默认 orig.ident
    """
    # 构建平铺 JSON 参数包
    r_params = {
        "project":         project,
        "elbow_ndims":     elbow_ndims,
        "umap_dims":       umap_dims,
        "umap_n_neighbors": umap_n_neighbors,
        "umap_min_dist":   umap_min_dist,
        # "run_tsne":        run_tsne,
        # "tsne_perplexity": tsne_perplexity,
        "dimplot_group_by": dimplot_group_by,
    }

    payload = {"tool_name": "pca", "params": r_params}

    # ── 调试日志 ──
    print("\n══════════════════════════════════════════")
    print("[pca_umap_tool] 发送到 R 容器:")
    print(f"  tool_name : pca")
    print(f"  params 键 : {list(r_params.keys())}")
    print("══════════════════════════════════════════\n")

    try:
        resp = requests.post(
            f"{SEURAT_BASE_URL}/api/execute_task",
            json=payload,
            timeout=1800,
        )
        resp.raise_for_status()
        return resp.json()
    except requests.exceptions.RequestException as e:
        return {"status": "error", "message": str(e)}
