# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  08_heatmap.R —— 标记基因热图 (DoHeatmap)                                     ║
# ║  功能：展示每个细胞群的 Top N 标记基因热图                                       ║
# ║  读取：data/cell_annotation/seuratobject.json + cluster_markers.csv            ║
# ║  输出：data/heatmap/{project}_heatmap.pdf、日志、seuratobject.json             ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# ── 预设 JSON 格式（注释，供 Agent / Python tool 参考） ──
# {
#   "project": "scRNA_project",
#   "top_n": 5,
#   "group_by": "cell_type",
#   "size": 3,
#   "angle": 0,
#   "raster": false,
#   "disp_min": -2.5,
#   "disp_max": 2.5,
#   "draw_lines": true,
#   "lines_width": 0.5,
#   "group_bar": true,
#   "sample_n": null,
#   "dpi": 300,
#   "width": 12,
#   "height": 10
# }

library(Seurat)
library(ggplot2)
library(dplyr)


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║              集中默认参数（小鼠物种）                                          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

run_heatmap <- function(...) {
  json <- list(...)

  # ── 基础参数 ──
  project_name   <- "scRNA_project"
  input_dir      <- "/workspace/data/cell_annotation"
  output_dir     <- "/workspace/data/heatmap"

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

  object_json_path <- file.path(input_dir, "seuratobject.json")
  if (!file.exists(object_json_path)) {
    log_msg("  错误: 找不到", object_json_path)
    sink()
    close(log_con)
    return(list(status = "error", message = paste("细胞注释索引文件不存在:", object_json_path)))
  }

  obj_info <- jsonlite::fromJSON(object_json_path, simplifyVector = FALSE)
  rds_path <- obj_info$latest_rds_path
  log_msg("  加载 rds:", rds_path)

  seurat_obj <- readRDS(rds_path)
  log_msg("  细胞数:", ncol(seurat_obj))

  # 读取标记基因 CSV（由 04_cell_annotation.R 生成）
  marker_csv_path <- file.path(input_dir, paste0(project_name, "_cluster_markers.csv"))
  if (!file.exists(marker_csv_path)) {
    marker_csv_path <- file.path("/workspace/data/cell_annotation",
                                 paste0(project_name, "_cluster_markers.csv"))
  }
  if (!file.exists(marker_csv_path)) {
    log_msg("  错误: 找不到 cluster_markers.csv")
    sink()
    close(log_con)
    return(list(status = "error", message = "cluster_markers.csv 不存在，请先运行细胞注释"))
  }

  cluster_markers <- read.csv(marker_csv_path, stringsAsFactors = FALSE)
  log_msg("  标记基因表:", marker_csv_path)
  log_msg("  标记基因行数:", nrow(cluster_markers))
  log_msg("  列名:", paste(colnames(cluster_markers), collapse = ", "))


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 2: 提取 Top N 标记基因
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 2: 提取 Top", top_n, "标记基因 ──")

  # 识别 cluster 列（可能是 cluster 或 group）
  cluster_col <- intersect(c("cluster", "group"), colnames(cluster_markers))[1]
  gene_col    <- intersect(c("gene", "Gene", "gene_name"), colnames(cluster_markers))[1]

  if (is.na(cluster_col) || is.na(gene_col)) {
    log_msg("  错误: 无法识别 cluster 或 gene 列")
    sink()
    close(log_con)
    return(list(status = "error", message = "cluster_markers.csv 格式不兼容"))
  }

  top_genes <- cluster_markers %>%
    group_by(.data[[cluster_col]]) %>%
    slice_head(n = top_n) %>%
    pull(.data[[gene_col]]) %>%
    unique()

  log_msg("  Top", top_n, "基因数:", length(top_genes))
  log_msg("  基因:", paste(top_genes, collapse = ", "))


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 3: DoHeatmap 绘制
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 3: DoHeatmap 绘制 ──")
  log_msg("  参数: group.by   =", heatmap_group_by)
  log_msg("  参数: size       =", font_size)
  log_msg("  参数: angle      =", font_angle)
  log_msg("  参数: disp.min   =", disp_min, ", disp.max =", disp_max)
  log_msg("  参数: raster     =", raster_val)

  # 如果指定了抽样数量，随机抽取细胞
  plot_obj <- seurat_obj
  if (!is.null(sample_n_val) && sample_n_val < ncol(seurat_obj)) {
    sampled_cells <- sample(colnames(seurat_obj), sample_n_val)
    plot_obj <- subset(seurat_obj, cells = sampled_cells)
    log_msg("  随机抽样细胞:", sample_n_val, "/", ncol(seurat_obj))
  }

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

  heatmap_p <- do.call(DoHeatmap, hm_args) +
    scale_fill_viridis_c(option = "plasma") +
    ggtitle(paste(project_name, "— Top", top_n, "标记基因热图")) +
    theme(legend.position = "right")

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
