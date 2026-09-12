# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  05_dimplot.R —— 细胞分群可视化 (DimPlot)                                     ║
# ║  功能：生成 UMAP 降维散点图，支持多分组、样本拆分、标签等功能                    ║
# ║  读取：data/cell_annotation/seuratobject.json                                 ║
# ║  输出：data/dimplot/{project}_dimplot.pdf、日志、seuratobject.json            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# ── 预设 JSON 格式（注释，供 Agent / Python tool 参考） ──
# {
#   "project": "scRNA_project",
#   "reduction": "umap",
#   "group_by": ["orig.ident", "cell_type"],
#   "split_by": null,
#   "pt_size": 0.3,
#   "label": true,
#   "repel": true,
#   "label_size": 4,
#   "cols": null,
#   "order": true,
#   "raster": false,
#   "dpi": 300,
#   "width": 12,
#   "height": 8
# }

library(Seurat)
library(ggplot2)


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║              集中默认参数（小鼠物种）                                          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# ═══════════════════════════════════════════════════════════════════════════════
#  载入共享配置：所有路径来自 SCAGENT_* 环境变量，不再硬编码
# ═══════════════════════════════════════════════════════════════════════════════
local({
  cands <- c(
    file.path(Sys.getenv("SCAGENT_BACKEND_DIR", "/workspace/seurat_backend"), "_config.R"),
    file.path(getwd(), "seurat_backend", "_config.R"),
    file.path(getwd(), "_config.R")
  )
  hit <- cands[file.exists(cands)]
  if (length(hit) == 0)
    stop("找不到 _config.R；请设置 SCAGENT_BACKEND_DIR 指向 seurat_backend 目录")
  source(hit[[1]], local = FALSE, encoding = "UTF-8")
})

run_dimplot <- function(...) {
  # 截获 JSON
  json <- list(...)

  # ── 基础参数 ──
  project_name   <- "scRNA_project"
  input_dir      <- scagent_step_dir("cell_annotation")
  output_dir     <- scagent_step_dir("dimplot")

  # ── DimPlot 参数 ──
  reduction_name <- "umap"
  group_by_cols  <- c("orig.ident", "cell_type")
  split_by_col   <- NULL       # 默认不拆分，传 "orig.ident" 则按样本拆分
  pt_size        <- 0.3
  label_val      <- TRUE
  repel_val      <- TRUE
  label_size_val <- 4
  cols_val       <- NULL       # 自定义颜色，NULL 则用默认
  order_val      <- TRUE
  raster_val     <- FALSE
  dpi_val        <- 300
  width_val      <- 12
  height_val     <- 8

 
  # ── JSON 覆盖默认值 ──
  if (!is.null(json$project))     project_name   <- json$project
  if (!is.null(json$reduction))   reduction_name <- json$reduction
  if (!is.null(json$group_by))    group_by_cols  <- as.character(unlist(json$group_by))  # ✅ 修复
  if (!is.null(json$split_by))    split_by_col   <- json$split_by
  if (!is.null(json$pt_size))     pt_size        <- json$pt_size
  if (!is.null(json$label))       label_val      <- json$label
  if (!is.null(json$repel))       repel_val      <- json$repel
  if (!is.null(json$label_size))  label_size_val <- json$label_size
  if (!is.null(json$cols))        cols_val       <- as.character(unlist(json$cols))     # ✅ 修复
  if (!is.null(json$order))       order_val      <- json$order
  if (!is.null(json$raster))      raster_val     <- json$raster
  if (!is.null(json$dpi))         dpi_val        <- json$dpi
  if (!is.null(json$width))       width_val      <- json$width
  if (!is.null(json$height))      height_val     <- json$height

  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  # ── 日志系统 ──
  log_path <- file.path(output_dir, paste0(project_name, "_dimplot.log"))
  log_con  <- file(log_path, open = "wt")
  sink(log_con, append = TRUE, split = TRUE)
  log_msg <- function(...) {
    cat(paste0("[", Sys.time(), "] "), ..., "\n", sep = "")
  }

  

  log_msg("══════════ DimPlot 细胞分群可视化开始 ══════════")
  log_msg("项目:", project_name)
  log_msg("输出目录:", output_dir)

  # ═══════════════════════════════════════════════════════════════════════
  #  Step 1: 读取 Seurat 对象
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 1: 读取 Seurat 对象 ──")
  print("param3")
  .idx <- scagent_read_index(input_dir, what = "细胞注释")
  if (!.idx$ok) {
    log_msg("  错误:", .idx$message)
    sink()
    close(log_con)
    return(list(status = "error", message = .idx$message))
  }
  object_json_path <- .idx$path
  obj_info <- .idx$info
  rds_path <- scagent_resolve_rds(obj_info, "cell_annotation")
  log_msg("  读取对象索引:", object_json_path)
  log_msg("  加载 rds:", rds_path)

  seurat_obj <- readRDS(rds_path)
  log_msg("  细胞数:", ncol(seurat_obj))
  log_msg("  基因数:", nrow(seurat_obj))


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 2: DimPlot 可视化
  # ═══════════════════════════════════════════════════════════════════════


  # 构建 DimPlot 参数列表
  dimplot_args <- list(
    object     = seurat_obj,
    reduction  = reduction_name,
    group.by   = group_by_cols,
    pt.size    = pt_size,
    label      = label_val,
    label.size = label_size_val,
    repel      = repel_val,
    order      = order_val,
    raster     = raster_val
  )

  log_msg("")
  log_msg("── Step 2: DimPlot 可视化 ──")
  log_msg("  参数: reduction =", reduction_name)
  log_msg("  参数: group.by  =", paste(group_by_cols, collapse = ", "))
  log_msg("  参数: pt.size   =", pt_size)
  log_msg("  参数: label     =", label_val)
  log_msg("  参数: repel     =", repel_val)
  log_msg("  参数: split.by  =", if (is.null(split_by_col)) "NULL" else split_by_col)
  log_msg("  参数: order     =", order_val)
  log_msg("  参数: raster    =", raster_val)

  if (!is.null(split_by_col)) {
    dimplot_args$split.by <- split_by_col
  }

  if (!is.null(cols_val)) {
    dimplot_args$cols <- cols_val
  }
  print("param5")
# ==========================================
  log_msg("── [Debug] 检查传入 DimPlot 的最终参数结构 ──")
  
  # 创建一个专门用于打印的副本
  debug_args <- dimplot_args
  # 用简短的字符串替换掉庞大的 Seurat 对象，防止日志爆炸
  debug_args$object <- paste0("<Seurat Object 包含 ", ncol(seurat_obj), " 个细胞>")
  
  # 使用 capture.output 和 str() 将列表的层次结构美观地写入日志
  debug_str <- capture.output(str(debug_args))
  log_msg(paste(debug_str, collapse = "\n"))
  # ==========================================


  p <- do.call(DimPlot, dimplot_args) +
    ggtitle(paste(project_name, "— DimPlot"))

  #图片动态宽度，此设置会忽视用户输入
  n_splits <- 1
  if (!is.null(split_by_col)) {
    n_splits <- length(unique(seurat_obj[[split_by_col]][[1]]))
  }
  # 基础宽度 6，每增加一个面板多加 4 
  dynamic_width <- 6 + (n_splits * 4)
  # 保存图片
  dimplot_file <- file.path(output_dir, paste0(project_name, "_dimplot.pdf"))
  ggsave(dimplot_file, p, width = dynamic_width, height = height_val, dpi = dpi_val)
  log_msg("  输出图片:", dimplot_file)
  sink()
  close(log_con)

  return(list(
    status          = "success",
    message         = "DimPlot 可视化完成",
    project         = project_name,
    dimplot_file    = dimplot_file,
    log_path        = log_path,
    cells           = ncol(seurat_obj),
    reduction       = reduction_name
  ))
}
