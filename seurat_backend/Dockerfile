# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  seurat_backend/Dockerfile —— R 后端应用层                                    ║
# ║                                                                              ║
# ║  只做两件事：把代码 COPY 进去 + 做构建期断言。                                 ║
# ║  因此改一行 R 代码只需重建约 10 MB 的层，耗时数秒                              ║
# ║  （重型依赖在 Dockerfile.runtime 里，见该文件说明）。                          ║
# ║                                                                              ║
# ║  重要：参考数据（celldex 等）**不进镜像** —— 由只读数据卷挂载。                 ║
# ║        见 docs/PROD_HANDOVER.md / docs/PROD_HANDOVER.md。      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# 由构建机传入，默认值指向本地标签；正式构建请用 push_registry.sh 传私有 registry 地址
ARG RUNTIME=scagent-runtime:1.0.0
FROM ${RUNTIME}

LABEL scagent.component="seurat-app"

# ── 应用代码 ──────────────────────────────────────────────────────────────────
COPY seurat_backend /workspace/seurat_backend

# ── 构建期断言：运行期禁止任何包安装（保证"零下载"可证明）────────────────────
RUN if grep -rnE "install\.packages|BiocManager::install|pak::pkg_install|remotes::install" \
        /workspace/seurat_backend/*.R ; then \
      echo "❌ 运行期脚本中存在包安装调用，违反离线约束"; \
      exit 1; \
    else \
      echo "✅ 断言通过：步骤脚本中无任何包安装调用"; \
    fi

# ── 构建期断言：镜像内不得包含参考数据（数据与软件分离）──────────────────────
RUN if find /workspace -name "*.rds" -o -name "*.RDS" | grep -q . ; then \
      echo "❌ 镜像中发现 .rds 文件 —— 参考数据必须走数据卷，不得打进镜像"; \
      find /workspace -name "*.rds" -o -name "*.RDS"; \
      exit 1; \
    else \
      echo "✅ 断言通过：镜像内无参考数据文件"; \
    fi

# ── 运行时路径约定（均可被环境变量覆盖）──────────────────────────────────────
ENV SCAGENT_BACKEND_DIR=/workspace/seurat_backend \
    SCAGENT_DATA_DIR=/workspace/data \
    SCAGENT_REFDATA_DIR=/ref/celldex \
    SCAGENT_API_HOST=0.0.0.0 \
    SCAGENT_API_PORT=9000

WORKDIR /workspace

EXPOSE 9000

# 健康检查：/api/ping（api.R 提供），带 start-period 容忍 R 冷启动
HEALTHCHECK --interval=15s --timeout=10s --start-period=120s --retries=20 \
  CMD Rscript -e "q(status = if (is.null(tryCatch(jsonlite::fromJSON('http://127.0.0.1:9000/api/ping'), error=function(e) NULL))) 1 else 0)"

CMD ["Rscript", "/workspace/seurat_backend/run_api.R"]
