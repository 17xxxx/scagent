# scripts/01_qc.R
library(Seurat)

# 核心工具函数：参数直接定义在形参里
run_quality_control <- function(data_path, min_cells = 3, min_features = 200, ...) {
  # 注意：末尾加上 `...` 可以自动忽略 Python 传过来的、但 QC 没用到的多余参数，防止报错
  
  print(paste("QC 收到参数 data_path:", data_path))
  
  # 具体的生信逻辑...
  # counts <- Read10X(data.dir = data_path)
  # seurat_obj <- CreateSeuratObject(counts, min.cells = min_cells, ...)
  
  return(list(
    status = "success",
    message = "QC 模块执行成功"
  ))
}