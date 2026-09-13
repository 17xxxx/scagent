"""
config.py —— scAgent Python 侧集中配置
========================================
原则：**所有可调项都来自环境变量**，代码里只保留默认值。
     这样同一份镜像可以在不同环境（本地 / 云 / 客户内网）用环境变量区分，不需要改代码。

对应方案：docs/PROD_HANDOVER.md 环境变量约定
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


class SecretError(RuntimeError):
    """密钥配置错误（配了 *_FILE 却读不到）—— 应当快速失败，而不是静默回退。"""


def _selinux_status() -> str:
    """探测 SELinux 状态。

    为什么重要：file 类型的 Docker secret 底层是 bind mount，
    宿主机文件若标签不对（如 user_home_t）会让容器进程拿到 EPERM，
    而 `ls -l` 看上去属主/权限完全正常 —— 极易误诊。
    Compose 的 secrets 语法又不支持 :z/:Z（那是 volumes 的选项），
    所以只能预先 chcon 打标签。
    """
    try:
        with open("/sys/fs/selinux/enforce", "r", encoding="utf-8") as fh:
            return "Enforcing" if fh.read().strip() == "1" else "Permissive"
    except OSError:
        return ""          # 无 SELinux 或未挂载 sysfs


def _describe_secret_failure(file_var: str, path: str, exc: OSError) -> str:
    """把"读不到密钥文件"变成可定位的诊断，而不是一句 Permission denied。"""
    uid = os.getuid() if hasattr(os, "getuid") else "?"
    gid = os.getgid() if hasattr(os, "getgid") else "?"
    lines = [f"{file_var}={path} 读取失败：{exc}",
             f"  容器内进程 UID:GID = {uid}:{gid}"]

    try:
        st = os.stat(path)
        lines.append(f"  密钥文件 属主:属组 = {st.st_uid}:{st.st_gid}  "
                     f"权限 = {oct(st.st_mode & 0o777)}")
    except OSError as stat_exc:
        lines.append(f"  （无法 stat 密钥文件：{stat_exc}）")

    try:
        dst = os.stat(os.path.dirname(path) or "/")
        lines.append(f"  所在目录 属主:属组 = {dst.st_uid}:{dst.st_gid}  "
                     f"权限 = {oct(dst.st_mode & 0o777)}")
    except OSError:
        pass

    sel = _selinux_status()
    if sel:
        lines.append(f"  SELinux = {sel}")

    lines += [
        "  常见原因与处置（按可能性排序）：",
        f"    1) 属主不匹配：容器以 UID {uid} 运行，而宿主机上的密钥文件属主不是它。",
        f"       修复： sudo chown {uid}:{uid} <宿主机上的密钥文件>",
        "       注意：Compose 的 file 型 secret 底层是 bind mount，",
        "             services.secrets 的 uid/gid/mode 三个属性【不被支持】，",
        "             属主完全由宿主机文件决定。",
    ]
    if sel == "Enforcing":
        lines += [
            "    2) SELinux（检测到 Enforcing）：标签不匹配会报 EPERM，"
            "且 ls -l 看起来正常。",
            "       修复： sudo chcon -t container_file_t <宿主机上的密钥文件>",
        ]
    else:
        lines.append("    2) SELinux：未启用（已检测）")
    lines += [
        "    3) userns-remap / rootless Docker：容器 UID 会映射到宿主机的高位 UID，",
        "       此时上面第 1 条里的 UID 不是宿主机上的真实 UID，",
        "       需按映射后的 UID 设置属主。",
        "    4) 路径写错或文件未挂载：确认 compose 的 secrets 段与 target 一致。",
        "  自检工具： ./scripts/check_secrets.sh",
    ]
    return "\n".join(lines)


def _secret(*names: str) -> Optional[str]:
    """读取密钥，支持 Docker secrets 约定。

    取值优先级（对每个候选名依次尝试）：
        1. <NAME>_FILE 指向的文件内容      ← 生产推荐，密钥不进容器环境变量
        2. 环境变量 <NAME>                 ← 开发方便

    为什么需要文件方式：环境变量会出现在 `docker inspect` 的 Config.Env 里，
    任何有 docker 权限的人都能读到；而 secrets 文件只挂载到容器内，
    不进环境、不进 `docker inspect`、不进镜像层。

    配了 *_FILE 却读不到时**直接抛错**而不是回退到环境变量 ——
    静默回退会用错密钥，比启动失败更难排查。
    """
    for name in names:
        file_var = f"{name}_FILE"
        path = os.getenv(file_var)
        if path and path.strip():
            try:
                with open(path.strip(), "r", encoding="utf-8") as fh:
                    content = fh.read().strip()
            except OSError as exc:
                raise SecretError(_describe_secret_failure(file_var, path, exc)) from exc
            if not content:
                raise SecretError(f"{file_var}={path} 是空文件")
            return content
    for name in names:
        val = os.getenv(name)
        if val and val.strip():
            return val.strip()
    return None


def _get_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    try:
        return float(raw)
    except ValueError:
        return default


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

    # ── 密钥配置错误（若非空，服务应拒绝启动并原样打印）────────────────────
    config_error: Optional[str]

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
        if self.config_error:
            return False, f"密钥配置错误：{self.config_error}"
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
    # ── 密钥：支持 *_FILE（Docker secrets），失败即记录错误、不静默回退 ──
    config_error: Optional[str] = None
    try:
        api_key = _secret("SCAGENT_LLM_API_KEY", "DEEPSEEK_API_KEY")
        token = _secret("SCAGENT_TOKEN") or ""
    except SecretError as exc:
        config_error = str(exc)
        api_key, token = None, ""

    if api_key is None and provider == "ollama":
        api_key = "ollama"          # ollama 不校验 key
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
        llm_temperature=_get_float("SCAGENT_LLM_TEMPERATURE", 0.0),
        llm_timeout=_get_int("SCAGENT_LLM_TIMEOUT", 120),
        llm_max_retries=_get_int("SCAGENT_LLM_MAX_RETRIES", 3),

        data_dir=data_dir,
        state_dir=state_dir,
        checkpoint_db=_get("SCAGENT_CHECKPOINT_DB",
                           os.path.join(state_dir, "checkpoints.sqlite")),

        host=_get("SCAGENT_API_HOST", "0.0.0.0"),
        port=_get_int("SCAGENT_API_PORT", 8080),
        config_error=config_error,
        token=token,
        hitl_mode=_get("SCAGENT_HITL", "interactive").strip().lower(),
        max_concurrent_runs=_get_int("SCAGENT_MAX_CONCURRENT_RUNS", 2),
        tool_run_limit=_get_int("SCAGENT_TOOL_RUN_LIMIT", 2),
        enable_web_ui=_get_bool("SCAGENT_WEB_UI", True),

        max_history_tokens=_get_int("MAX_HISTORY_TOKENS", 6000),
        keep_recent_messages=_get_int("KEEP_RECENT_MESSAGES", 10),
    )
