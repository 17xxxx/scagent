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
#  vendor/wheels 默认是空目录（仓库不随附 wheel）；为空时会自动走联网安装（PyPI）。
#  若自建了 wheelhouse（push_registry.sh --make-lock），下面的分支会自动改用它。
COPY vendor/wheels/linux-amd64-cp311 /vendor/wheels
COPY agent_core/requirements.txt     /tmp/requirements.txt
COPY agent_core/requirements.lock    /tmp/requirements.lock

# ═══════════════════════════════════════════════════════════════════════════════
#  pip 下载策略
#
#  files.pythonhosted.org 在国内可能出现 85 kB/s 级别的慢速并读超时
#  （ReadTimeoutError），导致构建下载中途失败。pip 默认 timeout=15s / retries=5，
#  对这种抖动不够。
#
#  因此默认走国内镜像并显式加大重试与超时。海外或想用官方源可覆盖：
#      --build-arg PIP_INDEX_URL=https://pypi.org/simple
#  想彻底不联网：先 ./scripts/push_registry.sh --make-lock 生成 wheelhouse。
# ═══════════════════════════════════════════════════════════════════════════════
ARG PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
ARG PIP_OPTS="--timeout 60 --retries 10"

# 三种状态，按"锁文件是否真实"与"wheelhouse 是否有内容"分开判断：
#   ① 占位锁文件            → 联网装 requirements.txt   【版本不固定】
#   ② 有锁 + 有 wheelhouse  → 离线安装                  【不联网 + 版本固定】
#   ③ 有锁 + 无 wheelhouse  → 联网装【锁定版本】        【版本固定，构建机需 PyPI】
# 运行期与这三者都无关：包已在镜像层里，服务器不需要任何 Python 网络。
RUN set -e; \
    PIPARGS="${PIP_OPTS}"; \
    if [ -n "${PIP_INDEX_URL}" ]; then PIPARGS="${PIPARGS} -i ${PIP_INDEX_URL}"; fi; \
    echo "pip 参数: ${PIPARGS}"; \
    if grep -q "PLACEHOLDER" /tmp/requirements.lock; then \
      echo "⚠️  占位锁文件 → 联网安装 requirements.txt（版本不固定）"; \
      pip install ${PIPARGS} -r /tmp/requirements.txt; \
    elif ls /vendor/wheels/*.whl >/dev/null 2>&1; then \
      echo "✅ 离线安装：wheelhouse + 锁文件（不访问网络）"; \
      pip install --no-index --find-links=/vendor/wheels \
                  -r /tmp/requirements.lock; \
    else \
      echo "⚙️  有锁文件但无 wheelhouse → 联网安装【锁定版本】"; \
      echo "    构建机需要 PyPI；这不影响服务器运行（包已在镜像内）"; \
      pip install ${PIPARGS} -r /tmp/requirements.lock; \
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
#      （这种情况下 pipeline_cli.py 会在调用时抛 pydantic ValidationError）
# 显式指定 agent_core 位置，避免依赖脚本的相对路径推断
RUN SCAGENT_AGENT_DIR=/workspace/agent_core python /tmp/check_tool_schemas.py \
 && rm -f /tmp/check_tool_schemas.py

# ── 非 root 运行 ──────────────────────────────────────────────────────────────
RUN useradd -m -u 1000 scagent \
 && mkdir -p /state \
 && chown -R scagent:scagent /workspace
RUN chown scagent:scagent /state

USER scagent

# 默认值与 docker-compose 保持一致（均可被环境变量覆盖）；R2 清理：
#   · 数据/状态默认改为 /data 与 /state（compose 挂载点）
#   · 删掉 SCAGENT_BACKEND_DIR —— Python 侧零引用，是死配置（F2）
ENV SCAGENT_DATA_DIR=/data \
    SCAGENT_STATE_DIR=/state \
    SCAGENT_API_HOST=0.0.0.0 \
    SCAGENT_API_PORT=8080 \
    PYTHONPATH=/workspace/agent_core

EXPOSE 8080

# 仅做存活探测；带鉴权的完整健康检查见 deploy/verify.sh
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request,os,sys; \
sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:'+os.getenv('SCAGENT_API_PORT','8080')+'/docs',timeout=4).status==200 else 1)"

CMD ["python", "/workspace/agent_core/server.py"]
