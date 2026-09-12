# 04_cell_annotation.R —— 单细胞标记基因识别与细胞类型注释
# ======================================================================
# 分析步骤：
#   1. 从 data/snn_cluster/seuratobject.json 读取 SNN 聚类输出的 Seurat 对象
#   2. FindAllMarkers — 寻找每个聚类的标记基因
#   3. 标记基因结果统计 + 保存 CSV
#   4. SingleR — 参考数据集自动注释细胞类型
#   5. 将注释结果写入 Seurat 对象元数据
#   6. DimPlot — 细胞类型注释 UMAP 可视化
#   7. 保存结果 + 更新 seuratobject.json
#
# 预设 JSON 入参格式（注释，非执行代码）：
# ┌─────────────────────────────────────────────────────────────────────┐
# │ {                                                                   │
# │   "input_dir": "/workspace/data/snn_cluster",                       │
# │   "output_dir": "/workspace/data/cell_annotation",                  │
# │   "project": "scRNA_project",                                       │
# │                                                                     │
# │   "species": "mouse",                                               │
# │                                                                     │
# │   "only_pos": true,                                                 │
# │   "min_pct": 0.25,                                                  │
# │   "logfc_threshold": 1,                                             │
# │   "marker_test_use": "wilcox",                                      │
# │   "max_cells_per_ident": null,                                      │
# │                                                                     │
# │   "top_n_markers": 5,                                               │
# │                                                                     │
# │   "singler_de_method": "classic",                                   │
# │   "singler_fine_tune": true,                                        │
# │                                                                     │
# │   "dimplot_group_by": "cell_type",                                  │
# │   "dimplot_pt_size": 0.3,                                           │
# │   "dimplot_label": true,                                            │
# │   "dimplot_label_size": 3,                                          │
# │   "dimplot_repel": true                                             │
# │ }                                                                   │
# └─────────────────────────────────────────────────────────────────────┘

library(Seurat)
library(ggplot2)
library(SingleR)
library(celldex)


run_cell_annotation <- function(...) {

  # ═══════════════════════════════════════════════════════════════════════
  # 〇、集中设置全部默认参数（小鼠物种）
  # ═══════════════════════════════════════════════════════════════════════

  # ── 输入 / 输出目录 ──
  input_dir   <- "/workspace/data/snn_cluster"
  output_dir  <- "/workspace/data/cell_annotation"
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  # ── 项目 ──
  project_name <- "scRNA_project"

  # ── 物种（决定 SingleR 参考数据集） ──
  species <- "mouse"

  # ── FindAllMarkers ──
  only_pos         <- TRUE
  min_pct          <- 0.25
  logfc_threshold  <- 0.25      # Seurat 官方默认值（1 太过严格，极易返回 0 行）
  marker_test_use   <- "wilcox"
  max_cells_per_ident <- NULL     # NULL = 不限，设 500/1000 可加速

  # ── 标记基因 Top N ──
  top_n_markers <- 5

  # ── SingleR ──
  singler_de_method  <- "classic"
  singler_fine_tune  <- TRUE

  # ── DimPlot ──
  dimplot_group_by   <- "cell_type"
  dimplot_pt_size    <- 0.3
  dimplot_label      <- TRUE
  dimplot_label_size <- 3
  dimplot_repel      <- TRUE

  # ── JSON 参数覆盖 ──
  json <- list(...)

  if (!is.null(json$input_dir))          input_dir            <- json$input_dir
  if (!is.null(json$output_dir))         output_dir           <- json$output_dir
  if (!is.null(json$project))            project_name         <- json$project

  if (!is.null(json$species))            species              <- json$species

  if (!is.null(json$only_pos))           only_pos             <- json$only_pos
  if (!is.null(json$min_pct))            min_pct              <- json$min_pct
  if (!is.null(json$logfc_threshold))    logfc_threshold      <- json$logfc_threshold
  if (!is.null(json$marker_test_use))    marker_test_use      <- json$marker_test_use
  if (!is.null(json$max_cells_per_ident)) max_cells_per_ident <- json$max_cells_per_ident

  if (!is.null(json$top_n_markers))      top_n_markers        <- json$top_n_markers

  if (!is.null(json$singler_de_method))  singler_de_method    <- json$singler_de_method
  if (!is.null(json$singler_fine_tune))  singler_fine_tune    <- json$singler_fine_tune

  if (!is.null(json$dimplot_group_by))   dimplot_group_by     <- json$dimplot_group_by
  if (!is.null(json$dimplot_pt_size))    dimplot_pt_size      <- json$dimplot_pt_size
  if (!is.null(json$dimplot_label))      dimplot_label        <- json$dimplot_label
  if (!is.null(json$dimplot_label_size)) dimplot_label_size   <- json$dimplot_label_size
  if (!is.null(json$dimplot_repel))      dimplot_repel        <- json$dimplot_repel

  # ── 日志 ──
  log_path <- file.path(output_dir, paste0(project_name, "_annotation.log"))
  log_con  <- file(log_path, open = "w")

  log_msg <- function(...) {
    line <- paste0("[ANNO] ", paste(..., collapse = " "))
    cat(line, "\n", file = log_con, append = TRUE)
    cat(line, "\n")
  }

  log_msg("========================================")
  log_msg("   单细胞标记基因识别与细胞类型注释")
  log_msg("========================================")
  log_msg("项目:", project_name)
  log_msg("物种:", species)
  log_msg("输入目录:", input_dir)
  log_msg("输出目录:", output_dir)
  log_msg("")


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 1: 读取 SNN 聚类输出的 Seurat 对象
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("── Step 1: 读取 SNN 聚类 Seurat 对象 ──")

  object_json_path <- file.path(input_dir, "seuratobject.json")
  if (!file.exists(object_json_path)) {
    log_msg("  错误: 找不到", object_json_path)
    close(log_con)
    return(list(status = "error", message = paste("SNN 聚类对象索引文件不存在:", object_json_path)))
  }

  obj_info <- jsonlite::fromJSON(object_json_path, simplifyVector = FALSE)
  rds_path <- obj_info$latest_rds_path
  log_msg("  读取对象索引:", object_json_path)
  log_msg("  RDS 路径:", rds_path)

  if (!file.exists(rds_path)) {
    log_msg("  错误: 找不到", rds_path)
    close(log_con)
    return(list(status = "error", message = paste("Seurat RDS 文件不存在:", rds_path)))
  }

  seurat_obj <- readRDS(rds_path)
  log_msg("  加载 Seurat 对象成功")
  log_msg("  细胞数:", ncol(seurat_obj), "  基因数:", nrow(seurat_obj))
  log_msg("  聚类数:", length(unique(seurat_obj$seurat_clusters)))

  # 修复1: 强制切回 RNA assay（防止上一步残留的 integrated assay 导致 Wilcoxon 失效）
  #DefaultAssay(seurat_obj) <- "RNA"
  #log_msg("  DefaultAssay → RNA")

  # 修复1b: 合并 RNA assay 的 split layers（Seurat V5 可能自动拆分 data 层）
  suppressWarnings(seurat_obj <- JoinLayers(seurat_obj, assay = "RNA"))
  log_msg("  RNA layers joined")

  # 修复2: 显式将 seurat_clusters 设为当前分组（防止 active.ident 仍是 orig.ident）
  #Idents(seurat_obj) <- seurat_obj$seurat_clusters
  #log_msg("  Idents ← seurat_clusters (", nlevels(seurat_obj), " 个聚类)")

  log_msg("  参数: input_dir =", input_dir, ", project =", project_name)


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 2: FindAllMarkers — 寻找每个聚类的标记基因
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 2: FindAllMarkers ──")

  marker_args <- list(
    object          = seurat_obj,
    only.pos        = only_pos,
    min.pct         = min_pct,
    logfc.threshold = logfc_threshold,
    test.use        = marker_test_use
  )
  if (!is.null(max_cells_per_ident)) {
    marker_args$max.cells.per.ident <- max_cells_per_ident
  }

  cluster_markers <- do.call(FindAllMarkers, marker_args)
  n_markers <- nrow(cluster_markers)
  log_msg("  标记基因识别完成: 共", n_markers, "个标记基因")

  # 保存 cluster_markers 为 RDS（供下游脚本读取）
  marker_rds_path <- file.path(output_dir, paste0(project_name, "_cluster_markers.rds"))
  saveRDS(cluster_markers, marker_rds_path)
  log_msg("  标记基因 RDS:", marker_rds_path)

  log_msg("  参数: only.pos =", only_pos,
          ", min.pct =", min_pct,
          ", logfc.threshold =", logfc_threshold,
          ", test.use =", marker_test_use,
          if (!is.null(max_cells_per_ident)) paste(", max.cells.per.ident =", max_cells_per_ident))


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 3: 标记基因结果统计 + 保存
  # ═══════════════════════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════════════════════
  #  Step 3: 标记基因结果统计 + 保存
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 3: 标记基因统计 + 保存 ──")

  # 加载 dplyr 包以使用管道操作
  suppressPackageStartupMessages(library(dplyr))

  # 保存完整的标记基因表到 CSV (优先保存全集，防止后续过滤覆盖原数据)
  csv_path <- file.path(output_dir, paste0(project_name, "_cluster_markers.csv"))
  write.csv(cluster_markers, csv_path, row.names = FALSE)
  log_msg("  标记基因 CSV:", csv_path)

  # 筛选显著性并提取 Top N 标记基因
  top_markers <- cluster_markers %>%
    filter(p_val_adj < 0.05) %>%                                    # 1. 严格要求校正后的 p 值显著
    group_by(cluster) %>%                                           # 2. 按聚类分组
    slice_max(n = top_n_markers, order_by = avg_log2FC, with_ties = FALSE) %>% # 3. 提取 log2FC 最高的前 N 个
    ungroup() %>%                                                   # 4. 解除分组
    as.data.frame()                                                 # 转回基础数据框以防万一

  # 日志输出 Top N 基因
  log_msg("  各聚类显著 Top", top_n_markers, "标记基因:")
  if (nrow(top_markers) > 0) {
    for (cl in unique(top_markers$cluster)) {
      genes <- top_markers$gene[top_markers$cluster == cl]
      log_msg("    Cluster", cl, ":", paste(genes, collapse = ", "))
    }
  } else {
    log_msg("    [警告] 未找到任何符合条件 (p_val_adj < 0.05) 的标记基因！")
  }

  log_msg("  参数: top_n =", top_n_markers)


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 4: SingleR — 参考数据集自动注释
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 4: SingleR 自动注释 ──")

  # 根据物种加载参考数据集
  if (tolower(species) == "human") {
    ref_data <- celldex::HumanPrimaryCellAtlasData()
    log_msg("  加载人类参考: HumanPrimaryCellAtlasData")
  } else {
    ref_data <- celldex::MouseRNAseqData()
    log_msg("  加载小鼠参考: MouseRNAseqData")
  }

  # 提取 log 标准化后的表达矩阵（SingleR 推荐用 data 层）
  expr_data <- GetAssayData(seurat_obj, assay = "RNA", layer = "data")

  # 运行 SingleR（按聚类注释，速度快）
  singleR_annot <- SingleR(
    test     = expr_data,
    ref      = ref_data,
    labels   = ref_data$label.main,
    clusters = seurat_obj$seurat_clusters,
    assay.type.test = "logcounts",
    assay.type.ref  = "logcounts",
    de.method       = singler_de_method,
    fine.tune       = singler_fine_tune
  )

  log_msg("  SingleR 注释完成")
  log_msg("  预测细胞类型:")
  for (i in seq_along(singleR_annot$labels)) {
    log_msg("    Cluster", names(singleR_annot$labels)[i],
            "→", singleR_annot$labels[i])
  }

  log_msg("  参数: de.method =", singler_de_method,
          ", fine.tune =", singler_fine_tune,
          ", species =", species)


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 5: 将注释结果写入 Seurat 对象
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 5: 写入注释结果 ──")

  # 将每个聚类的预测标签映射到每个细胞
  cluster_labels <- singleR_annot$labels
  names(cluster_labels) <- rownames(singleR_annot)
  seurat_obj$cell_type <- unname(cluster_labels[as.character(seurat_obj$seurat_clusters)])

  # 统计各细胞类型数量
  celltype_table <- table(seurat_obj$cell_type)
  log_msg("  细胞类型分布:")
  for (ct in names(celltype_table)) {
    log_msg("    ", ct, ":", celltype_table[ct], "个细胞")
  }


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 6: DimPlot — 细胞类型 UMAP 可视化
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 6: DimPlot 细胞类型可视化 ──")

  celltype_p <- DimPlot(
    seurat_obj,
    reduction  = "umap",
    group.by   = dimplot_group_by,
    pt.size    = dimplot_pt_size,
    label      = dimplot_label,
    label.size = dimplot_label_size,
    repel      = dimplot_repel
  ) + ggtitle(paste(project_name, "— 细胞类型注释 (SingleR,", species, ")"))

  celltype_file <- file.path(output_dir, paste0(project_name, "_umap_celltype.pdf"))
  ggsave(celltype_file, celltype_p, width = 10, height = 8, dpi = 300)
  log_msg("  UMAP 细胞类型图:", celltype_file)

  log_msg("  参数: group.by =", dimplot_group_by,
          ", pt.size =", dimplot_pt_size,
          ", label =", dimplot_label,
          ", label.size =", dimplot_label_size,
          ", repel =", dimplot_repel)


  # ═══════════════════════════════════════════════════════════════════════
  #  保存结果 + 日志收尾 + 返回值
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── 保存结果 ──")

  rds_path <- file.path(output_dir, paste0(project_name, "_annotated.rds"))
  saveRDS(seurat_obj, file = rds_path)
  log_msg("  Seurat 对象:", rds_path)

  # ── 保存 seuratobject.json ──
  object_json <- file.path(output_dir, "seuratobject.json")
  object_info <- list(
    latest_rds      = basename(rds_path),
    latest_rds_path = rds_path,
    project         = project_name,
    created_at      = as.character(Sys.time()),
    cells           = ncol(seurat_obj),
    cell_types      = as.list(celltype_table),
    species         = species,
    reductions      = Reductions(seurat_obj)
  )
  jsonlite::write_json(object_info, object_json, pretty = TRUE, auto_unbox = TRUE)
  log_msg("  对象索引:", object_json)

  log_msg("")
  log_msg("  细胞类型注释完成。")
  log_msg("========================================")

  close(log_con)

  return(list(
    status         = "success",
    message        = paste("细胞类型注释完成，共", length(celltype_table), "种细胞类型，",
                           ncol(seurat_obj), "个细胞"),
    project        = project_name,
    species        = species,
    n_markers      = n_markers,
    cell_types     = names(celltype_table),
    celltype_table = as.list(celltype_table),
    cells          = ncol(seurat_obj),
    rds_path       = rds_path,
    object_json    = object_json,
    csv_path       = csv_path,
    log_path       = log_path,
    figures = list(
      umap_celltype = celltype_file
    )
  ))
}
