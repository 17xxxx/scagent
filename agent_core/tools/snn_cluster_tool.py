"""
snn_cluster_tool.py —— 单细胞 SNN 图聚类分析工具
============================================================
- 通过 Pydantic args_schema 定义可选结构化输入参数
- 自动从 data/pca_umap/seuratobject.json 读取 PCA/UMAP 输出的 Seurat 对象
- 通过 HTTP POST 调用 R 容器 (seurat:9000) 的 /api/execute_task 接口
- 最终触发 03_snn_cluster.R 中的 run_snn_cluster() 执行聚类分析
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

class RunSnnInput(BaseModel):
    """单细胞 SNN 聚类参数 —— 所有字段均为可选，不传则使用默认值。"""

    project: Optional[str] = Field(
        default="scRNA_project",
        description="项目名称，决定输出文件前缀，默认 scRNA_project",
    )
    findneighbor_dims: Optional[str] = Field(
        default="1:15",
        description="FindNeighbors 输入维度范围，如 '1:15'，默认 1:15",
    )
    k_param: Optional[int] = Field(
        default=20,
        description="KNN 邻居数，稀有细胞群可适当降低，默认 20",
    )
    resolution: Optional[float] = Field(
        default=0.8,
        description="分群分辨率，越大亚群越多，3000 细胞推荐 0.4-1.2，默认 0.8",
    )
    cluster_algorithm: Optional[int] = Field(
        default=1,
        description="聚类算法：1=Louvain，4=Leiden（推荐复杂数据集），默认 1",
    )


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║          @tool 工具函数（全部参数可选，不传则使用默认值）                     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

@tool(parse_docstring=True, args_schema=RunSnnInput)
def run_snn_cluster(
    project: str = "scRNA_project",
    findneighbor_dims: str = "1:15",
    k_param: int = 20,
    resolution: float = 0.8,
    cluster_algorithm: int = 1,
) -> dict:
    """对 PCA/UMAP 完成的 Seurat 对象执行 SNN 图聚类分析。

    此工具会自动从 data/pca_umap/seuratobject.json 读取上一次降维分析输出的 Seurat 对象，
    然后调用 R 后端执行 SNN 聚类流水线。

    **所有参数均为可选**，不传则使用内部默认值。
    用户说"做聚类分析"或"跑 SNN"即可直接调用，无需提供任何参数。

    分析流程包括：
      Step 1 - 从 data/pca_umap/seuratobject.json 读取 Seurat 对象
      Step 2 - 自动检测可用降维方法（harmony > pca）
      Step 3 - FindNeighbors 构建 SNN 邻接图
      Step 4 - FindClusters 社区发现分群
      Step 5 - 聚类结果统计
      Step 6 - DimPlot UMAP 聚类图可视化

    所有图片、日志和 .rds 对象均输出到 data/snn_cluster/ 目录。

    Args:
        project: 项目名称，默认 scRNA_project
        findneighbor_dims: 输入维度范围，默认 '1:15'
        k_param: KNN 邻居数，默认 20
        resolution: 分群分辨率，默认 0.8
        cluster_algorithm: 聚类算法（1=Louvain, 4=Leiden），默认 1
    """
    # 构建平铺 JSON 参数包
    r_params = {
        "project":            project,
        "findneighbor_dims":  findneighbor_dims,
        "k_param":            k_param,
        "resolution":         resolution,
        "cluster_algorithm":   cluster_algorithm,
    }

    payload = {"tool_name": "snn", "params": r_params}

    # ── 调试日志 ──
    print("\n══════════════════════════════════════════")
    print("[snn_cluster_tool] 发送到 R 容器:")
    print(f"  tool_name : snn")
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
