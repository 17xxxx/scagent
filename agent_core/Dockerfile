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

# 三种状态，按"锁文件是否存在"与"wheelhouse 是否可用"分开判断：
#   ① 占位锁文件            → 联网装 requirements.txt   【版本不固定，最差】
#   ② 有锁 + 有 wheelhouse  → 离线安装                  【最佳：不联网 + 版本固定 + 可校验哈希】
#   ③ 有锁 + 无 wheelhouse  → 联网装【锁定版本】        【版本固定，但构建机需 PyPI】
# 说明：③ 的存在很重要 —— 它让"版本固定"不必先有 wheelhouse。
#       运行期与这三者都无关：包已在镜像层里，服务器不需要任何 Python 网络。
RUN set -e; \
    if grep -q "PLACEHOLDER" /tmp/requirements.lock; then \
      echo "⚠️  占位锁文件 → 联网安装 requirements.txt（版本不固定）"; \
      pip install -r /tmp/requirements.txt; \
    elif ls /vendor/wheels/*.whl >/dev/null 2>&1; then \
      if grep -q -- "--hash=" /tmp/requirements.lock; then \
        echo "✅ 离线安装：wheelhouse + 锁文件 + 哈希校验"; \
        pip install --no-index --find-links=/vendor/wheels \
                    --require-hashes -r /tmp/requirements.lock; \
      else \
        echo "✅ 离线安装：wheelhouse + 锁文件（锁文件无哈希，跳过哈希校验）"; \
        pip install --no-index --find-links=/vendor/wheels \
                    -r /tmp/requirements.lock; \
      fi; \
    else \
      echo "⚙️  有锁文件但无 wheelhouse → 联网安装【锁定版本】"; \
      echo "    构建机需要 PyPI；这不影响服务器运行（包已在镜像内）"; \
      pip install -r /tmp/requirements.lock; \
    fi; \
    rm -f /tmp/requirements.txt /tmp/requirements.lock

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
