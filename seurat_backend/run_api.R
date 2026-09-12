#!/usr/bin/env Rscript
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  run_api.R —— Plumber 服务启动器                                              ║
# ║                                                                              ║
# ║  从 docker-compose 的 command 中抽出来，使 Docker 与原生（无容器）两种运行方式  ║
# ║  共用同一份启动逻辑。                                                          ║
# ║                                                                              ║
# ║  环境变量：                                                                   ║
# ║    SCAGENT_BACKEND_DIR  R 脚本目录   默认 /workspace/seurat_backend            ║
# ║    SCAGENT_API_HOST     监听地址     默认 0.0.0.0                             ║
# ║    SCAGENT_API_PORT     监听端口     默认 9000                                ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

suppressPackageStartupMessages(library(plumber))

backend_dir <- Sys.getenv("SCAGENT_BACKEND_DIR", "/workspace/seurat_backend")
host        <- Sys.getenv("SCAGENT_API_HOST", "0.0.0.0")
port        <- as.integer(Sys.getenv("SCAGENT_API_PORT", "9000"))

api_file <- file.path(backend_dir, "api.R")
if (!file.exists(api_file)) {
  stop("找不到 api.R: ", api_file, "；请设置 SCAGENT_BACKEND_DIR")
}

cat("[run_api.R] 加载 API:", api_file, "\n")
pr <- plumber::pr(api_file)

cat("[run_api.R] 监听 http://", host, ":", port, "\n", sep = "")
plumber::pr_run(pr, host = host, port = port)
