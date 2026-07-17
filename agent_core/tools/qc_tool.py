"""
qc_tool.py —— 单细胞数据质量控制工具
============================================================
- 通过 Pydantic args_schema 定义可选结构化输入参数
- 自动扫描 data/rawdata/ 目录下的所有 10X 样本
- 通过 HTTP POST 调用 R 容器 (seurat:9000) 的 /api/execute_task 接口
- 最终触发 01_qc.R 中的 run_quality_control() 执行全流程 8 步质控
- 返回 JSON 格式的 dict 供 Agent 解读
"""
import os
from typing import Dict, Optional

import requests
from pydantic import BaseModel, Field

from langchain_core.tools import tool

# R 容器地址（docker-compose 内网，服务名即主机名）
SEURAT_BASE_URL = os.getenv("SEURAT_API_BASE", "http://seurat:9000")

# 原始数据根目录（容器内路径）
RAW_DATA_DIR = "/workspace/data/rawdata"


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║    结构化输入参数（参考 ch05-tools/03-使用@tool 装饰器 的 args_schema）      ║
# ║    全部字段为 Optional，LLM 不会强制索要，不传则使用内部默认值                ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

class RunQcInput(BaseModel):
    """单细胞质控参数 —— 所有字段均为可选，不传则使用默认值（小鼠物种）。"""

    project: Optional[str] = Field(
        default="scRNA_project",
        description="项目名称，决定输出文件前缀，默认 scRNA_project",
    )
    min_cells: Optional[int] = Field(
        default=3,
        description="基因至少出现在多少个细胞中，默认 3",
    )
    min_features: Optional[int] = Field(
        default=200,
        description="细胞至少表达多少个基因，默认 200",
    )
    nfeature_rna_low: Optional[int] = Field(
        default=200,
        description="nFeature_RNA 过滤下阈值，默认 200",
    )
    nfeature_rna_high: Optional[int] = Field(
        default=6000,
        description="nFeature_RNA 过滤上阈值，默认 6000",
    )
    percent_mt_max: Optional[int] = Field(
        default=5,
        description="线粒体基因比例上限(%)，默认 5",
    )
    percent_ribo_min: Optional[int] = Field(
        default=10,
        description="核糖体基因比例下限(%)，默认 10",
    )
    run_harmony: Optional[bool] = Field(
        default=True,
        description="是否运行 Harmony 批次校正，默认 true",
    )


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                    内部辅助函数                                              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

def _scan_samples(raw_dir: str) -> Dict[str, str]:
    """扫描 data/rawdata/ 目录，返回 {样本名: 数据路径} 的字典。

    判定规则：子目录下包含 matrix.mtx.gz（或 matrix.mtx）文件即视为有效 10X 样本。
    """
    if not os.path.isdir(raw_dir):
        return {}

    samples = {}
    for entry in sorted(os.listdir(raw_dir)):
        full_path = os.path.join(raw_dir, entry)
        if not os.path.isdir(full_path):
            continue
        has_matrix = (
            os.path.isfile(os.path.join(full_path, "matrix.mtx.gz"))
            or os.path.isfile(os.path.join(full_path, "matrix.mtx"))
        )
        if has_matrix:
            samples[entry] = full_path

    return samples


def _call_qc_api(r_params: dict) -> dict:
    """调用 R 容器 POST /api/execute_task，发送平铺 JSON 格式。

    发送 JSON 格式：{"tool_name": "qc", "params": {...}}
    params 中直接平铺 samples、project 及所有 QC 参数。
    api.R 根据 tool_name 查找映射表，用 do.call() 动态执行 01_qc.R 中的函数。
    """
    payload = {"tool_name": "qc", "params": r_params}

    # ── 调试日志 ──
    print("\n══════════════════════════════════════════")
    print("[qc_tool] 发送到 R 容器:")
    print(f"  tool_name : qc")
    print(f"  params 键 : {list(r_params.keys())}")
    samples_count = len(r_params.get("samples", {}))
    print(f"  samples 数量: {samples_count}")
    if samples_count > 0:
        print(f"  samples 名字: {list(r_params['samples'].keys())}")
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


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║          @tool 工具函数（全部参数可选，不传则使用默认值）                     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

@tool(parse_docstring=True, args_schema=RunQcInput)
def run_qc_for_all_samples(
    project: str = "scRNA_project",
    min_cells: int = 3,
    min_features: int = 200,
    nfeature_rna_low: int = 200,
    nfeature_rna_high: int = 6000,
    percent_mt_max: int = 5,
    percent_ribo_min: int = 10,
    run_harmony: bool = True,
) -> dict:
    """对 data/rawdata/ 目录下所有 10X 样本执行完整单细胞质量控制流程。

    此工具会自动扫描数据目录，找到所有包含 10X 格式数据的样本，
    然后一次性调用 R 后端执行完整的 8 步 QC 流水线。

    **所有参数均为可选**，不传则使用内部默认值（小鼠物种）。
    用户说"做质控"即可直接调用，无需提供任何参数。

    QC 流程包括：
      Step 1 - 数据导入（Read10X + CreateSeuratObject）
      Step 2 - 添加细胞元数据（线粒体% + 核糖体%）
      Step 3 - QC 可视化（小提琴图 + 散点图）
      Step 4 - 过滤 + 多样本合并（subset → merge → 生成 batch 列）
      Step 5 - 归一化 + 高变基因筛选
      Step 6 - 高变基因可视化
      Step 7 - 标准化 + 线粒体回归
      Step 8 - PCA + Harmony 批次校正

    所有图片、日志和 .rds 对象均输出到 data/qc/ 目录。

    Args:
        project: 项目名称，决定输出文件前缀（如 scRNA_project_filtered.rds）
        min_cells: 基因至少出现在多少个细胞中（默认 3）
        min_features: 细胞至少表达多少个基因（默认 200）
        nfeature_rna_low: nFeature_RNA 过滤下阈值（默认 200）
        nfeature_rna_high: nFeature_RNA 过滤上阈值（默认 6000）
        percent_mt_max: 线粒体基因比例上限 %（默认 5）
        percent_ribo_min: 核糖体基因比例下限 %（默认 10）
        run_harmony: 是否运行 Harmony 批次校正（默认 true）
    """
    # 1. 扫描样本
    samples = _scan_samples(RAW_DATA_DIR)

    if not samples:
        return {
            "status": "no_data",
            "message": f"在 {RAW_DATA_DIR} 中未找到任何 10X 数据样本",
        }

    # 2. 构建平铺 JSON（samples dict + 全部参数），一次性发给 R
    r_params = {
        "samples": samples,
        "project": project,
        "min_cells": min_cells,
        "min_features": min_features,
        "nfeature_rna_low": nfeature_rna_low,
        "nfeature_rna_high": nfeature_rna_high,
        "percent_mt_max": percent_mt_max,
        "percent_ribo_min": percent_ribo_min,
        "run_harmony": run_harmony,
    }

    # 3. 调用 R 后端
    result = _call_qc_api(r_params)

    # 4. 返回结果给 Agent
    return result
