# library(plumber)

# #* @get /ping
# function() {
#   return(list(message = "R backend is alive!"))
# }

# #* @get /read_test
# function() {
#   content <- readLines("/workspace/shared_data/test.txt")
#   return(list(file_content = content))
# }




library(plumber)

# 预先加载所有工具脚本
source("/workspace/seurat_backend/01_qc.R")
source("/workspace/seurat_backend/02_pca_umap.R")
source("/workspace/seurat_backend/03_snn_cluster.R")
source("/workspace/seurat_backend/04_cell_annotation.R")
source("/workspace/seurat_backend/05_dimplot.R")
source("/workspace/seurat_backend/06_marker_viz.R")
source("/workspace/seurat_backend/07_cell_ratio.R")
source("/workspace/seurat_backend/08_heatmap.R")
source("/workspace/seurat_backend/09_enrichment.R")

#* 通用分发网关
#* @post /api/execute_task
function(req, ...) {
  # 1. 从 HTTP 请求体中直接获取解析好的 JSON 数据 (此时是一个 R List)
  body <- req$body
  
  tool_name <- body$tool_name
  tool_params <- body$params      # 这就是你的"未知参数 JSON 对象"

  # ── 调试日志：打印收到的参数结构 ──
  cat("\n══════════════════════════════════════════\n")
  cat("[api.R] 收到请求\n")
  cat("  tool_name :", tool_name, "\n")
  cat("  params 名字:", paste(names(tool_params), collapse = ", "), "\n")
  if ("samples" %in% names(tool_params)) {
    cat("  samples 数量:", length(tool_params$samples), "\n")
    cat("  samples 名字:", paste(names(tool_params$samples), collapse = ", "), "\n")
  }
  cat("══════════════════════════════════════════\n\n")
  
  # 2. 根据工具名，映射到对应的 R 函数字串
  # 未来每增加一个新工具，只需要在这个映射表里加一行即可
  func_mapping <- list(
    "qc"          = "run_quality_control",
    "pca"         = "run_pca_umap_analysis",
    "snn"         = "run_snn_cluster",
    "anno"        = "run_cell_annotation",
    "dimplot"     = "run_dimplot",
    "marker_viz"  = "run_marker_viz",
    "cell_ratio"  = "run_cell_ratio",
    "heatmap"     = "run_heatmap",
    "enrichment"  = "run_enrichment"
  )
  
  target_function_name <- func_mapping[[tool_name]]
  
  if (is.null(target_function_name)) {
    return(list(status = "error", message = paste("未知的工具名:", tool_name)))
  }
  
  # 3. 动态执行与参数投喂 (核心魔法)
  tryCatch({
    # 使用 get() 动态把字符串变成真正的函数对象，然后用 do.call 投喂未知参数
    result <- do.call(get(target_function_name), tool_params)
    return(result)
    
  }, error = function(e) {
    return(list(status = "error", message = paste("执行出错:", e$message)))
  })
}

#* 运行 run_test.R 自检脚本
#* @get /api/run_test
function() {
  tryCatch({
    invisible(capture.output(source("/workspace/seurat_backend/run_test.R")))
    return(list(status = "success", message = "run_test 全部通过"))
  }, error = function(e) {
    return(list(status = "error", message = paste("run_test 失败:", e$message)))
  })
}

#* @plumber
function(pr) {
  pr
}
