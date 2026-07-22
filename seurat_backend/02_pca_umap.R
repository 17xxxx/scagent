# 02_pca_umap.R —— 单细胞降维与可视化分析
# ======================================================================
# 分析步骤：
#   1. 从 data/qc/object.json 读取 QC 输出的 Seurat 对象
#   2. 自动检测可用降维方法（harmony > pca）
#   3. ElbowPlot — 评估最优主成分数
#   4. RunUMAP — 非线性降维
#   5. RunTSNE — 可选，非线性降维
#   6. DimPlot — UMAP 可视化
#   7. 保存结果 + 更新 seuratobject.json
#
# 预设 JSON 入参格式（注释，非执行代码）：
# ┌─────────────────────────────────────────────────────────────────────┐
# │ {                                                                   │
# │   "qc_dir": "/workspace/data/qc",                                   │
# │   "output_dir": "/workspace/data/pca_umap",                         │
# │   "project": "scRNA_project",                                       │
# │                                                                     │
# │   "elbow_ndims": 50,                                                │
# │   "elbow_reduction": "pca",                                         │
# │                                                                     │
# │   "umap_dims": "1:15",                                              │
# │   "umap_n_neighbors": 30,                                           │
# │   "umap_min_dist": 0.3,                                             │
# │   "umap_seed": 42,                                                  │
# │                                                                     │
# │   "run_tsne": true,                                                 │
# │   "tsne_dims": "1:15",                                              │
# │   "tsne_perplexity": 30,                                            │
# │   "tsne_seed": 42,                                                  │
# │                                                                     │
# │   "dimplot_group_by": "orig.ident",                                 │
# │   "dimplot_pt_size": 0.3                                            │
# │ }                                                                   │
# └─────────────────────────────────────────────────────────────────────┘

library(Seurat)
library(ggplot2)


run_pca_umap_analysis <- function(...) {

  # ═══════════════════════════════════════════════════════════════════════
  # 〇、集中设置全部默认参数
  # ═══════════════════════════════════════════════════════════════════════

  # ── 输入 / 输出目录 ──
  qc_dir      <- "/workspace/data/qc"
  output_dir  <- "/workspace/data/pca_umap"
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  # ── 项目 ──
  project_name <- "scRNA_project"

  # ── ElbowPlot ──
  elbow_ndims     <- 50
  elbow_reduction <- "pca"

  # ── RunUMAP ──
  umap_dims        <- "1:15"
  umap_n_neighbors  <- 30
  umap_min_dist     <- 0.3
  umap_seed         <- 42

  # ── RunTSNE ──
  # run_tsne       <- TRUE
  # tsne_dims      <- "1:15"
  # tsne_perplexity <- 30
  # tsne_seed       <- 42

  # ── DimPlot ──
  dimplot_group_by <- "orig.ident"
  dimplot_pt_size  <- 0.3

  # ── JSON 参数覆盖 ──
  json <- list(...)

  if (!is.null(json$qc_dir))           qc_dir            <- json$qc_dir
  if (!is.null(json$output_dir))       output_dir        <- json$output_dir
  if (!is.null(json$project))          project_name      <- json$project

  if (!is.null(json$elbow_ndims))      elbow_ndims       <- json$elbow_ndims
  if (!is.null(json$elbow_reduction))  elbow_reduction   <- json$elbow_reduction

  if (!is.null(json$umap_dims))        umap_dims         <- json$umap_dims
  if (!is.null(json$umap_n_neighbors)) umap_n_neighbors  <- json$umap_n_neighbors
  if (!is.null(json$umap_min_dist))    umap_min_dist     <- json$umap_min_dist
  if (!is.null(json$umap_seed))        umap_seed         <- json$umap_seed

  # if (!is.null(json$run_tsne))         run_tsne          <- json$run_tsne
  # if (!is.null(json$tsne_dims))        tsne_dims         <- json$tsne_dims
  # if (!is.null(json$tsne_perplexity))  tsne_perplexity   <- json$tsne_perplexity
  # if (!is.null(json$tsne_seed))        tsne_seed         <- json$tsne_seed

  if (!is.null(json$dimplot_group_by)) dimplot_group_by  <- json$dimplot_group_by
  if (!is.null(json$dimplot_pt_size))  dimplot_pt_size   <- json$dimplot_pt_size

  # 解析 dims 字符串 → 整数向量
  umap_dims_vec  <- eval(parse(text = umap_dims))
  # tsne_dims_vec  <- eval(parse(text = tsne_dims))

  # ── 日志 ──
  log_path <- file.path(output_dir, paste0(project_name, "_pca_umap.log"))
  log_con  <- file(log_path, open = "w")

  log_msg <- function(...) {
    line <- paste0("[PCA-UMAP] ", paste(..., collapse = " "))
    cat(line, "\n", file = log_con, append = TRUE)
    cat(line, "\n")
  }

  log_msg("========================================")
  log_msg("   单细胞降维与可视化分析")
  log_msg("========================================")
  log_msg("项目:", project_name)
  log_msg("QC 目录:", qc_dir)
  log_msg("输出目录:", output_dir)
  log_msg("")


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 1: 读取 QC 输出的 Seurat 对象
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("── Step 1: 读取 QC Seurat 对象 ──")

  object_json_path <- file.path(qc_dir, "object.json")
  if (!file.exists(object_json_path)) {
    log_msg("  错误: 找不到", object_json_path)
    close(log_con)
    return(list(status = "error", message = paste("QC 对象索引文件不存在:", object_json_path)))
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
  log_msg("")

  log_msg("  参数: qc_dir =", qc_dir, ", project =", project_name)


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 2: 检测可用降维方法
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("── Step 2: 检测可用降维 ──")

  available_reductions <- Reductions(seurat_obj)
  log_msg("  可用降维:", paste(available_reductions, collapse = ", "))

  if ("harmony" %in% available_reductions) {
    reduction_use <- "harmony"
    log_msg("  → 使用 Harmony 降维结果")
  } else if ("pca" %in% available_reductions) {
    reduction_use <- "pca"
    log_msg("  → 使用 PCA 降维结果")
  } else {
    log_msg("  错误: 未找到 pca 或 harmony 降维结果，请先运行 QC")
    close(log_con)
    return(list(status = "error", message = "Seurat 对象中无 pca/harmony 降维结果"))
  }


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 3: ElbowPlot — 评估主成分
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 3: ElbowPlot ──")

  elbow_p <- ElbowPlot(
    seurat_obj,
    ndims     = elbow_ndims,
    reduction = elbow_reduction
  ) + ggtitle(paste(project_name, "— Elbow Plot"))

  elbow_file <- file.path(output_dir, paste0(project_name, "_elbow.pdf"))
  ggsave(elbow_file, elbow_p, width = 8, height = 6, dpi = 300)
  log_msg("  ElbowPlot 已保存:", elbow_file)

  log_msg("  参数: ndims =", elbow_ndims, ", reduction =", elbow_reduction)


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 4: RunUMAP
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 4: RunUMAP ──")

  seurat_obj <- RunUMAP(
    object     = seurat_obj,
    reduction  = reduction_use,
    dims       = umap_dims_vec,
    n.neighbors = umap_n_neighbors,
    min.dist   = umap_min_dist,
    seed.use   = umap_seed,
    verbose    = FALSE
  )
  log_msg("  UMAP 完成")

  log_msg("  参数: reduction =", reduction_use,
          ", dims =", umap_dims,
          ", n.neighbors =", umap_n_neighbors,
          ", min.dist =", umap_min_dist,
          ", seed =", umap_seed)


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 5: RunTSNE（已注释）
  # ═══════════════════════════════════════════════════════════════════════
  # log_msg("")
  # log_msg("── Step 5: RunTSNE ──")
  #
  # if (run_tsne) {
  #   seurat_obj <- RunTSNE(
  #     object     = seurat_obj,
  #     reduction  = reduction_use,
  #     dims       = tsne_dims_vec,
  #     perplexity = tsne_perplexity,
  #     seed.use   = tsne_seed,
  #     verbose    = FALSE
  #   )
  #   log_msg("  tSNE 完成")
  #
  #   log_msg("  参数: reduction =", reduction_use,
  #           ", dims =", tsne_dims,
  #           ", perplexity =", tsne_perplexity,
  #           ", seed =", tsne_seed)
  # } else {
  #   log_msg("  已跳过 (run_tsne = FALSE)")
  # }


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 6: DimPlot — UMAP 可视化
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 6: DimPlot 可视化 ──")

  umap_p <- DimPlot(
    seurat_obj,
    reduction = "umap",
    group.by  = dimplot_group_by,
    pt.size   = dimplot_pt_size,
    label     = FALSE
  ) + ggtitle(paste(project_name, "— UMAP (", reduction_use, ")"))

  umap_file <- file.path(output_dir, paste0(project_name, "_umap.pdf"))
  ggsave(umap_file, umap_p, width = 8, height = 6, dpi = 300)
  log_msg("  UMAP 图已保存:", umap_file)

  # # tSNE 图（已注释）
  # if (run_tsne) {
  #   tsne_p <- DimPlot(
  #     seurat_obj,
  #     reduction = "tsne",
  #     group.by  = dimplot_group_by,
  #     pt.size   = dimplot_pt_size,
  #     label     = FALSE
  #   ) + ggtitle(paste(project_name, "— tSNE"))
  #
  #   tsne_file <- file.path(output_dir, paste0(project_name, "_tsne.pdf"))
  #   ggsave(tsne_file, tsne_p, width = 8, height = 6, dpi = 300)
  #   log_msg("  tSNE 图已保存:", tsne_file)
  # }

  log_msg("  参数: group.by =", dimplot_group_by,
          ", pt.size =", dimplot_pt_size)


  # ═══════════════════════════════════════════════════════════════════════
  #  保存结果 + 日志收尾 + 返回值
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── 保存结果 ──")

  rds_path <- file.path(output_dir, paste0(project_name, "_pca_umap.rds"))
  saveRDS(seurat_obj, file = rds_path)
  log_msg("  Seurat 对象:", rds_path)

  # ── 保存 seuratobject.json：记录本次运行的 RDS 路径，供后续工具读取 ──
  object_json <- file.path(output_dir, "seuratobject.json")
  object_info <- list(
    latest_rds      = basename(rds_path),
    latest_rds_path = rds_path,
    project         = project_name,
    created_at      = as.character(Sys.time()),
    cells           = ncol(seurat_obj),
    reductions      = Reductions(seurat_obj)
  )
  jsonlite::write_json(object_info, object_json, pretty = TRUE, auto_unbox = TRUE)
  log_msg("  对象索引:", object_json)

  log_msg("")
  log_msg("  降维分析完成。")
  log_msg("========================================")

  close(log_con)

  return(list(
    status          = "success",
    message         = paste("PCA/UMAP 分析完成，", ncol(seurat_obj), "个细胞"),
    project         = project_name,
    reduction_use   = reduction_use,
    cells           = ncol(seurat_obj),
    rds_path        = rds_path,
    object_json     = object_json,
    log_path        = log_path,
    figures = list(
      elbow = elbow_file,
      umap  = umap_file
      # tsne  = if (run_tsne) tsne_file else NULL
    )
  ))
}
