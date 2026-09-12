"""
agent_main.py —— 带历史会话的 scRNA 分析 Agent
================================================================================
- 基于 LangGraph create_agent，内建 InMemorySaver 持久化对话历史
- 工具调用框架已就绪，当前工具列表为空，后续按需注入
- 使用 SummarizationMiddleware 自动摘要压缩历史消息，防止上下文溢出
- 主模型与压缩模型均使用 DeepSeek API（DEEPSEEK_API_KEY / DEEPSEEK_BASE_URL）
- 启动时自动从项目根目录 .env 文件加载环境变量
"""
import json
import os
from typing import List

from dotenv import load_dotenv
from langchain.agents import create_agent
from langchain.agents.middleware import (
    HumanInTheLoopMiddleware,
    SummarizationMiddleware,
    ToolCallLimitMiddleware,
)
from langchain_openai import ChatOpenAI
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.types import Command

# 加载 .env 文件（优先级：系统环境变量 > .env）
load_dotenv()


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                        历史消息自动摘要模块                                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# 摘要用模型：DeepSeek（低成本、高速度，适合做摘要）
summarizer = ChatOpenAI(
    model="deepseek-v4-flash",
    api_key=os.getenv("DEEPSEEK_API_KEY"),
    base_url=os.getenv("DEEPSEEK_BASE_URL", None),
    temperature=0.3,
)

# SummarizationMiddleware 配置：
#   trigger=[("tokens", 1000)]  → 消息总 tokens 超过 1000 时触发摘要
#   keep=("messages", 6)        → 保留最近 6 条消息原文，其余压缩为摘要
summarization_middleware = SummarizationMiddleware(
    model=summarizer,
    trigger=[
        ("tokens", int(os.getenv("MAX_HISTORY_TOKENS", "6000"))),
    ],
    keep=("messages", int(os.getenv("KEEP_RECENT_MESSAGES", "10"))),
)


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                         Agent 核心配置                                      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# ── 主模型（DeepSeek，通过环境变量切换） ──
model = ChatOpenAI(
    model="deepseek-v4-flash",
    api_key=os.getenv("DEEPSEEK_API_KEY"),
    base_url=os.getenv("DEEPSEEK_BASE_URL", None),
    temperature=0,
)

# ── 工具注册（从 tools/ 子目录导入，每新增工具在此 import 即可） ──
from tools import run_qc_for_all_samples, run_pca_umap, run_snn_cluster, run_cell_type_annotation, \
    run_dimplot, run_marker_visualization, run_cell_ratio_viz, run_heatmap, run_enrichment_analysis, \
    check_pipeline_status

tools: List = [
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

# ── 系统提示词 ──
SYSTEM_PROMPT = """\
你是一个单细胞 RNA 测序（scRNA-seq）数据分析助手，共 10 个可用工具（9 个分析工具 + 1 个进度查询工具）。

【数据要求】
- 原始数据必须放在 data/rawdata/ 目录下
- 格式：每个样本一个子文件夹，文件夹内直接存放 10X 格式的三个文件（barcodes.tsv.gz / barcodes.tsv、features.tsv.gz / features.tsv、matrix.mtx.gz / matrix.mtx），文件名中不能带样本名前缀

【进度查询】
0. check_pipeline_status — 查询流水线当前进度，返回各步骤完成状态和下一步建议。不确定该调用什么时先调此工具。

【分析工具】
1. run_qc_for_all_samples — 质控（8步流水线：导入→元数据→QC可视化→过滤合并→归一化→高变基因→标准化→PCA+Harmony）。可选参数: project, min_cells(3), min_features(200), nfeature_rna_low(200), nfeature_rna_high(6000), percent_mt_max(5), percent_ribo_min(10), run_harmony(true)

2. run_pca_umap — PCA降维+UMAP可视化。可选参数: project, elbow_ndims(50), umap_dims("1:15"), umap_n_neighbors(30), umap_min_dist(0.3), dimplot_group_by(orig.ident)

3. run_snn_cluster — SNN图聚类分群。可选参数: project, findneighbor_dims("1:15"), k_param(20), resolution(0.8), cluster_algorithm(1=Louvain/4=Leiden)

4. run_cell_type_annotation — 标记基因识别+SingleR自动注释。可选参数: project, species(mouse/human), logfc_threshold(0.25), max_cells_per_ident, singler_de_method(classic/wilcox/t)

5. run_dimplot — UMAP/pca散点图，支持多分组着色和样本拆分。可选参数: project, reduction(umap/pca), group_by, split_by, pt_size(0.3), label(true), repel(true)

6. run_marker_visualization — 标记基因小提琴图+气泡图。**必填**: marker_genes(基因名列表)。可选: project, group_by(cell_type), pt_size(0.1), ncol(2)

7. run_cell_ratio_viz — 细胞类型比例堆叠柱状图。可选参数: project, group_by_sample(orig.ident), group_by_celltype(cell_type), position(stack/fill)

8. run_heatmap — Top N标记基因热图。可选参数: project, top_n(5), group_by(cell_type), sample_n

9. run_enrichment_analysis — GO功能富集分析。**必填**: cell_group_names(细胞类型名列表)。可选: project, species(mouse/human), ont(BP/CC/MF/ALL), qvalue_cutoff(0.05), show_category(10)

【调用规则】
- 工具1-4为流水线，必须按顺序执行（QC→PCA/UMAP→SNN→注释），前一步成功后才能调用下一步
- 工具5-9为独立可视化，均依赖工具4的输出
- 所有可选参数不传则使用括号内默认值（小鼠物种），用户说"做质控/降维/聚类/注释"即可直接调用
- 必填参数由你根据上下文推断传入
- 不确定进度时，先调用 check_pipeline_status
- 请保持回答简洁专业，用通俗语言解读工具返回的结果
- 当被用户拒绝执行工具时立刻停下来询问，不要重复调用其他工具或直接修改参数调用。
"""

# ── HITL（Human-in-the-Loop）中间件配置 ──
tool_names = [t.name for t in tools]

interrupt_on_config = {
    name: {
        "allowed_decisions": ["approve", "reject"],
        "description": f"准备执行分析工具 {name}",
    }
    for name in tool_names
}

hitl_middleware = HumanInTheLoopMiddleware(
    interrupt_on=interrupt_on_config,
    description_prefix="⚠️ [HITL 拦截]",
)

# ── 构建 Agent：checkpointer 持久化历史，SummarizationMiddleware 自动摘要 ──
checkpointer = InMemorySaver()

agent = create_agent(
    model=model,
    tools=tools,
    system_prompt=SYSTEM_PROMPT,
    checkpointer=checkpointer,
    middleware=[
        summarization_middleware,
        ToolCallLimitMiddleware(
            run_limit=2,
            exit_behavior="continue",
        ),
        hitl_middleware,
    ],
)


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                        对话循环 & 会话管理                                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

session_counter = 1


def run_conversation(thread_id: str | None = None):
    """启动交互式对话循环。

    每个 thread_id 对应一条独立的对话线，历史互不干扰。
    支持内置命令：quit 退出 / new 新建会话 / history 查看历史。
    """
    global session_counter

    if thread_id is None:
        thread_id = str(session_counter)
        session_counter += 1

    config = {"configurable": {"thread_id": thread_id}}

    print("=" * 50)
    print(f"  scRNA Agent  会话: {thread_id}")
    print("  输入 'quit' 退出 | 'new' 新建会话 | 'history' 查看历史")
    print("=" * 50)

    while True:
        try:
            user_input = input("\n> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n  会话结束")
            break

        if not user_input:
            continue

        # 内置命令处理
        if user_input.lower() == "quit":
            print("  会话结束")
            break
        elif user_input.lower() == "new":
            run_conversation()
            return
        elif user_input.lower() == "history":
            show_history(config)
            continue

        # 正常对话：调用 Agent，提取最后一条 AI 回复
        try:
            result = agent.invoke(
                {"messages": [{"role": "user", "content": user_input}]},
                config=config,
            )

            # --- HITL 中断循环 ---
            while result.get("__interrupt__"):
                interrupts = result.get("__interrupt__", [])
                action_requests = interrupts[0].value["action_requests"]

                decisions_payload = {"decisions": []}

                for req in action_requests:
                    tool_name = req["name"]
                    tool_args = req["args"]

                    print(f"\n{req.get('description', '')}")
                    print(f"  工具名称: {tool_name}")
                    print(f"  预设参数: {json.dumps(tool_args, indent=2, ensure_ascii=False)}")

                    while True:
                        choice = input("  请确认是否调用该工具 (y: 允许 / n: 拒绝): ").strip().lower()
                        if choice == "y":
                            decisions_payload["decisions"].append({"type": "approve"})
                            break
                        elif choice == "n":
                            decisions_payload["decisions"].append({"type": "reject"})
                            print("  已拒绝该工具调用。您可以直接在下一次对话中告诉 Agent 需要修改哪些参数。")
                            break
                        else:
                            print("  无效输入，仅支持 y, n。")

                print("\n  提交决策，恢复 Agent 执行...")
                result = agent.invoke(
                    Command(resume=decisions_payload),
                    config=config,
                )
            # --- 中断循环结束 ---

            reply = result["messages"][-1].content
            print(f"\n{reply}")
        except Exception as e:
            print(f"\n  错误: {e}")


def show_history(config: dict):
    """打印当前会话的消息历史。

    每条消息显示角色前缀和截断内容（最多 120 字符）。
    """
    state = agent.get_state(config)
    if state is None or not state.values:
        print("  (暂无历史)")
        return

    messages = state.values.get("messages", [])
    if not messages:
        print("  (暂无历史)")
        return

    print(f"\n  ── 会话历史 ({len(messages)} 条消息) ──")

    for i, msg in enumerate(messages):
        role = getattr(msg, "type", "unknown")
        content = getattr(msg, "content", str(msg))

        if role == "human":
            prefix = "User"
        elif role == "ai":
            prefix = "Agent"
        elif role == "tool":
            prefix = "Tool"
        else:
            prefix = role

        display = content[:120] + "..." if len(content) > 120 else content
        print(f"  [{i+1}] {prefix}: {display}")

    print(f"  ── 摘要阈值: {os.getenv('MAX_HISTORY_TOKENS', '1000')} tokens ──")


if __name__ == "__main__":
    run_conversation()
