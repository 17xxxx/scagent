#!/usr/bin/env python3
"""
scagent —— scAgent 本地瘦客户端
================================
设计约束：**只依赖 Python 标准库**（3.8+）。
因此在任何一台机器上，只要有 python3（甚至只有 curl）就能给远端的 agent 下指令，
不需要安装 Docker、R、也不需要对 langchain 一无所知的依赖。

配置（优先级：环境变量 > 配置文件）：
  SCAGENT_SERVER       服务地址，如 https://scagent.example.com
  SCAGENT_TOKEN        访问令牌
  SCAGENT_TOKEN_FILE   令牌文件路径（Docker secrets 约定，优先于 SCAGENT_TOKEN）
  配置文件          ~/.scagent/config.json

用法：
  scagent login --server https://... --token xxx
  scagent ask "帮我做质控"
  scagent ask --stream "做 PCA 和 UMAP"
  scagent status
  scagent approvals                 # 列出待批准的操作
  scagent approve ap_xxxxxxxx
  scagent reject  ap_xxxxxxxx
  scagent sessions
  scagent health
  scagent tools
"""
from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import time
import urllib.error
import urllib.request
import uuid

CONFIG_DIR = os.path.join(os.path.expanduser("~"), ".scagent")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
DEFAULT_TIMEOUT = 3600          # 分析可能跑几十分钟


# ═══════════════════════════════════════════════════════════════════════════════
# 配置
# ═══════════════════════════════════════════════════════════════════════════════

def _read_secret_file(path: str | None) -> str:
    """读取 *_FILE 指向的密钥文件（Docker secrets 约定）。仅用标准库。"""
    if not path or not path.strip():
        return ""
    try:
        with open(path.strip(), "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError as exc:
        sys.exit(f"❌ 读取 SCAGENT_TOKEN_FILE={path} 失败: {exc}")


def load_config() -> dict:
    cfg = {}
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as fh:
                cfg = json.load(fh)
        except (OSError, json.JSONDecodeError):
            cfg = {}
    cfg["server"] = (os.getenv("SCAGENT_SERVER") or cfg.get("server") or "").rstrip("/")
    cfg["token"] = (os.getenv("SCAGENT_TOKEN")
                    or _read_secret_file(os.getenv("SCAGENT_TOKEN_FILE"))
                    or cfg.get("token") or "")
    cfg.setdefault("session_id", "")
    if not cfg["server"] or not cfg["token"]:
        sys.exit("❌ 未配置服务地址或令牌。\n"
                 "   请先运行: scagent login --server <URL> --token <TOKEN>\n"
                 "   或设置环境变量 SCAGENT_SERVER / SCAGENT_TOKEN")
    return cfg


def save_config(cfg: dict) -> None:
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(CONFIG_FILE, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2, ensure_ascii=False)
    try:
        os.chmod(CONFIG_FILE, stat.S_IRUSR | stat.S_IWUSR)   # 600
    except OSError:
        pass


def update_config(**kwargs) -> None:
    cfg = {}
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as fh:
                cfg = json.load(fh)
        except (OSError, json.JSONDecodeError):
            cfg = {}
    cfg.update(kwargs)
    save_config(cfg)


# ═══════════════════════════════════════════════════════════════════════════════
# HTTP
# ═══════════════════════════════════════════════════════════════════════════════

def _request(cfg: dict, path: str, payload: dict | None = None,
             method: str = "POST", timeout: int = DEFAULT_TIMEOUT):
    url = cfg["server"] + path
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"Authorization": "Bearer " + cfg["token"],
                 "Content-Type": "application/json",
                 "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", "replace")
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        try:
            detail = json.loads(detail).get("detail", detail)
        except json.JSONDecodeError:
            pass
        if exc.code == 401:
            sys.exit(f"❌ 访问令牌无效（401）。请重新运行 scagent login。")
        sys.exit(f"❌ HTTP {exc.code}: {detail}")
    except urllib.error.URLError as exc:
        sys.exit(f"❌ 无法连接 {url}\n   {exc.reason}")


def _stream(cfg: dict, path: str, payload: dict) -> None:
    """读取服务端的 SSE 流，把进度实时打印出来。"""
    url = cfg["server"] + path
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode("utf-8"), method="POST",
        headers={"Authorization": "Bearer " + cfg["token"],
                 "Content-Type": "application/json",
                 "Accept": "text/event-stream"},
    )
    try:
        with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT) as resp:
            event = None
            for raw in resp:
                line = raw.decode("utf-8", "replace").rstrip("\n")
                if line.startswith("event:"):
                    event = line[6:].strip()
                elif line.startswith("data:"):
                    data = line[5:].strip()
                    _handle_event(event, data)
                elif line == "":
                    event = None
    except urllib.error.HTTPError as exc:
        sys.exit(f"❌ HTTP {exc.code}: {exc.read().decode('utf-8', 'replace')}")
    except urllib.error.URLError as exc:
        sys.exit(f"❌ 无法连接 {url}\n   {exc.reason}")


def _handle_event(event: str, data: str) -> None:
    try:
        obj = json.loads(data) if data else {}
    except json.JSONDecodeError:
        obj = {"raw": data}

    if event == "start":
        print(f"▶ 已提交（会话 {obj.get('session_id')}）…", flush=True)
    elif event == "heartbeat":
        print("  … 分析进行中", flush=True)
    elif event == "message":
        print()
        print(obj.get("reply") or "（无文本回复）")
    elif event == "approval":
        _render_approval(obj)
    elif event == "error":
        print(f"❌ {obj.get('message')}", file=sys.stderr)
    elif event == "done":
        print(f"\n✔ 状态: {obj.get('status')}")


# ═══════════════════════════════════════════════════════════════════════════════
# 交互辅助
# ═══════════════════════════════════════════════════════════════════════════════

def _render_approval(obj: dict) -> None:
    reqs = obj.get("action_requests") or []
    print("\n" + "=" * 62)
    print("  ⚠️  需要你确认")
    print("=" * 62)
    for r in reqs:
        print(f"  工具: {r.get('name')}")
        print(f"  参数: {json.dumps(r.get('args', {}), indent=4, ensure_ascii=False)}")
    print(f"\n  批准: scagent approve {obj.get('approval_id')}")
    print(f"  拒绝: scagent reject  {obj.get('approval_id')}")
    print("=" * 62)


def _print_table(rows: list[dict], cols: list[str]) -> None:
    if not rows:
        print("  (无)")
        return
    widths = {c: max(len(c), *(len(str(r.get(c, ""))) for r in rows)) for c in cols}
    print("  " + "  ".join(c.ljust(widths[c]) for c in cols))
    print("  " + "  ".join("-" * widths[c] for c in cols))
    for r in rows:
        print("  " + "  ".join(str(r.get(c, "")).ljust(widths[c]) for c in cols))


def _session_id(args, cfg: dict) -> str:
    sid = getattr(args, "session", None) or cfg.get("session_id")
    if not sid:
        sid = "cli_" + uuid.uuid4().hex[:8]
        update_config(session_id=sid)
        print(f"[会话] 新建 {sid}")
    return sid


# ═══════════════════════════════════════════════════════════════════════════════
# 命令
# ═══════════════════════════════════════════════════════════════════════════════

def cmd_login(args) -> int:
    cfg = {"server": args.server.rstrip("/"), "token": args.token}
    if args.session:
        cfg["session_id"] = args.session
    save_config(cfg)
    print(f"✅ 已保存到 {CONFIG_FILE}（权限 600）")
    print(f"   服务地址: {cfg['server']}")
    # 顺手验证连通性
    try:
        h = _request(cfg, "/v1/health", method="GET", timeout=15)
        print(f"   连通性: ✅  模型={h.get('llm', {}).get('model')}  "
              f"HITL={h.get('hitl_mode')}")
    except SystemExit:
        print("   连通性: ⚠️  登录信息已保存，但健康检查未通过（请检查地址与网络）")
    return 0


def cmd_ask(args) -> int:
    cfg = load_config()
    sid = _session_id(args, cfg)
    payload = {"message": args.message, "session_id": sid}
    if args.project:
        payload["project"] = args.project

    if args.stream:
        payload["stream"] = True
        _stream(cfg, "/v1/chat", payload)
        return 0

    print(f"[会话 {sid}] 已发送，分析可能需要数分钟…", flush=True)
    r = _request(cfg, "/v1/chat", payload)
    if r.get("status") == "pending_approval":
        _render_approval(r)
    else:
        print()
        print(r.get("reply") or "（无文本回复）")
    return 0


def cmd_approvals(args) -> int:
    """列出待批准请求（通过健康接口的计数 + 本地提示）。"""
    cfg = load_config()
    h = _request(cfg, "/v1/health", method="GET", timeout=15)
    print(f"待批准请求数: {h.get('pending_approvals', 0)}")
    print("提示：批准请使用 scagent approve <approval_id>（id 在 ask 的输出里）")
    return 0


def _decide(args, decision: str) -> int:
    cfg = load_config()
    payload = {"approval_id": args.approval_id, "decision": decision}
    if cfg.get("session_id"):
        payload["session_id"] = cfg["session_id"]
    if getattr(args, "note", None):
        payload["note"] = args.note
    print(f"已提交: {decision} → {args.approval_id}")
    r = _request(cfg, "/v1/approval", payload)
    if r.get("status") == "pending_approval":
        _render_approval(r)
    else:
        print()
        print(r.get("reply") or "（无文本回复）")
    return 0


def cmd_approve(args) -> int:
    return _decide(args, "approve")


def cmd_reject(args) -> int:
    return _decide(args, "reject")


def cmd_status(args) -> int:
    """流水线进度：通过让 agent 调用 check_pipeline_status 实现。"""
    cfg = load_config()
    sid = _session_id(args, cfg)
    payload = {"message": "请调用 check_pipeline_status 告诉我当前流水线进度，"
                          "不要执行任何分析工具。",
               "session_id": sid}
    r = _request(cfg, "/v1/chat", payload)
    if r.get("status") == "pending_approval":
        _render_approval(r)
    else:
        print(r.get("reply") or "（无文本回复）")
    return 0


def cmd_sessions(args) -> int:
    cfg = load_config()
    r = _request(cfg, "/v1/sessions", method="GET", timeout=30)
    rows = r.get("sessions", [])
    current = cfg.get("session_id", "")
    for row in rows:
        row["current"] = "← 当前" if row.get("session_id") == current else ""
    _print_table(rows, ["session_id", "project", "last_status", "run_count",
                        "updated_at", "current"])
    return 0


def cmd_use(args) -> int:
    update_config(session_id=args.session_id)
    print(f"✅ 当前会话已切换为 {args.session_id}")
    return 0


def cmd_new(args) -> int:
    sid = "cli_" + uuid.uuid4().hex[:8]
    update_config(session_id=sid)
    print(f"✅ 已新建会话 {sid}")
    return 0


def cmd_health(args) -> int:
    cfg = load_config()
    h = _request(cfg, "/v1/health", method="GET", timeout=20)
    print(json.dumps(h, indent=2, ensure_ascii=False))
    return 0


def cmd_tools(args) -> int:
    cfg = load_config()
    r = _request(cfg, "/v1/tools", method="GET", timeout=30)
    for t in r.get("tools", []):
        print(f"\n{t['name']}\n  {t['description']}")
        for p in t.get("params", []):
            print(f"    - {p['name']:<20} {p['type']:<12} 默认={p['default']}")
    return 0


# ═══════════════════════════════════════════════════════════════════════════════
# 入口
# ═══════════════════════════════════════════════════════════════════════════════

def main() -> int:
    ap = argparse.ArgumentParser(
        prog="scagent",
        description="scAgent 瘦客户端 —— 向远端服务下达自然语言分析指令",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例:\n"
               "  scagent ask \"帮我做质控\"\n"
               "  scagent ask --stream \"做 PCA 和 UMAP\"\n"
               "  scagent status\n")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("login", help="配置服务地址与令牌")
    p.add_argument("--server", required=True)
    p.add_argument("--token", required=True)
    p.add_argument("--session", default="")
    p.set_defaults(func=cmd_login)

    p = sub.add_parser("ask", help="发送自然语言指令")
    p.add_argument("message")
    p.add_argument("--project", default=None)
    p.add_argument("--session", default=None)
    p.add_argument("--stream", action="store_true", help="实时显示进度（SSE）")
    p.set_defaults(func=cmd_ask)

    sub.add_parser("status", help="查询流水线进度").set_defaults(
        func=cmd_status, session=None)
    sub.add_parser("approvals", help="查看待批准数量").set_defaults(func=cmd_approvals)

    p = sub.add_parser("approve", help="批准一个待执行的操作")
    p.add_argument("approval_id")
    p.add_argument("--note", default=None)
    p.set_defaults(func=cmd_approve)

    p = sub.add_parser("reject", help="拒绝一个待执行的操作")
    p.add_argument("approval_id")
    p.add_argument("--note", default=None)
    p.set_defaults(func=cmd_reject)

    sub.add_parser("sessions", help="列出会话").set_defaults(func=cmd_sessions)

    p = sub.add_parser("use", help="切换当前会话")
    p.add_argument("session_id")
    p.set_defaults(func=cmd_use)

    sub.add_parser("new", help="新建会话").set_defaults(func=cmd_new)
    sub.add_parser("health", help="服务健康检查").set_defaults(func=cmd_health)
    sub.add_parser("tools", help="列出服务端工具").set_defaults(func=cmd_tools)

    args = ap.parse_args()
    if args.cmd == "status" and getattr(args, "session", None) is None:
        args.session = None
    return args.func(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n已取消")
        raise SystemExit(130)
