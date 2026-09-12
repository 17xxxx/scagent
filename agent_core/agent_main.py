"""
agent_main.py —— scAgent 本地交互式命令行（开发 / 调试用）
============================================================
生产环境请使用：
  · server.py         —— HTTP 服务（供远端瘦客户端 / 网页调用）
  · pipeline_cli.py   —— 确定性流水线（无需 LLM、无需联网）

Agent 的构建逻辑集中在 agent_factory.py，本文件只负责交互循环。

内置命令：
  quit      退出
  new       新建会话
  history   查看当前会话历史
  help      显示帮助
"""
from __future__ import annotations

import json
import sys
from typing import List, Optional

from dotenv import load_dotenv

# 加载 .env（优先级：系统环境变量 > .env）
load_dotenv()

from agent_factory import build_agent, tool_names          # noqa: E402
from config import load_settings                            # noqa: E402
from langgraph.types import Command                         # noqa: E402

SETTINGS = load_settings()
session_counter = 1


def print_banner(thread_id: str) -> None:
    print("=" * 62)
    print(f"  scAgent 单细胞分析 · 会话 {thread_id}")
    print(f"  模型: {SETTINGS.llm_model}   工具: {len(tool_names())} 个")
    print("  输入 'quit' 退出 | 'new' 新建会话 | 'history' 查看历史")
    print("=" * 62)


def handle_interrupts(result: dict, config: dict, agent) -> dict:
    """HITL 中断循环：把中断交给用户决定，然后恢复执行。"""
    while result.get("__interrupt__"):
        action_requests = result["__interrupt__"][0].value["action_requests"]
        decisions: List[dict] = []

        for req in action_requests:
            print(f"\n{req.get('description', '')}")
            print(f"  工具名称: {req['name']}")
            print(f"  预设参数: {json.dumps(req['args'], indent=2, ensure_ascii=False)}")
            while True:
                choice = input("  请确认是否调用该工具 (y: 允许 / n: 拒绝): ").strip().lower()
                if choice == "y":
                    decisions.append({"type": "approve"})
                    break
                if choice == "n":
                    decisions.append({"type": "reject"})
                    print("  已拒绝。你可以直接在下一次对话中告诉 Agent 要改哪些参数。")
                    break
                print("  无效输入，仅支持 y / n。")

        print("\n  提交决策，恢复 Agent 执行…")
        result = agent.invoke(Command(resume={"decisions": decisions}), config=config)
    return result


def conversation(thread_id: Optional[str] = None) -> None:
    """交互式对话循环。每个 thread_id 是一条独立会话线。"""
    global session_counter

    agent, info = build_agent(SETTINGS)
    print(f"[agent] checkpointer={info['checkpointer']}  "
          f"provider={info['llm_provider']}  tools={info['tool_count']}")

    if thread_id is None:
        thread_id = str(session_counter)
        session_counter += 1
    config = {"configurable": {"thread_id": thread_id}}
    print_banner(thread_id)

    while True:
        try:
            user_input = input("\n> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n  会话结束")
            break

        if not user_input:
            continue

        cmd = user_input.lower()
        if cmd in {"quit", "exit"}:
            print("  会话结束")
            break
        if cmd == "new":
            conversation()
            return
        if cmd == "history":
            show_history(agent, config)
            continue
        if cmd == "help":
            print("  quit 退出 | new 新建会话 | history 查看历史\n"
                  "  直接输入自然语言即可，例如：帮我做质控")
            continue

        try:
            result = agent.invoke(
                {"messages": [{"role": "user", "content": user_input}]},
                config=config,
            )
            result = handle_interrupts(result, config, agent)
            reply = result["messages"][-1].content
            print(f"\n{reply}")
        except Exception as exc:                          # noqa: BLE001
            print(f"\n  错误: {exc}")


def show_history(agent, config: dict) -> None:
    """打印当前会话的消息历史（每条最多 120 字符）。"""
    state = agent.get_state(config)
    if state is None or not getattr(state, "values", None):
        print("  (暂无历史)")
        return
    messages = state.values.get("messages", [])
    if not messages:
        print("  (暂无历史)")
        return

    prefix_map = {"human": "User", "ai": "Agent", "tool": "Tool"}
    print(f"\n  ── 会话历史（{len(messages)} 条）──")
    for i, msg in enumerate(messages, 1):
        role = getattr(msg, "type", "unknown")
        content = getattr(msg, "content", str(msg))
        if isinstance(content, list):
            content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
        text = str(content)
        print(f"  [{i}] {prefix_map.get(role, role)}: "
              f"{text[:120] + '...' if len(text) > 120 else text}")


def main() -> None:
    ok, why = SETTINGS.llm_ready()
    if not ok:
        print(f"❌ {why}", file=sys.stderr)
        sys.exit(1)
    conversation()


if __name__ == "__main__":
    main()
