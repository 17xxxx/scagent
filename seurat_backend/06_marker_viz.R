# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  06_marker_viz.R —— 标记基因表达可视化 (VlnPlot + DotPlot)                    ║
# ║  功能：小提琴图 + 气泡图，展示标记基因在各细胞群的表达分布                        ║
# ║  读取：data/cell_annotation/seuratobject.json                                 ║
# ║  必须参数：marker_genes — 基因名列表（此工具要求 LLM 传入）                      ║
# ║  输出：data/marker_viz/{project}_vln.pdf、{project}_dot.pdf、日志、seuratobject ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# ── 预设 JSON 格式（注释，供 Agent / Python tool 参考） ──
# marker_genes 为必须参数，由 LLM 在调用工具时传入
# {
#   "project": "scRNA_project",
#   "marker_genes": ["CD3D", "MS4A1", "CD68", "EPCAM", "PECAM1", "COL1A1"],
#   "group_by": "cell_type",
#   "pt_size": 0.1,
#   "ncol": 2,
#   "split_by": null,
#   "log": false,
#   "dot_scale": 8,
#   "cols": null,
#   "col_min": -2.5,
#   "col_max": 2.5,
#   "cluster_idents": false,
#   "dpi": 300,
#   "vln_width": 12,
#   "vln_height": 10,
#   "dot_width": 10,
#   "dot_height": 8,
#   "dot_angle": 45
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

run_marker_viz <- function(...) {
  json <- list(...)

  # ── 基础参数 ──
  project_name   <- "scRNA_project"
  input_dir      <- scagent_step_dir("cell_annotation")
  output_dir     <- scagent_step_dir("marker_viz")

  # ── 必须参数（LLM 传入）──
  marker_genes   <- NULL

  # ── VlnPlot 参数 ──
  vln_group_by   <- "cell_type"
  pt_size        <- 0.1
  vln_ncol       <- 2
  split_by_col   <- NULL
  log_val        <- FALSE

  # ── DotPlot 参数 ──
  dot_scale      <- 8
  cols_val       <- NULL
  col_min_val    <- -2.5
  col_max_val    <- 2.5
  cluster_idents <- FALSE

  # ── 图像输出参数 ──
  dpi_val        <- 300
  vln_width      <- 12
  vln_height     <- 10
  dot_width      <- 10
  dot_height     <- 8
  dot_angle      <- 45

  # ── JSON 覆盖默认值 ──
  if (!is.null(json$project))        project_name   <- json$project
  if (!is.null(json$marker_genes))   marker_genes   <- unlist(json$marker_genes)
  if (!is.null(json$group_by))       vln_group_by   <- json$group_by
  if (!is.null(json$pt_size))        pt_size        <- json$pt_size
  if (!is.null(json$ncol))           vln_ncol       <- json$ncol
  if (!is.null(json$split_by))       split_by_col   <- json$split_by
  if (!is.null(json$log))            log_val        <- json$log
  if (!is.null(json$dot_scale))      dot_scale      <- json$dot_scale
  if (!is.null(json$cols))           cols_val       <- json$cols
  if (!is.null(json$col_min))        col_min_val    <- json$col_min
  if (!is.null(json$col_max))        col_max_val    <- json$col_max
  if (!is.null(json$cluster_idents)) cluster_idents <- json$cluster_idents
  if (!is.null(json$dpi))            dpi_val        <- json$dpi
  if (!is.null(json$vln_width))      vln_width      <- json$vln_width
  if (!is.null(json$vln_height))     vln_height     <- json$vln_height
  if (!is.null(json$dot_width))      dot_width      <- json$dot_width
  if (!is.null(json$dot_height))     dot_height     <- json$dot_height
  if (!is.null(json$dot_angle))      dot_angle      <- json$dot_angle

  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  # ── 日志系统 ──
  log_path <- file.path(output_dir, paste0(project_name, "_marker_viz.log"))
  log_con  <- file(log_path, open = "wt")
  sink(log_con, append = TRUE, split = TRUE)
  log_msg <- function(...) {
    cat(paste0("[", Sys.time(), "] "), ..., "\n", sep = "")
  }

  log_msg("══════════ 标记基因表达可视化开始 ══════════")
  log_msg("项目:", project_name)

  # ── 检查必须参数 ──
  if (is.null(marker_genes) || length(marker_genes) == 0) {
    log_msg("  错误: 缺少必须参数 marker_genes")
    sink()
    close(log_con)
    return(list(status = "error",
                message = "缺少必须参数 marker_genes，请提供标记基因名称列表"))
  }
  log_msg("标记基因:", paste(marker_genes, collapse = ", "))


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 1: 读取 Seurat 对象
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 1: 读取 Seurat 对象 ──")

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
  log_msg("  加载 rds:", rds_path)

  seurat_obj <- readRDS(rds_path)
  log_msg("  细胞数:", ncol(seurat_obj))
  log_msg("  基因数:", nrow(seurat_obj))


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 2: 验证基因是否存在于数据集中
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 2: 验证标记基因 ──")

  all_genes <- rownames(seurat_obj)
  missing_genes <- setdiff(marker_genes, all_genes)
  found_genes <- intersect(marker_genes, all_genes)

  if (length(missing_genes) > 0) {
    log_msg("  警告: 以下基因在数据集中不存在:", paste(missing_genes, collapse = ", "))
  }
  log_msg("  有效基因:", paste(found_genes, collapse = ", "))

  if (length(found_genes) == 0) {
    log_msg("  错误: 所有标记基因在数据集中均不存在")
    sink()
    close(log_con)
    return(list(status = "error",
                message = "所有标记基因在数据集中均不存在"))
  }

  # ═══════════════════════════════════════════════════════════════════════
  #  Step 3: VlnPlot — 小提琴图
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 3: VlnPlot 小提琴图 ──")
  log_msg("  参数: features =", paste(found_genes, collapse = ", "))
  log_msg("  参数: group.by =", vln_group_by)
  log_msg("  参数: pt.size  =", pt_size)
  log_msg("  参数: ncol     =", vln_ncol)
  log_msg("  参数: log      =", log_val)

  vln_args <- list(
    object   = seurat_obj,
    features = found_genes,
    group.by = vln_group_by,
    pt.size  = pt_size,
    ncol     = vln_ncol,
    log      = log_val
  )
  if (!is.null(split_by_col)) {
    vln_args$split.by <- split_by_col
  }

  vln_p <- do.call(VlnPlot, vln_args) 

  vln_file <- file.path(output_dir, paste0(project_name, "_marker_vln.pdf"))
  ggsave(vln_file, vln_p, width = vln_width, height = vln_height, dpi = dpi_val)
  log_msg("  输出图片:", vln_file)


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 4: DotPlot — 气泡图
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 4: DotPlot 气泡图 ──")
  log_msg("  参数: features  =", paste(found_genes, collapse = ", "))
  log_msg("  参数: group.by  =", vln_group_by)
  log_msg("  参数: dot.scale =", dot_scale)
  log_msg("  参数: col.min   =", col_min_val, ", col.max =", col_max_val)

  dot_args <- list(
    object   = seurat_obj,
    features = found_genes,
    group.by = vln_group_by,
    dot.scale = dot_scale,
    cluster.idents = cluster_idents
  )

  if (!is.null(cols_val)) {
    dot_args$cols <- cols_val
  }
  if (!is.null(col_min_val)) {
    dot_args$col.min <- col_min_val
  }
  if (!is.null(col_max_val)) {
    dot_args$col.max <- col_max_val
  }

  dot_p <- do.call(DotPlot, dot_args) +
    ggtitle(paste(project_name, "— 标记基因气泡图")) +
    theme(axis.text.x = element_text(angle = dot_angle, hjust = 1))

  dot_file <- file.path(output_dir, paste0(project_name, "_marker_dot.pdf"))
  ggsave(dot_file, dot_p, width = dot_width, height = dot_height, dpi = dpi_val)
  log_msg("  输出图片:", dot_file)


  sink()
  close(log_con)

  return(list(
    status          = "success",
    message         = "标记基因可视化完成",
    project         = project_name,
    marker_genes    = found_genes,
    missing_genes   = if (length(missing_genes) > 0) missing_genes else NULL,
    vln_file        = vln_file,
    dot_file        = dot_file,
    log_path        = log_path,
    cells           = ncol(seurat_obj)
  ))
}
