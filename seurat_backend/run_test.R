# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  run_test.R —— R 后端自检脚本                                                 ║
# ║                                                                              ║
# ║  注意：本脚本会真的跑一遍 QC，需要 data/rawdata 下有 10X 数据。               ║
# ║  仅用于构建期冒烟测试（GET /api/run_test），日常健康检查请用 GET /api/ping。   ║
# ║                                                                              ║
# ║  路径全部来自环境变量，不再硬编码。                                            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

backend_dir <- Sys.getenv("SCAGENT_BACKEND_DIR", "/workspace/seurat_backend")
data_root   <- Sys.getenv("SCAGENT_DATA_DIR", "/workspace/data")

source(file.path(backend_dir, "_config.R"), encoding = "UTF-8")
source(file.path(backend_dir, "01_qc.R"), encoding = "UTF-8")

cat("\n========== run_test: 开始验证 QC 脚本 ==========\n")

target_function_name <- "run_quality_control"

# 自动挑选第一个可用的样本，避免写死 KM0
raw_dir <- file.path(data_root, "rawdata")
samples_available <- if (dir.exists(raw_dir)) {
  list.dirs(raw_dir, recursive = FALSE, full.names = TRUE)
} else character(0)
samples_available <- samples_available[
  file.exists(file.path(samples_available, "matrix.mtx.gz")) |
  file.exists(file.path(samples_available, "matrix.mtx"))
]

if (length(samples_available) == 0) {
  cat("[run_test] 跳过：", raw_dir, " 下没有可用的 10X 样本\n")
  cat("[run_test] （这是正常情况 —— 自检数据未随镜像分发）\n")
  quit(status = 0)
}

first_sample <- samples_available[[1]]
tool_params <- list(
  samples      = stats::setNames(list(first_sample), basename(first_sample)),
  project      = "test_project",
  min_cells    = 3,
  min_features = 200
)

cat("[run_test] 调用函数:", target_function_name, "\n")
cat("[run_test] 样本:", first_sample, "\n")
cat("[run_test] 参数:\n")
str(tool_params)

result <- do.call(get(target_function_name), tool_params)

cat("\n[run_test] 返回: status =", result$status, "\n")

if (isTRUE(result$status == "success")) {
  cat("[run_test] ✓ 执行成功\n")
  cat("[run_test] 消息:", result$message, "\n")
  cat("[run_test] 项目:", result$project, "\n")
  cat("[run_test] 过滤前:", result$cells_before, " 过滤后:", result$cells_after, "\n")
  cat("[run_test] RDS 输出:", result$rds_path, "\n")
  cat("[run_test] 日志:", result$log_path, "\n")
} else {
  cat("[run_test] ✗ 执行失败:", result$message, "\n")
  quit(status = 1)
}

cat("========== run_test: 验证通过 ==========\n")
