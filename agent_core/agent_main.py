"""
agent_main.py —— 带历史会话的 scRNA 分析 Agent
================================================================================
- 基于 LangGraph create_agent，内建 InMemorySaver 持久化对话历史
- 工具调用框架已就绪，当前工具列表为空，后续按需注入
- 使用 SummarizationMiddleware 自动摘要压缩历史消息，防止上下文溢出
- 主模型与压缩模型均使用 DeepSeek API（DEEPSEEK_API_KEY / DEEPSEEK_BASE_URL）
- 启动时自动从项目根目录 .env 文件加载环境变量
"""
import os
from typing import List

from dotenv import load_dotenv
from langchain.agents import create_agent
from langchain.agents.middleware import SummarizationMiddleware
from langchain_openai import ChatOpenAI
from langgraph.checkpoint.memory import InMemorySaver

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
        ("tokens", int(os.getenv("MAX_HISTORY_TOKENS", "1000"))),
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
from tools import run_qc_for_all_samples

tools: List = [run_qc_for_all_samples]

# ── 系统提示词 ──
SYSTEM_PROMPT = """\
你是一个单细胞 RNA 测序（scRNA-seq）数据分析助手。

你的职责：
1. 理解用户的生信分析需求
2. 在合适的时机调用工具执行分析任务（如质控、降维、聚类等）
3. 解读工具返回的结果，用通俗语言向用户解释

请保持回答简洁专业。如果用户的需求需要用到你尚未配备的工具，
请如实告知，并说明需要哪些工具支持。

注意：对话中可能出现摘要消息，这是之前对话的压缩记录，
请参考其中的关键信息来理解上下文。
"""

# ── 构建 Agent：checkpointer 持久化历史，SummarizationMiddleware 自动摘要 ──
checkpointer = InMemorySaver()

agent = create_agent(
    model=model,
    tools=tools,
    system_prompt=SYSTEM_PROMPT,
    checkpointer=checkpointer,
    middleware=[summarization_middleware],
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
