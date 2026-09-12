# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  08_heatmap.R —— 标记基因热图 (DoHeatmap)                                     ║
# ║  功能：展示每个细胞群的 Top N 标记基因热图                                       ║
# ║  读取：data/cell_annotation/seuratobject.json + cluster_markers.rds            ║
# ║  输出：data/heatmap/{project}_heatmap.pdf、日志、seuratobject.json             ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

library(Seurat)
library(ggplot2)
library(dplyr)

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

run_heatmap <- function(...) {
  json <- list(...)

  # ── 基础参数 ──
  project_name   <- "scRNA_project"
  input_dir      <- scagent_step_dir("cell_annotation")
  output_dir     <- scagent_step_dir("heatmap")

  # ── DoHeatmap 参数 ──
  top_n          <- 5
  heatmap_group_by <- "cell_type"
  font_size      <- 3
  font_angle     <- 0
  raster_val     <- FALSE
  disp_min       <- -2.5
  disp_max       <- 2.5
  draw_lines_val <- TRUE
  lines_width    <- 0.5
  group_bar_val  <- TRUE
  sample_n_val   <- NULL       # NULL = 使用全部细胞，数值 = 随机抽取

  # ── 图像输出参数 ──
  dpi_val        <- 300
  width_val      <- 12
  height_val     <- 10

  # ── JSON 覆盖默认值 ──
  if (!is.null(json$project))     project_name    <- json$project
  if (!is.null(json$top_n))       top_n           <- json$top_n
  if (!is.null(json$group_by))    heatmap_group_by <- json$group_by
  if (!is.null(json$size))        font_size       <- json$size
  if (!is.null(json$angle))       font_angle      <- json$angle
  if (!is.null(json$raster))      raster_val      <- json$raster
  if (!is.null(json$disp_min))    disp_min        <- json$disp_min
  if (!is.null(json$disp_max))    disp_max        <- json$disp_max
  if (!is.null(json$draw_lines))  draw_lines_val  <- json$draw_lines
  if (!is.null(json$lines_width)) lines_width     <- json$lines_width
  if (!is.null(json$group_bar))   group_bar_val   <- json$group_bar
  if (!is.null(json$sample_n))    sample_n_val    <- json$sample_n
  if (!is.null(json$dpi))         dpi_val         <- json$dpi
  if (!is.null(json$width))       width_val       <- json$width
  if (!is.null(json$height))      height_val      <- json$height

  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  # ── 日志系统 ──
  log_path <- file.path(output_dir, paste0(project_name, "_heatmap.log"))
  log_con  <- file(log_path, open = "wt")
  sink(log_con, append = TRUE, split = TRUE)
  log_msg <- function(...) {
    cat(paste0("[", Sys.time(), "] "), ..., "\n", sep = "")
  }

  log_msg("══════════ 标记基因热图开始 ══════════")
  log_msg("项目:", project_name)


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 1: 读取 Seurat 对象 + 标记基因表
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 1: 读取数据 ──")

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

  # 2. 读 cluster_markers (放宽条件：不再强依赖 project_name，直接在目录下寻找后缀匹配的文件)
  # 使用正则匹配以 "cluster_markers.rds" 结尾的文件
  marker_rds_files <- list.files(path = input_dir, pattern = "cluster_markers\\.rds$", full.names = TRUE)
  
  if (length(marker_rds_files) == 0) {
    log_msg("  [致命错误] 在 ", input_dir, " 目录下找不到任何 cluster_markers.rds 文件")
    sink(); close(log_con)
    return(list(status = "error", message = "cluster_markers.rds 不存在，请先运行上游标记基因分析"))
  }
  
  # 如果意外找到多个文件，给出警告并默认使用第一个
  if (length(marker_rds_files) > 1) {
    log_msg("  [警告] 找到多个 marker 文件，将默认使用第一个。")
  }
  
  marker_rds_path <- marker_rds_files[1]
  cluster_markers <- readRDS(marker_rds_path)
  log_msg("  加载标记基因表:", marker_rds_path, " (行数: ", nrow(cluster_markers), ")")


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 2: 提取 Top N 标记基因
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 2: 提取 Top", top_n, "标记基因 ──")

# 检查必需的列是否存在
  if (!all(c("cluster", "gene") %in% colnames(cluster_markers))) {
    log_msg("  [致命错误] RDS 数据框缺失 'cluster' 或 'gene' 列")
    sink(); close(log_con)
    return(list(status = "error", message = "标记基因对象格式有误"))
  }

  # 1. 提取 【Top N】 基因，仅用于画图
  top_genes <- cluster_markers %>%
    group_by(cluster) %>%
    slice_head(n = top_n) %>%
    pull(gene) %>%
    unique()
  valid_top_genes <- intersect(top_genes, rownames(seurat_obj))
  log_msg("  用于作图的有效 Top", top_n, "基因数: ", length(valid_top_genes))

  # 2. 提取 【所有】 标记基因，用于 ScaleData（防止局部方差计算崩溃）
  all_marker_genes <- intersect(unique(cluster_markers$gene), rownames(seurat_obj))
  log_msg("  正在为", length(all_marker_genes), "个全部 Marker 重新计算 ScaleData...")
  
  # 使用 suppressWarnings 屏蔽 Seurat V5 常规提示
  plot_obj <- ScaleData(seurat_obj, features = all_marker_genes, verbose = FALSE)
  

  # ═══════════════════════════════════════════════════════════════════════
  #  Step 3: DoHeatmap 绘制
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 3: DoHeatmap 绘制 ──")
  
  if (length(valid_top_genes) == 0) {
    log_msg("  [致命错误] 无效的基因列表，无法出图")
    sink(); close(log_con)
    return(list(status = "error", message = "提取的标记基因均不在 Seurat 对象内"))
  }

  log_msg("  正在执行 DoHeatmap...")
  
  # ==========================================

  # 标准绘图参数
  hm_args <- list(
    object    = plot_obj,
    features  = top_genes,
    group.by  = heatmap_group_by,
    size      = font_size,
    angle     = font_angle,
    raster    = raster_val,
    disp.min  = disp_min,
    disp.max  = disp_max,
    lines.width = lines_width,
    group.bar   = group_bar_val,
    draw.lines  = draw_lines_val
  )
  
  log_msg("  正在生成热图 (DoHeatmap)...")
  
# 废弃复杂的 do.call 和高风险参数，直接原生调用
  heatmap_p <- DoHeatmap(
    object   = plot_obj,
    features = valid_top_genes,
    group.by = heatmap_group_by,
    size     = font_size,
    angle    = font_angle,
    raster   = raster_val
  ) 
  
  heatmap_file <- file.path(output_dir, paste0(project_name, "_markers_heatmap.pdf"))
  ggsave(heatmap_file, heatmap_p, width = width_val, height = height_val, dpi = dpi_val)
  log_msg("  输出图片:", heatmap_file)

  sink()
  close(log_con)

  return(list(
    status          = "success",
    message         = "标记基因热图完成",
    project         = project_name,
    top_n           = top_n,
    genes_used      = top_genes,
    heatmap_file    = heatmap_file,
    log_path        = log_path,
    cells           = ncol(seurat_obj)
  ))
}