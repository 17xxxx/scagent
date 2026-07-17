source("/workspace/seurat_backend/01_qc.R")

cat("\n========== run_test: 开始验证 QC 脚本 ==========\n")

target_function_name <- "run_quality_control"

# 使用新的平铺 JSON 格式：samples dict + 参数
tool_params <- list(
  samples   = list(KM0 = "/workspace/data/rawdata/KM0"),
  project   = "test_project",
  min_cells = 3,
  min_features = 200
)

cat("[run_test] 调用函数:", target_function_name, "\n")
cat("[run_test] 参数:\n")
str(tool_params)

result <- do.call(get(target_function_name), tool_params)

cat("\n[run_test] 返回: status =", result$status, "\n")

if (result$status == "success") {
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
