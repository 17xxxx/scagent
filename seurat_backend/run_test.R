source("/workspace/seurat_backend/01_qc.R")

cat("\n========== run_test: 开始验证 QC 脚本 ==========\n")

target_function_name <- "run_quality_control"

tool_params <- list(
  data_path = "/workspace/data/rawdata/KM0/",
  min_cells = 3,
  min_features = 200
)

cat("[run_test] 调用函数:", target_function_name, "\n")
cat("[run_test] 参数:", paste(names(tool_params), tool_params, sep = " = ", collapse = ", "), "\n")

result <- do.call(get(target_function_name), tool_params)

if (result$status == "success") {
  cat("[run_test] ✓ 执行成功\n")
  cat("[run_test] 消息:", result$message, "\n")
  cat("[run_test] RDS 输出:", result$rds_path, "\n")
  cat("[run_test] JSON 输出:", result$json_path, "\n")
} else {
  cat("[run_test] ✗ 执行失败:", result$message, "\n")
  quit(status = 1)
}

cat("========== run_test: 验证通过 ✓ ==========\n")
