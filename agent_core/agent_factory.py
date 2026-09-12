"""
agent_factory.py —— 构建 scAgent 的 LangGraph agent
=====================================================
被两个入口共用：
  · agent_main.py  —— 本地交互式 CLI（开发/调试）
  · server.py      —— HTTP 服务（生产部署）

把"怎么造 agent"集中在一处，避免两份配置漂移。
"""
from __future__ import annotations

import os
import sqlite3
from typing import List, Optional, Tuple

from langchain.agents import create_agent
from langchain.agents.middleware import (
    HumanInTheLoopMiddleware,
    SummarizationMiddleware,
    ToolCallLimitMiddleware,
)
from langchain_openai import ChatOpenAI

from config import Settings, load_settings

# 工具注册（每新增工具在此 import 即可）
from tools import (
    check_pipeline_status,
    run_cell_ratio_viz,
    run_cell_type_annotation,
    run_dimplot,
    run_enrichment_analysis,
    run_heatmap,
    run_marker_visualization,
    run_pca_umap,
    run_qc_for_all_samples,
    run_snn_cluster,
)

ALL_TOOLS: List = [
    run_qc_for_all_samples,
    run_pca_umap,
    run_snn_cluster,
    run_cell_type_annotation,
    run_dimplot,
    run_marker_visualization,
    run_cell_ratio_viz,
    run_heatmap,
    run_enrichment_analysis,
    check_pipeline_status,
]


SYSTEM_PROMPT = """\
你是一个单细胞 RNA 测序（scRNA-seq）数据分析助手，共 10 个可用工具（9 个分析工具 + 1 个进度查询工具）。

【数据要求】
- 原始数据位于数据根目录的 data/rawdata/ 下（容器内默认 /workspace/data/rawdata）
- 格式：每个样本一个子文件夹，文件夹内直接存放 10X 格式的三个文件
  （barcodes.tsv.gz / barcodes.tsv、features.tsv.gz / features.tsv、matrix.mtx.gz / matrix.mtx），
  文件名中不能带样本名前缀

【进度查询】
0. check_pipeline_status — 查询流水线当前进度，返回各步骤完成状态和下一步建议。
   不确定该调用什么时先调此工具。

【分析工具】
1. run_qc_for_all_samples — 质控（8步：导入→元数据→QC可视化→过滤合并→归一化→高变基因→标准化→PCA+Harmony）
2. run_pca_umap — PCA 降维 + UMAP 可视化
3. run_snn_cluster — SNN 图聚类分群
4. run_cell_type_annotation — 标记基因识别 + SingleR 自动注释
5. run_dimplot — UMAP/PCA 散点图，支持多分组着色与样本拆分
6. run_marker_visualization — 标记基因小提琴图 + 气泡图。**必填**: marker_genes
7. run_cell_ratio_viz — 细胞类型比例堆叠柱状图
8. run_heatmap — Top N 标记基因热图
9. run_enrichment_analysis — GO 功能富集分析。**必填**: cell_group_names

（各工具的完整参数与默认值见 TOOLS_HELP.txt）

【调用规则】
- 工具 1-4 为流水线，必须按顺序执行（QC→PCA/UMAP→SNN→注释），前一步成功后才能调用下一步
- 工具 5-9 为独立可视化，均依赖工具 4 的输出
- 所有可选参数不传则使用默认值；用户说"做质控/降维/聚类/注释"即可直接调用
- 必填参数由你根据上下文推断传入；不确定细胞类型名时，先看 check_pipeline_status 的输出
- 不确定进度时，先调用 check_pipeline_status
- 请保持回答简洁专业，用通俗语言解读工具返回的结果
- 当被用户拒绝执行工具时立刻停下来询问，不要重复调用其他工具或直接修改参数调用
"""


def build_model(settings: Settings, for_summary: bool = False) -> ChatOpenAI:
    """构建 LLM 客户端。for_summary=True 时用较低温度做历史摘要。"""
    if not settings.llm_enabled:
        raise RuntimeError(
            "LLM 已被禁用（SCAGENT_LLM_PROVIDER=none）。"
            "请改用 pipeline_cli.py 执行确定性分析流程。"
        )
    kwargs = dict(
        model=settings.llm_model,
        api_key=settings.llm_api_key,
        temperature=0.3 if for_summary else settings.llm_temperature,
        timeout=settings.llm_timeout,
        max_retries=settings.llm_max_retries,
    )
    if settings.llm_base_url:
        kwargs["base_url"] = settings.llm_base_url
    return ChatOpenAI(**kwargs)


def build_checkpointer(settings: Settings) -> Tuple[object, str]:
    """构建会话检查点存储。

    优先 SQLite（服务重启不丢会话）；不可用时降级为内存并说明原因。
    """
    try:
        from langgraph.checkpoint.sqlite import SqliteSaver

        os.makedirs(os.path.dirname(settings.checkpoint_db) or ".", exist_ok=True)
        conn = sqlite3.connect(settings.checkpoint_db, check_same_thread=False)
        return SqliteSaver(conn), f"sqlite:{settings.checkpoint_db}"
    except Exception as exc:                      # noqa: BLE001
        from langgraph.checkpoint.memory import InMemorySaver

        return InMemorySaver(), f"memory（SQLite 不可用: {exc}）"


def build_hitl_middleware(settings: Settings) -> HumanInTheLoopMiddleware:
    """HITL 中间件：每次工具调用前需要人工批准。"""
    names = [t.name for t in ALL_TOOLS]
    interrupt_on = {
        name: {
            "allowed_decisions": ["approve", "reject"],
            "description": f"准备执行分析工具 {name}",
        }
        for name in names
    }
    return HumanInTheLoopMiddleware(
        interrupt_on=interrupt_on,
        description_prefix="⚠️ [HITL 拦截]",
    )


def build_agent(settings: Optional[Settings] = None, checkpointer: Optional[object] = None):
    """构建 agent。

    Returns:
        (agent, info) —— info 是 dict，含 checkpointer 类型等诊断信息
    """
    settings = settings or load_settings()

    if checkpointer is None:
        checkpointer, cp_desc = build_checkpointer(settings)
    else:
        cp_desc = type(checkpointer).__name__

    model = build_model(settings)

    middleware = [
        SummarizationMiddleware(
            model=build_model(settings, for_summary=True),
            trigger=[("tokens", settings.max_history_tokens)],
            keep=("messages", settings.keep_recent_messages),
        ),
        ToolCallLimitMiddleware(
            run_limit=settings.tool_run_limit,
            exit_behavior="continue",
        ),
        build_hitl_middleware(settings),
    ]

    agent = create_agent(
        model=model,
        tools=ALL_TOOLS,
        system_prompt=SYSTEM_PROMPT,
        checkpointer=checkpointer,
        middleware=middleware,
    )

    return agent, {
        "checkpointer": cp_desc,
        "llm_provider": settings.llm_provider,
        "llm_model": settings.llm_model,
        "tool_count": len(ALL_TOOLS),
        "hitl_mode": settings.hitl_mode,
    }


def tool_names() -> List[str]:
    return [t.name for t in ALL_TOOLS]
