"""
server.py —— scAgent HTTP 服务
================================
把原本只能本地交互式运行的 agent 改造成可远程调用的服务，
使"分析跑在服务器、本地只下指令"成为可能。

核心设计：
  1. HITL 状态机 —— 原实现阻塞在 input()，远程调用会永久挂起；
     这里改为返回 pending_approval + approval_id，客户端批准后再恢复执行。
  2. 会话持久化 —— SQLite checkpointer，服务重启不丢会话。
  3. 鉴权 —— Bearer Token（timing-safe 比较）。
  4. 并发控制 —— 每会话一把锁 + 全局信号量（R 端单个对象 1.6 GB，内存是硬约束）。
  5. 内置网页界面 —— 本地零安装，打开浏览器即可下指令。
  6. 结构化日志 —— JSON Lines 输出到 stdout，便于云端采集。

接口：
  GET    /                     内置网页界面
  GET    /v1/health            健康检查
  GET    /v1/tools             工具与参数清单
  GET    /v1/sessions          会话列表
  GET    /v1/sessions/{id}     会话详情
  DELETE /v1/sessions/{id}     删除会话
  POST   /v1/chat              发送指令（可 stream=true 走 SSE）
  POST   /v1/approval          批准/拒绝待执行的工具调用
"""
from __future__ import annotations

import asyncio
import hmac
import json
import os
import sqlite3
import sys
import time
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

import requests
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from langgraph.types import Command

from agent_factory import ALL_TOOLS, build_agent, tool_names
from config import Settings, load_settings

# ═══════════════════════════════════════════════════════════════════════════════
# 全局状态
# ═══════════════════════════════════════════════════════════════════════════════

SETTINGS: Settings = load_settings()
AGENT: Any = None
AGENT_INFO: Dict[str, Any] = {}
SESSION_LOCKS: Dict[str, asyncio.Lock] = {}
RUN_SEMAPHORE: Optional[asyncio.Semaphore] = None


def log(event: str, **fields: Any) -> None:
    """结构化日志：JSON Lines 到 stdout（便于云端采集）。"""
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "event": event}
    rec.update({k: v for k, v in fields.items() if v is not None})
    print(json.dumps(rec, ensure_ascii=False), flush=True)


# ═══════════════════════════════════════════════════════════════════════════════
# 会话元数据（SQLite）—— 检查点由 LangGraph 管，这里只存展示用的元信息
# ═══════════════════════════════════════════════════════════════════════════════

def _session_db_path() -> str:
    return os.path.join(SETTINGS.state_dir, "sessions.sqlite")


def _init_session_db() -> None:
    os.makedirs(SETTINGS.state_dir, exist_ok=True)
    with sqlite3.connect(_session_db_path()) as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS sessions (
                session_id  TEXT PRIMARY KEY,
                tenant      TEXT,
                project     TEXT,
                created_at  TEXT,
                updated_at  TEXT,
                last_status TEXT,
                run_count   INTEGER DEFAULT 0
            )
        """)
        conn.commit()


def _touch_session(session_id: str, tenant: Optional[str], project: Optional[str],
                   status: str) -> None:
    now = time.strftime("%Y-%m-%dT%H:%M:%S")
    with sqlite3.connect(_session_db_path()) as conn:
        conn.execute("""
            INSERT INTO sessions (session_id, tenant, project, created_at, updated_at,
                                  last_status, run_count)
            VALUES (?, ?, ?, ?, ?, ?, 1)
            ON CONFLICT(session_id) DO UPDATE SET
                updated_at  = excluded.updated_at,
                last_status = excluded.last_status,
                run_count   = sessions.run_count + 1,
                tenant      = COALESCE(excluded.tenant, sessions.tenant),
                project     = COALESCE(excluded.project, sessions.project)
        """, (session_id, tenant, project, now, now, status))
        conn.commit()


def _list_sessions(limit: int = 100) -> List[Dict[str, Any]]:
    with sqlite3.connect(_session_db_path()) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT * FROM sessions ORDER BY updated_at DESC LIMIT ?", (limit,)
        ).fetchall()
    return [dict(r) for r in rows]


def _delete_session_row(session_id: str) -> None:
    with sqlite3.connect(_session_db_path()) as conn:
        conn.execute("DELETE FROM sessions WHERE session_id = ?", (session_id,))
        conn.commit()


# ═══════════════════════════════════════════════════════════════════════════════
# 待批准请求（HITL 状态机）
# ═══════════════════════════════════════════════════════════════════════════════

APPROVAL_TTL_SECONDS = 3600


@dataclass
class PendingApproval:
    approval_id: str
    session_id: str
    created_at: float
    action_requests: List[Dict[str, Any]]
    tenant: Optional[str] = None
    project: Optional[str] = None


PENDING: Dict[str, PendingApproval] = {}


def _gc_pending() -> None:
    now = time.time()
    for k in [k for k, v in PENDING.items() if now - v.created_at > APPROVAL_TTL_SECONDS]:
        PENDING.pop(k, None)


def _register_pending(session_id: str, interrupts: Any,
                      tenant: Optional[str], project: Optional[str]) -> PendingApproval:
    _gc_pending()
    action_requests: List[Dict[str, Any]] = []
    try:
        for irq in interrupts or []:
            value = getattr(irq, "value", None) or {}
            action_requests.extend(value.get("action_requests", []))
    except Exception:                                   # noqa: BLE001
        action_requests = []

    pa = PendingApproval(
        approval_id="ap_" + uuid.uuid4().hex[:12],
        session_id=session_id,
        created_at=time.time(),
        action_requests=action_requests,
        tenant=tenant,
        project=project,
    )
    PENDING[pa.approval_id] = pa
    return pa


def _pending_from_checkpoint(session_id: str,
                             tenant: Optional[str] = None,
                             project: Optional[str] = None) -> Optional[PendingApproval]:
    """从 checkpoint 重建"待批准"信息（进程重启后 PENDING 必为空，但 interrupt 还在）。

    用途：会话历史存在 SQLite checkpointer 里、进程重启不丢，而 PENDING 是进程内字典、
    重启即空。此时历史里会留下"调用了工具却没有结果"的记录，直接把新消息交给模型会被
    拒绝（tool_calls 缺少对应的 tool 消息 → 400 → 对外表现为 500）。
    这里用 get_state() 把待批准的动作取回来，让用户仍能批准 / 拒绝。
    """
    try:
        snap = AGENT.get_state({"configurable": {"thread_id": session_id}})
    except Exception:                                   # noqa: BLE001
        return None
    for task in (getattr(snap, "tasks", None) or []):
        for irq in (getattr(task, "interrupts", None) or []):
            value = getattr(irq, "value", None)
            if isinstance(value, dict) and value.get("action_requests"):
                pa = PendingApproval(
                    approval_id="ap_" + uuid.uuid4().hex[:12],
                    session_id=session_id,
                    created_at=time.time(),
                    action_requests=list(value["action_requests"]),
                    tenant=tenant,
                    project=project,
                )
                PENDING[pa.approval_id] = pa
                return pa
    return None


# ═══════════════════════════════════════════════════════════════════════════════
# Agent 运行
# ═══════════════════════════════════════════════════════════════════════════════

def _extract_reply(result: Dict[str, Any]) -> Optional[str]:
    """从 agent 结果里取出最后一条 AI 文本。"""
    messages = result.get("messages") or []
    for msg in reversed(messages):
        content = getattr(msg, "content", None)
        if content and getattr(msg, "type", "") in {"ai", "assistant"}:
            if isinstance(content, list):
                parts = [p.get("text", "") for p in content if isinstance(p, dict)]
                content = "".join(parts)
            if str(content).strip():
                return str(content)
    return None


def _run_agent_sync(session_id: str, payload: Any, tenant: Optional[str],
                    project: Optional[str]) -> Dict[str, Any]:
    """在工作线程里同步执行 agent（LangGraph 的 invoke 是阻塞的）。"""
    config = {"configurable": {"thread_id": session_id}}
    result = AGENT.invoke(payload, config=config)

    interrupts = result.get("__interrupt__")
    if interrupts:
        pa = _register_pending(session_id, interrupts, tenant, project)
        _touch_session(session_id, tenant, project, "pending_approval")
        return {
            "status": "pending_approval",
            "session_id": session_id,
            "approval_id": pa.approval_id,
            "action_requests": pa.action_requests,
            "reply": None,
        }

    reply = _extract_reply(result)
    _touch_session(session_id, tenant, project, "completed")
    return {
        "status": "completed",
        "session_id": session_id,
        "approval_id": None,
        "action_requests": [],
        "reply": reply,
    }


async def _execute(session_id: str, payload: Any, tenant: Optional[str],
                   project: Optional[str]) -> Dict[str, Any]:
    """串行执行：每会话一把锁 + 全局并发上限。"""
    lock = SESSION_LOCKS.setdefault(session_id, asyncio.Lock())
    async with lock:
        async with RUN_SEMAPHORE:                        # type: ignore[arg-type]
            return await asyncio.to_thread(
                _run_agent_sync, session_id, payload, tenant, project
            )


def _apply_hitl_policy(payload: Dict[str, Any]) -> Dict[str, Any]:
    """auto_approve / deny_all 策略：不需要人工介入时自动决定。"""
    if SETTINGS.hitl_mode == "auto_approve":
        return {"decisions": [{"type": "approve"}] * max(1, len(
            payload.get("action_requests") or []))}
    return {"decisions": [{"type": "reject"}] * max(1, len(
        payload.get("action_requests") or []))}


# ═══════════════════════════════════════════════════════════════════════════════
# 鉴权
# ═══════════════════════════════════════════════════════════════════════════════

_bearer = HTTPBearer(auto_error=False)


async def require_token(
    creds: Optional[HTTPAuthorizationCredentials] = Depends(_bearer),
) -> None:
    if not SETTINGS.token:
        raise HTTPException(status_code=503,
                            detail="服务端未配置 SCAGENT_TOKEN，拒绝提供服务")
    if creds is None or not hmac.compare_digest(creds.credentials, SETTINGS.token):
        log("auth_failed")
        raise HTTPException(status_code=401, detail="访问令牌无效")


# ═══════════════════════════════════════════════════════════════════════════════
# 应用生命周期
# ═══════════════════════════════════════════════════════════════════════════════

@asynccontextmanager
async def lifespan(app: FastAPI):
    global AGENT, AGENT_INFO, RUN_SEMAPHORE

    if SETTINGS.config_error:
        log("startup_error", reason=SETTINGS.config_error)
        print(f"❌ 密钥配置错误：{SETTINGS.config_error}", file=sys.stderr)
        raise SystemExit(2)

    if not SETTINGS.token:
        # 区分"没配"与"配了但读不到"（文件缺失 / 为空 / 无权限），后者的原因是
        # SCAGENT_TOKEN_FILE 本身，直接报出来比笼统地说"未设置"更可诊断
        if SETTINGS.token_error:
            log("startup_error", reason=SETTINGS.token_error)
            print(f"❌ 访问令牌读取失败：{SETTINGS.token_error}\n"
                  "   检查：SCAGENT_TOKEN_FILE 指向的文件是否存在、非空、容器的运行用户可以读；\n"
                  "   自检： ./scripts/check_secrets.sh --prod",
                  file=sys.stderr)
        else:
            log("startup_error", reason="SCAGENT_TOKEN 未设置")
            print("❌ 未设置 SCAGENT_TOKEN —— 服务拒绝启动。\n"
                  "   生成方式： cp deploy/.env.sample deploy/.env && chmod 600 deploy/.env\n"
                  "             把 SCAGENT_TOKEN 填成 $(openssl rand -hex 24)\n"
                  "   生产环境建议用 Docker secrets： SCAGENT_TOKEN_FILE=/run/secrets/scagent_token",
                  file=sys.stderr)
        raise SystemExit(2)

    ok, why = SETTINGS.llm_ready()
    if not ok:
        log("startup_error", reason=why)
        print(f"❌ LLM 配置不可用: {why}\n"
              f"   若只想跑确定性分析流程，请使用 pipeline_cli.py。", file=sys.stderr)
        raise SystemExit(3)

    _init_session_db()
    RUN_SEMAPHORE = asyncio.Semaphore(SETTINGS.max_concurrent_runs)

    AGENT, AGENT_INFO = build_agent(SETTINGS)
    # 注意：hitl_mode 已在 AGENT_INFO 里，不能再显式传一次
    # （否则 TypeError: got multiple values for keyword argument）
    log("startup", **AGENT_INFO, data_dir=SETTINGS.data_dir,
        tools=tool_names())
    yield
    log("shutdown")


app = FastAPI(title="scAgent", version="1.0.0", lifespan=lifespan)


# ═══════════════════════════════════════════════════════════════════════════════
# 内置网页界面
# ═══════════════════════════════════════════════════════════════════════════════

WEB_UI = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>scAgent · 单细胞分析</title>
<style>
 body{font-family:system-ui,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;
      max-width:860px;margin:0 auto;padding:16px;background:#f6f7f9;color:#1a1a1a}
 h1{font-size:20px;margin:8px 0 4px}
 .sub{color:#666;font-size:13px;margin-bottom:16px}
 #log{background:#fff;border:1px solid #e3e6ea;border-radius:10px;padding:14px;
      height:56vh;overflow-y:auto;white-space:pre-wrap;line-height:1.55;font-size:14px}
 .me{color:#0a58ca;margin:10px 0 4px;font-weight:600}
 .ai{color:#111;margin:4px 0 12px}
 .sys{color:#888;font-size:12px;margin:4px 0}
 .appr{background:#fff8e1;border:1px solid #f0d48a;border-radius:8px;padding:10px;margin:8px 0}
 .appr pre{white-space:pre-wrap;font-size:12px;margin:6px 0}
 button{cursor:pointer;border-radius:8px;border:1px solid #c9ced6;background:#fff;
        padding:7px 14px;font-size:14px}
 button.primary{background:#0d6efd;border-color:#0d6efd;color:#fff}
 button.danger{background:#dc3545;border-color:#dc3545;color:#fff}
 #row{display:flex;gap:8px;margin-top:12px}
 #msg{flex:1;padding:11px;border:1px solid #c9ced6;border-radius:8px;font-size:14px}
 .tok{font-size:12px;color:#888;margin-top:8px}
</style></head><body>
<h1>scAgent · 单细胞分析</h1>
<div class="sub">直接用自然语言下达分析指令，例如"帮我做质控"</div>
<div id="log"></div>
<div id="row">
  <input id="msg" placeholder="例如：帮我做质控 / 做 PCA 和 UMAP / 聚类" autofocus>
  <button class="primary" onclick="send()">发送</button>
</div>
<div class="tok">访问令牌保存在本机浏览器，不会上传到别处。
  <a href="#" onclick="setToken();return false">重新设置</a> ·
  <a href="#" onclick="newSession();return false">新建会话</a>（服务重启后若提示"待批准"，可用它重新开始）</div>
<script>
const $ = s => document.querySelector(s);
let SESSION = localStorage.getItem('scagent_session');
if(!SESSION){ SESSION = 'web_' + Math.random().toString(36).slice(2,10);
              localStorage.setItem('scagent_session', SESSION); }
function newSession(){
  SESSION = 'web_' + Math.random().toString(36).slice(2,10);
  localStorage.setItem('scagent_session', SESSION);
  document.querySelector('#log').innerHTML = '';
  say('sys', '已新建会话：' + SESSION);
}
function token(){ return localStorage.getItem('scagent_token') || ''; }
function setToken(){ const t = prompt('请输入访问令牌（SCAGENT_TOKEN）', token());
                     if(t!==null){ localStorage.setItem('scagent_token', t.trim()); } }
function say(cls, text){ const d=document.createElement('div'); d.className=cls;
                         d.textContent=text; $('#log').appendChild(d);
                         $('#log').scrollTop=$('#log').scrollHeight; }
async function api(path, body){
  const r = await fetch(path, {method:'POST',
    headers:{'Content-Type':'application/json','Authorization':'Bearer '+token()},
    body: JSON.stringify(body)});
  if(r.status===401){ setToken(); throw new Error('访问令牌无效，请重新设置'); }
  if(!r.ok){
    let t = await r.text();
    try{ const j = JSON.parse(t); if(j && j.detail) t = j.detail; }catch(e){}
    throw new Error(t);
  }
  return r.json();
}
function renderApproval(d){
  const box=document.createElement('div'); box.className='appr';
  const names=(d.action_requests||[]).map(a=>a.name).join(', ');
  box.innerHTML='<b>⚠️ 需要你确认</b><div>即将执行：'+names+'</div>'+
    '<pre>'+JSON.stringify(d.action_requests,null,2)+'</pre>';
  const ok=document.createElement('button'); ok.className='primary'; ok.textContent='允许';
  const no=document.createElement('button'); no.className='danger'; no.textContent='拒绝';
  no.style.marginLeft='8px';
  ok.onclick=()=>decide(d.approval_id,'approve',box);
  no.onclick=()=>decide(d.approval_id,'reject',box);
  box.appendChild(ok); box.appendChild(no); $('#log').appendChild(box);
  $('#log').scrollTop=$('#log').scrollHeight;
}
async function decide(id, decision, box){
  box.remove(); say('sys','已提交决定：'+decision+'，等待执行…');
  try{ const r = await api('/v1/approval',{approval_id:id, decision, session_id:SESSION});
       after(r); }catch(e){ say('sys','错误：'+e.message); }
}
function after(r){
  if(r.note) say('sys', r.note);
  if(r.status==='pending_approval'){ say('sys','等待你批准…'); renderApproval(r); }
  else if(r.reply){ say('ai', r.reply); }
  else { say('sys','完成（无文本回复）'); }
}
async function send(){
  const text=$('#msg').value.trim(); if(!text) return;
  if(!token()){ setToken(); if(!token()) return; }
  $('#msg').value=''; say('me', text); say('sys','已发送，分析可能需要数分钟…');
  try{ const r = await api('/v1/chat',{message:text, session_id:SESSION}); after(r); }
  catch(e){ say('sys','错误：'+e.message); }
}
$('#msg').addEventListener('keydown',e=>{ if(e.key==='Enter') send(); });
say('sys','就绪。会话 ID：'+SESSION);
</script></body></html>
"""


@app.get("/", response_class=HTMLResponse)
async def index() -> HTMLResponse:
    if not SETTINGS.enable_web_ui:
        raise HTTPException(status_code=404, detail="网页界面已禁用")
    return HTMLResponse(WEB_UI)


# ═══════════════════════════════════════════════════════════════════════════════
# 接口实现
# ═══════════════════════════════════════════════════════════════════════════════

def _seurat_health() -> Dict[str, Any]:
    base = os.getenv("SEURAT_API_BASE", "http://seurat:9000")
    try:
        r = requests.get(f"{base}/api/ping", timeout=5)
        return {"reachable": r.status_code == 200, "status_code": r.status_code}
    except Exception as exc:                             # noqa: BLE001
        return {"reachable": False, "error": str(exc)}


@app.get("/v1/health")
async def health(_: None = Depends(require_token)) -> Dict[str, Any]:
    ok, why = SETTINGS.llm_ready()
    return {
        "status": "ok",
        "llm": {"provider": SETTINGS.llm_provider, "model": SETTINGS.llm_model,
                "ready": ok, "reason": why},
        "seurat": _seurat_health(),
        "data_dir": SETTINGS.data_dir,
        "hitl_mode": SETTINGS.hitl_mode,
        "checkpointer": AGENT_INFO.get("checkpointer"),
        "pending_approvals": len(PENDING),
        "sessions": len(_list_sessions(1000)),
    }


@app.get("/v1/tools")
async def tools(_: None = Depends(require_token)) -> Dict[str, Any]:
    out = []
    for t in ALL_TOOLS:
        schema = getattr(t, "args_schema", None)
        fields = []
        if schema is not None:
            props = getattr(schema, "model_fields", {}) or {}
            for fname, f in props.items():
                fields.append({
                    "name": fname,
                    "type": str(getattr(f, "annotation", "any")),
                    "default": None if getattr(f, "default", None) is None
                               else str(getattr(f, "default")),
                    "description": getattr(f, "description", "") or "",
                })
        out.append({"name": t.name, "description": (t.description or "").split("\n")[0],
                    "params": fields})
    return {"count": len(out), "tools": out}


@app.get("/v1/sessions")
async def sessions(_: None = Depends(require_token)) -> Dict[str, Any]:
    return {"sessions": _list_sessions()}


@app.get("/v1/sessions/{session_id}")
async def session_detail(session_id: str, _: None = Depends(require_token)) -> Dict[str, Any]:
    rows = [s for s in _list_sessions(1000) if s["session_id"] == session_id]
    if not rows:
        raise HTTPException(status_code=404, detail=f"会话不存在: {session_id}")
    state = AGENT.get_state({"configurable": {"thread_id": session_id}})
    messages = []
    if state is not None and getattr(state, "values", None):
        for m in state.values.get("messages", []):
            content = getattr(m, "content", "")
            if isinstance(content, list):
                content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
            messages.append({"role": getattr(m, "type", "?"),
                             "content": str(content)[:2000]})
    return {"session": rows[0], "messages": messages}


@app.delete("/v1/sessions/{session_id}")
async def session_delete(session_id: str, _: None = Depends(require_token)) -> Dict[str, Any]:
    _delete_session_row(session_id)
    SESSION_LOCKS.pop(session_id, None)
    log("session_deleted", session_id=session_id)
    return {"status": "ok", "session_id": session_id}


def _parse_chat_body(body: Dict[str, Any]) -> Dict[str, Any]:
    message = (body.get("message") or "").strip()
    if not message:
        raise HTTPException(status_code=400, detail="message 不能为空")
    return {
        "message": message,
        "session_id": body.get("session_id") or ("s_" + uuid.uuid4().hex[:12]),
        "tenant": body.get("tenant"),
        "project": body.get("project"),
        "stream": bool(body.get("stream", False)),
    }


@app.post("/v1/chat")
async def chat(request: Request, _: None = Depends(require_token)):
    body = await request.json()
    p = _parse_chat_body(body)
    run_id = "run_" + uuid.uuid4().hex[:12]

    log("chat_start", run_id=run_id, session_id=p["session_id"],
        tenant=p["tenant"], message=p["message"][:200])
    payload = {"messages": [{"role": "user", "content": p["message"]}]}

    # 守卫：该会话若还挂着一个未回答的 interrupt（典型场景：服务重启过），
    # 就直接把待批准的动作交回给用户，**不要**把新消息塞进历史 —— 否则历史里
    # "tool_calls 没有对应结果"会被 LLM 拒绝（400，对外表现为 500），会话被写坏。
    pending = _pending_from_checkpoint(p["session_id"], p["tenant"], p["project"])
    if pending is not None:
        log("chat_blocked_by_pending", run_id=run_id, session_id=p["session_id"],
            approval_id=pending.approval_id,
            tools=[a.get("name") for a in pending.action_requests])
        return JSONResponse({
            "status": "pending_approval",
            "session_id": p["session_id"],
            "run_id": run_id,
            "approval_id": pending.approval_id,
            "action_requests": pending.action_requests,
            "reply": None,
            "note": ("该会话还有一个待批准的操作（通常是服务重启前留下的）："
                     "请先批准或拒绝；也可以点『新建会话』重新开始。"),
        })

    if not p["stream"]:
        result = await _execute(p["session_id"], payload, p["tenant"], p["project"])
        # auto_approve / deny_all：策略模式下自动继续，无需客户端介入
        while result["status"] == "pending_approval" and SETTINGS.hitl_mode != "interactive":
            decision = _apply_hitl_policy(result)
            PENDING.pop(result.get("approval_id") or "", None)
            result = await _execute(p["session_id"], Command(resume=decision),
                                    p["tenant"], p["project"])
        result["run_id"] = run_id
        log("chat_done", run_id=run_id, session_id=p["session_id"],
            status=result["status"])
        return JSONResponse(result)

    # ── SSE 流式 ──
    async def gen():
        yield f"event: start\ndata: {json.dumps({'run_id': run_id, 'session_id': p['session_id']}, ensure_ascii=False)}\n\n"
        task = asyncio.create_task(
            _execute(p["session_id"], payload, p["tenant"], p["project"]))
        while not task.done():
            done, _ = await asyncio.wait({task}, timeout=15)
            if not done:
                yield "event: heartbeat\ndata: {}\n\n"      # 防止反向代理超时
        try:
            result = task.result()
            result["run_id"] = run_id
            if result["status"] == "pending_approval":
                yield f"event: approval\ndata: {json.dumps(result, ensure_ascii=False)}\n\n"
            else:
                yield f"event: message\ndata: {json.dumps(result, ensure_ascii=False)}\n\n"
            yield f"event: done\ndata: {json.dumps({'status': result['status']}, ensure_ascii=False)}\n\n"
        except Exception as exc:                            # noqa: BLE001
            log("chat_error", run_id=run_id, error=str(exc))
            yield f"event: error\ndata: {json.dumps({'message': str(exc)}, ensure_ascii=False)}\n\n"

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache",
                                      "X-Accel-Buffering": "no"})


@app.post("/v1/approval")
async def approval(request: Request, _: None = Depends(require_token)) -> Dict[str, Any]:
    body = await request.json()
    approval_id = body.get("approval_id")
    decision = body.get("decision")
    session_id = body.get("session_id")
    note = body.get("note")

    if decision not in {"approve", "reject"}:
        raise HTTPException(status_code=400, detail="decision 必须是 approve 或 reject")

    pa = PENDING.get(approval_id or "")
    if pa is None and session_id:
        # 进程重启后 PENDING 会清空，但 checkpoint 里的 interrupt 还在 ——
        # 用会话 ID 重建，让用户仍能批准/拒绝（拒绝同时是修复被写坏会话的出口）。
        pa = _pending_from_checkpoint(session_id, tenant=None, project=None)
        if pa is not None:
            log("approval_recovered_from_checkpoint", session_id=session_id,
                approval_id=pa.approval_id,
                tools=[a.get("name") for a in pa.action_requests])
    if pa is None:
        raise HTTPException(status_code=404,
                            detail="批准请求不存在或已过期（默认 1 小时）")
    if session_id and session_id != pa.session_id:
        raise HTTPException(status_code=403, detail="不可批准其它会话的操作")

    PENDING.pop(approval_id, None)
    n = max(1, len(pa.action_requests))
    resume = {"decisions": [{"type": decision}] * n}

    log("approval", approval_id=approval_id, session_id=pa.session_id,
        decision=decision, note=note, tools=[a.get("name") for a in pa.action_requests])

    result = await _execute(pa.session_id, Command(resume=resume), pa.tenant, pa.project)
    while result["status"] == "pending_approval" and SETTINGS.hitl_mode != "interactive":
        d = _apply_hitl_policy(result)
        PENDING.pop(result.get("approval_id") or "", None)
        result = await _execute(pa.session_id, Command(resume=d), pa.tenant, pa.project)
    return JSONResponse(result)


# ═══════════════════════════════════════════════════════════════════════════════
# 入口
# ═══════════════════════════════════════════════════════════════════════════════

def main() -> None:
    import uvicorn

    print(f"""
╔══════════════════════════════════════════════════════════╗
║  scAgent HTTP 服务                                       ║
╠══════════════════════════════════════════════════════════╣
║  网页界面 : http://<服务器IP>:{SETTINGS.port}/{'':<24}║
║  API 文档 : http://<服务器IP>:{SETTINGS.port}/docs{'':<20}║
║  数据目录 : {SETTINGS.data_dir:<44}║
║  HITL 模式: {SETTINGS.hitl_mode:<44}║
╚══════════════════════════════════════════════════════════╝
""")
    uvicorn.run(app, host=SETTINGS.host, port=SETTINGS.port, log_level="info")


if __name__ == "__main__":
    main()
