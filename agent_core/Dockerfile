# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  agent_core/Dockerfile —— scAgent Agent 服务镜像                              ║
# ║                                                                              ║
# ║  构建上下文 = 项目根目录（docker-compose 里 context: ..）                      ║
# ║                                                                              ║
# ║  两种构建模式（自动切换）：                                                    ║
# ║    · 离线模式：agent_core/requirements.lock 是真实锁文件时，                  ║
# ║      只用 vendor/wheels 安装并强制校验哈希 —— 构建期也不访问 PyPI。            ║
# ║    · 首次构建：requirements.lock 仍是占位文件时，回退到联网安装，             ║
# ║      仅用于把项目跑起来以便生成锁文件。                                        ║
# ║                                                                              ║
# ║  安全：绝不 COPY .env / *.key（.dockerignore 已兜底，此处再次声明）。          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

FROM python:3.11-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /workspace

# ── Python 依赖 ────────────────────────────────────────────────────────────────
COPY vendor/wheels/linux-amd64-cp311 /vendor/wheels
COPY agent_core/requirements.txt     /tmp/requirements.txt
COPY agent_core/requirements.lock    /tmp/requirements.lock

RUN if grep -q "PLACEHOLDER" /tmp/requirements.lock; then \
      echo "⚠️  requirements.lock 仍是占位文件 —— 回退到联网安装（首次构建专用）"; \
      echo "    建议尽快执行 Step 5 生成真实锁文件，之后构建将完全离线。"; \
      pip install -r /tmp/requirements.txt; \
    else \
      echo "✅ 离线安装模式：仅使用 /vendor/wheels，并强制校验哈希"; \
      pip install --no-index --find-links=/vendor/wheels \
                  --require-hashes -r /tmp/requirements.lock; \
    fi \
 && rm -f /tmp/requirements.txt /tmp/requirements.lock

# 依赖自检：确认关键 API 真的可用（版本不匹配时在这里失败，而不是运行期）
RUN python -c "from langchain.agents import create_agent; \
from langchain.agents.middleware import HumanInTheLoopMiddleware, SummarizationMiddleware, ToolCallLimitMiddleware; \
import fastapi, uvicorn, langgraph; \
print('依赖自检通过')" \
 && pip check \
 && pip freeze --all > /opt/scagent-py-packages.txt

# ── 应用代码 ──────────────────────────────────────────────────────────────────
COPY agent_core /workspace/agent_core
COPY scripts/check_tool_schemas.py /tmp/check_tool_schemas.py

# 构建期断言：所有工具的 args_schema 必须容忍空参数与 None
#   —— 防止"字段声明为必填 str、调用方传 None"这类错误溜到运行期
#      （曾经导致 pipeline_cli.py status 直接抛 pydantic ValidationError）
# 显式指定 agent_core 位置，避免依赖脚本的相对路径推断
RUN SCAGENT_AGENT_DIR=/workspace/agent_core python /tmp/check_tool_schemas.py \
 && rm -f /tmp/check_tool_schemas.py

# ── 非 root 运行 ──────────────────────────────────────────────────────────────
RUN useradd -m -u 1000 scagent \
 && mkdir -p /workspace/state \
 && chown -R scagent:scagent /workspace

USER scagent

# 默认值与 docker-compose 保持一致（均可被环境变量覆盖）
ENV SCAGENT_DATA_DIR=/workspace/data \
    SCAGENT_STATE_DIR=/workspace/state \
    SCAGENT_BACKEND_DIR=/workspace/seurat_backend \
    SCAGENT_API_HOST=0.0.0.0 \
    SCAGENT_API_PORT=8080 \
    PYTHONPATH=/workspace/agent_core

EXPOSE 8080

# 仅做存活探测；带鉴权的完整健康检查见 deploy/verify.sh
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request,os,sys; \
sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:'+os.getenv('SCAGENT_API_PORT','8080')+'/docs',timeout=4).status==200 else 1)"

CMD ["python", "/workspace/agent_core/server.py"]
