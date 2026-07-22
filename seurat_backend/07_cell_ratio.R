# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  07_cell_ratio.R —— 细胞类型比例可视化 (堆叠柱状图)                            ║
# ║  功能：按样本/条件统计细胞类型比例，绘制堆叠柱状图                                 ║
# ║  读取：data/cell_annotation/seuratobject.json                                 ║
# ║  输出：data/cell_ratio/{project}_ratio.pdf、_counts.csv、日志、seuratobject     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# ── 预设 JSON 格式（注释，供 Agent / Python tool 参考） ──
# {
#   "project": "scRNA_project",
#   "group_by_sample": "orig.ident",
#   "group_by_celltype": "cell_type",
#   "position": "stack",
#   "width": 0.7,
#   "custom_colors": null,
#   "dpi": 300,
#   "width_pic": 10,
#   "height_pic": 6,
#   "angle": 45
# }

library(Seurat)
library(ggplot2)
library(dplyr)


# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║              集中默认参数（小鼠物种）                                          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

run_cell_ratio <- function(...) {
  json <- list(...)

  # ── 基础参数 ──
  project_name      <- "scRNA_project"
  input_dir         <- "/workspace/data/cell_annotation"
  output_dir        <- "/workspace/data/cell_ratio"

  # ── 柱状图参数 ──
  sample_col        <- "orig.ident"
  celltype_col      <- "cell_type"
  position_val      <- "stack"   # stack / fill
  bar_width         <- 0.7
  custom_colors     <- NULL
  dpi_val           <- 300
  width_pic         <- 10
  height_pic        <- 6
  angle_val         <- 45

  # ── JSON 覆盖默认值 ──
  if (!is.null(json$project))          project_name  <- json$project
  if (!is.null(json$group_by_sample))  sample_col    <- json$group_by_sample
  if (!is.null(json$group_by_celltype)) celltype_col <- json$group_by_celltype
  if (!is.null(json$position))         position_val  <- json$position
  if (!is.null(json$width))            bar_width     <- json$width
  if (!is.null(json$custom_colors))    custom_colors <- json$custom_colors
  if (!is.null(json$dpi))              dpi_val       <- json$dpi
  if (!is.null(json$width_pic))        width_pic     <- json$width_pic
  if (!is.null(json$height_pic))       height_pic    <- json$height_pic
  if (!is.null(json$angle))            angle_val     <- json$angle

  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  # ── 日志系统 ──
  log_path <- file.path(output_dir, paste0(project_name, "_cell_ratio.log"))
  log_con  <- file(log_path, open = "wt")
  sink(log_con, append = TRUE, split = TRUE)
  log_msg <- function(...) {
    cat(paste0("[", Sys.time(), "] "), ..., "\n", sep = "")
  }

  log_msg("══════════ 细胞类型比例可视化开始 ══════════")
  log_msg("项目:", project_name)


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 1: 读取 Seurat 对象
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 1: 读取 Seurat 对象 ──")

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
  log_msg("  基因数:", nrow(seurat_obj))

  # ── 检查必需的 meta.data 列是否存在 ──
  meta_cols <- colnames(seurat_obj@meta.data)
  if (!(sample_col %in% meta_cols)) {
    log_msg("  错误: meta.data 中不存在列 '", sample_col, "'")
    sink()
    close(log_con)
    return(list(status = "error", message = paste("meta.data 中不存在列:", sample_col)))
  }
  if (!(celltype_col %in% meta_cols)) {
    log_msg("  错误: meta.data 中不存在列 '", celltype_col, "'")
    sink()
    close(log_con)
    return(list(status = "error", message = paste("meta.data 中不存在列:", celltype_col)))
  }


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 2: 计算细胞类型比例
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 2: 计算细胞类型比例 ──")
  log_msg("  参数: group_by_sample   =", sample_col)
  log_msg("  参数: group_by_celltype =", celltype_col)
  log_msg("  参数: position          =", position_val)
  log_msg("  参数: bar_width         =", bar_width)

  cell_ratio_data <- seurat_obj@meta.data %>%
    group_by(.data[[sample_col]], .data[[celltype_col]]) %>%
    summarise(count = n(), .groups = "drop_last") %>%
    mutate(ratio = count / sum(count) * 100)

  log_msg("  样本-细胞类型组合数:", nrow(cell_ratio_data))
  for (s in unique(cell_ratio_data[[sample_col]])) {
    sub_data <- cell_ratio_data[cell_ratio_data[[sample_col]] == s, ]
    log_msg("  ", s, ": ", nrow(sub_data), "种细胞类型")
  }

  # 保存比例表到 CSV
  csv_path <- file.path(output_dir, paste0(project_name, "_cell_ratio.csv"))
  write.csv(as.data.frame(cell_ratio_data), csv_path, row.names = FALSE)
  log_msg("  比例表 CSV:", csv_path)


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 3: 绘制堆叠柱状图
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 3: 绘制堆叠柱状图 ──")

  # 使用 ratio（百分比）作为 y 轴，position=stack 即可展示各细胞类型比例
  p <- ggplot(
    cell_ratio_data,
    aes(x = .data[[sample_col]], y = ratio, fill = .data[[celltype_col]])
  ) +
    geom_col(position = position_val, width = bar_width) +
    labs(
      x     = sample_col,
      y     = if (position_val == "fill") "Fraction" else "Cell Ratio (%)",
      fill  = celltype_col,
      title = paste(project_name, "— 细胞类型比例")
    ) +
    theme_classic() +
    theme(
      axis.text.x = element_text(angle = angle_val, hjust = 1),
      legend.position = "right"
    )

  if (!is.null(custom_colors) && length(custom_colors) > 0) {
    p <- p + scale_fill_manual(values = unlist(custom_colors))
  }

  ratio_file <- file.path(output_dir, paste0(project_name, "_cell_ratio.pdf"))
  ggsave(ratio_file, p, width = width_pic, height = height_pic, dpi = dpi_val)
  log_msg("  输出图片:", ratio_file)


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 4: 保存 seuratobject.json
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 4: 保存对象索引 ──")

  new_rds <- file.path(output_dir, paste0(project_name, "_cell_ratio.rds"))
  saveRDS(seurat_obj, new_rds)
  log_msg("  rds 保存:", new_rds)

  object_json <- file.path(output_dir, "seuratobject.json")
  object_info <- list(
    latest_rds      = paste0(project_name, "_cell_ratio.rds"),
    latest_rds_path = new_rds,
    project         = project_name,
    created_at      = Sys.time(),
    cells           = ncol(seurat_obj),
    sample_col      = sample_col,
    celltype_col    = celltype_col
  )
  jsonlite::write_json(object_info, object_json, pretty = TRUE, auto_unbox = TRUE)
  log_msg("  对象索引:", object_json)

  # ── 各样本细胞类型数量汇总 ──
  total_counts <- seurat_obj@meta.data %>%
    group_by(.data[[sample_col]]) %>%
    summarise(total_cells = n(), .groups = "drop")

  sink()
  close(log_con)

  return(list(
    status          = "success",
    message         = "细胞类型比例可视化完成",
    project         = project_name,
    ratio_file      = ratio_file,
    ratio_csv       = csv_path,
    rds_path        = new_rds,
    object_json     = object_json,
    log_path        = log_path,
    cells           = ncol(seurat_obj),
    sample_summary  = as.list(total_counts)
  ))
}
