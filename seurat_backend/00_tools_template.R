# 文件位置: seurat_backend/scripts/00_template.R
library(Seurat)

# 【核心对应点】：这里的变量名 "run_quality_control"，
# 必须和 api.R 里 func_mapping 中配置的字符串一模一样！
run_quality_control <- function(data_path, min_cells = 3, min_features = 200, ...) {
  
  # 这里写具体的业务逻辑
  print("正在执行质控逻辑...")
  
  # 假设处理完了，返回一个结果列表
  return(list(
    status = "success",
    message = "QC 模块执行成功"
  ))
}

# 你也可以在这个文件里写一些辅助函数，比如：
# 只要不在 api.R 的映射表里，Python 端就无法直接调用它，它是安全的内部函数
.calculate_mt_ratio <- function(seurat_obj) {
    # ...
}