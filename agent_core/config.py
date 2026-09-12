"""
config.py —— scAgent Python 侧集中配置
========================================
原则：**所有可调项都来自环境变量**，代码里只保留默认值。
     这样同一份镜像可以在不同环境（本地 / 云 / 客户内网）用环境变量区分，不需要改代码。

对应方案：docs/CLOUD_DEPLOY_PLAN.md §6.1 环境变量约定
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional


def _get(name: str, default: str = "") -> str:
    return os.getenv(name, default)


def _get_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _get_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    return raw.strip().lower() in {"1", "true", "yes", "y", "on"}


@dataclass(frozen=True)
class Settings:
    # ── LLM（唯一允许出网的外部依赖）────────────────────────────────────────
    llm_provider: str          # deepseek | ollama | none
    llm_model: str
    llm_base_url: Optional[str]
    llm_api_key: Optional[str]
    llm_temperature: float
    llm_timeout: int
    llm_max_retries: int

    # ── 路径 ────────────────────────────────────────────────────────────────
    data_dir: str              # 分析产物根目录
    state_dir: str             # 会话检查点 / SQLite 等运行时状态
    checkpoint_db: str

    # ── 服务 ────────────────────────────────────────────────────────────────
    host: str
    port: int
    token: str                 # 客户端访问令牌（必填）
    hitl_mode: str             # interactive | auto_approve | deny_all
    max_concurrent_runs: int
    tool_run_limit: int
    enable_web_ui: bool

    # ── 历史压缩 ────────────────────────────────────────────────────────────
    max_history_tokens: int
    keep_recent_messages: int

    @property
    def llm_enabled(self) -> bool:
        return self.llm_provider != "none"

    def llm_ready(self) -> tuple[bool, str]:
        """检查 LLM 配置是否可用，返回 (是否可用, 原因)。"""
        if not self.llm_enabled:
            return False, "SCAGENT_LLM_PROVIDER=none（已禁用 LLM，请改用 pipeline_cli.py）"
        if self.llm_provider in {"deepseek", "openai"} and not self.llm_api_key:
            return False, "缺少 API Key：请设置 SCAGENT_LLM_API_KEY 或 DEEPSEEK_API_KEY"
        return True, "ok"


def load_settings() -> Settings:
    """从环境变量读取配置（每次调用都重新读取，便于测试）。"""
    provider = _get("SCAGENT_LLM_PROVIDER", "deepseek").strip().lower()

    # 按 provider 决定默认 base_url（显式设置优先）
    default_base = {
        "deepseek": "https://api.deepseek.com",
        "ollama": "http://ollama:11434/v1",
    }.get(provider)

    base_url = (
        _get("SCAGENT_LLM_BASE_URL")
        or _get("DEEPSEEK_BASE_URL")
        or default_base
        or None
    )
    api_key = (
        _get("SCAGENT_LLM_API_KEY")
        or _get("DEEPSEEK_API_KEY")
        or ("ollama" if provider == "ollama" else None)   # ollama 不校验 key
        or None
    )
    default_model = {
        "deepseek": "deepseek-v4-flash",
        "ollama": "qwen2.5:7b-instruct",
    }.get(provider, "deepseek-v4-flash")

    data_dir = _get("SCAGENT_DATA_DIR", "/workspace/data")
    state_dir = _get("SCAGENT_STATE_DIR", os.path.join(data_dir, "..", "state"))

    return Settings(
        llm_provider=provider,
        llm_model=_get("SCAGENT_LLM_MODEL", default_model),
        llm_base_url=base_url,
        llm_api_key=api_key,
        llm_temperature=float(_get("SCAGENT_LLM_TEMPERATURE", "0")),
        llm_timeout=_get_int("SCAGENT_LLM_TIMEOUT", 120),
        llm_max_retries=_get_int("SCAGENT_LLM_MAX_RETRIES", 3),

        data_dir=data_dir,
        state_dir=state_dir,
        checkpoint_db=_get("SCAGENT_CHECKPOINT_DB",
                           os.path.join(state_dir, "checkpoints.sqlite")),

        host=_get("SCAGENT_API_HOST", "0.0.0.0"),
        port=_get_int("SCAGENT_API_PORT", 8080),
        token=_get("SCAGENT_TOKEN", ""),
        hitl_mode=_get("SCAGENT_HITL", "interactive").strip().lower(),
        max_concurrent_runs=_get_int("SCAGENT_MAX_CONCURRENT_RUNS", 2),
        tool_run_limit=_get_int("SCAGENT_TOOL_RUN_LIMIT", 2),
        enable_web_ui=_get_bool("SCAGENT_WEB_UI", True),

        max_history_tokens=_get_int("MAX_HISTORY_TOKENS", 6000),
        keep_recent_messages=_get_int("KEEP_RECENT_MESSAGES", 10),
    )
