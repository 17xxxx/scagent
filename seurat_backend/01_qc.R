# 01_qc.R —— 单细胞 RNA-seq 全流程质控分析
# ======================================================================
# 共 8 个分析步骤：
#   1. 数据导入（Read10X → CreateSeuratObject）
#   2. 添加细胞元数据（线粒体% + 核糖体%）
#   3. QC 可视化（小提琴图 + 散点图）
#   4. 过滤 + 多样本合并（subset → merge → 生成 batch 列）
#   5. 归一化 + 高变基因筛选
#   6. 高变基因可视化
#   7. 标准化（Scaling）+ 线粒体回归
#   8. PCA + Harmony 批次校正
#
# 预设 JSON 入参格式（注释，非执行代码）：
# ┌─────────────────────────────────────────────────────────────────────┐
# │ {                                                                   │
# │   "samples": {                                                      │
# │     "sample_A": "/workspace/data/rawdata/sample_A",                 │
# │     "sample_B": "/workspace/data/rawdata/sample_B"                  │
# │   },                                                                │
# │   "project": "scRNA_project",                                       │
# │                                                                     │
# │   "species": "mouse",                                               │
# │   "mito_pattern": "^mt-",                                           │
# │   "ribo_pattern": "^Rp[sl]",                                        │
# │                                                                     │
# │   "gene_column": 2,                                                 │
# │   "unique_features": true,                                          │
# │   "strip_suffix": false,                                            │
# │   "assay_name": "RNA",                                              │
# │                                                                     │
# │   "min_cells": 3,                                                   │
# │   "min_features": 200,                                              │
# │   "nfeature_rna_low": 200,                                          │
# │   "nfeature_rna_high": 6000,                                        │
# │   "percent_mt_max": 5,                                              │
# │   "percent_ribo_min": 10,                                           │
# │                                                                     │
# │   "merge_data": false,                                              │
# │                                                                     │
# │   "norm_method": "LogNormalize",                                    │
# │   "scale_factor": 10000,                                            │
# │                                                                     │
# │   "var_method": "vst",                                              │
# │   "nfeatures_var": 2000,                                            │
# │   "vst_clip_max": "auto",                                           │
# │                                                                     │
# │   "model_use": "linear",                                            │
# │   "do_scale": true,                                                 │
# │   "do_center": true,                                                │
# │   "scale_max": 10,                                                  │
# │                                                                     │
# │   "npcs": 50,                                                       │
# │   "weight_by_var": true,                                            │
# │                                                                     │
# │   "run_harmony": true,                                              │
# │   "harmony_group_by_vars": "batch",                                 │
# │   "harmony_dims_use": "1:30",                                       │
# │   "harmony_theta": 2,                                               │
# │   "harmony_lambda": 1,                                              │
# │   "harmony_sigma": 0.1,                                             │
# │   "harmony_max_iter_harmony": 10,                                   │
# │   "harmony_max_iter_cluster": 20                                    │
# │ }                                                                   │
# └─────────────────────────────────────────────────────────────────────┘

library(Seurat)
library(ggplot2)
library(harmony)

run_quality_control <- function(...) {

  # ═══════════════════════════════════════════════════════════════════════
  # 〇、集中设置全部默认参数（小鼠物种）
  # ═══════════════════════════════════════════════════════════════════════

  # ── 输出目录 ──
  qc_dir <- "/workspace/data/qc"
  dir.create(qc_dir, showWarnings = FALSE, recursive = TRUE)

  # ── 样本与项目 ──
  samples      <- list()           # list(sample_name = data_path, ...)
  project_name <- "scRNA_project"

  # ── 物种（默认: 小鼠） ──
  species      <- "mouse"
  mito_pattern <- "^mt-"
  ribo_pattern <- "^Rp[sl]"

  # ── Read10X ──
  gene_column      <- 2L
  unique_features  <- TRUE
  strip_suffix     <- FALSE

  # ── CreateSeuratObject ──
  min_cells    <- 3
  min_features <- 200
  assay_name   <- "RNA"

  # ── QC 过滤 ──
  nfeature_rna_low  <- 200
  nfeature_rna_high <- 6000
  percent_mt_max    <- 5
  percent_ribo_min  <- 10

  # ── merge ──
  merge_data <- FALSE

  # ── NormalizeData ──
  norm_method  <- "LogNormalize"
  scale_factor <- 10000

  # ── FindVariableFeatures ──
  var_method     <- "vst"
  nfeatures_var  <- 2000
  vst_clip_max   <- "auto"

  # ── ScaleData ──
  vars_to_regress <- "percent.mt"
  model_use       <- "linear"
  do_scale        <- TRUE
  do_center       <- TRUE
  scale_max       <- 10

  # ── RunPCA ──
  npcs           <- 50
  weight_by_var  <- TRUE

  # ── RunHarmony ──
  run_harmony             <- TRUE
  harmony_group_by_vars   <- "batch"
  harmony_dims_use        <- "1:30"
  harmony_theta           <- 2
  harmony_lambda          <- 1
  harmony_sigma           <- 0.1
  harmony_max_iter_harmony <- 10
  harmony_max_iter_cluster <- 20

  # ── JSON 参数覆盖 ──
  # api.R 通过 do.call(fn, params) 调用，params 的每个元素都成为 ... 的单独命名参数
  # 因此 list(...) 直接就是平铺的 JSON 结构，无需再解包
  json <- list(...)

  if (!is.null(json$samples))          samples          <- json$samples
  if (!is.null(json$project))          project_name     <- json$project

  if (!is.null(json$species))          species          <- json$species
  if (!is.null(json$mito_pattern))     mito_pattern     <- json$mito_pattern
  if (!is.null(json$ribo_pattern))     ribo_pattern     <- json$ribo_pattern

  if (!is.null(json$gene_column))      gene_column      <- json$gene_column
  if (!is.null(json$unique_features))  unique_features  <- json$unique_features
  if (!is.null(json$strip_suffix))     strip_suffix     <- json$strip_suffix

  if (!is.null(json$min_cells))        min_cells        <- json$min_cells
  if (!is.null(json$min_features))     min_features     <- json$min_features
  if (!is.null(json$assay_name))       assay_name       <- json$assay_name

  if (!is.null(json$nfeature_rna_low))  nfeature_rna_low  <- json$nfeature_rna_low
  if (!is.null(json$nfeature_rna_high)) nfeature_rna_high <- json$nfeature_rna_high
  if (!is.null(json$percent_mt_max))    percent_mt_max    <- json$percent_mt_max
  if (!is.null(json$percent_ribo_min))  percent_ribo_min  <- json$percent_ribo_min

  if (!is.null(json$merge_data))       merge_data       <- json$merge_data

  if (!is.null(json$norm_method))      norm_method      <- json$norm_method
  if (!is.null(json$scale_factor))     scale_factor     <- json$scale_factor

  if (!is.null(json$var_method))       var_method       <- json$var_method
  if (!is.null(json$nfeatures_var))    nfeatures_var    <- json$nfeatures_var
  if (!is.null(json$vst_clip_max))     vst_clip_max     <- json$vst_clip_max

  if (!is.null(json$vars_to_regress))  vars_to_regress  <- json$vars_to_regress
  if (!is.null(json$model_use))        model_use        <- json$model_use
  if (!is.null(json$do_scale))         do_scale         <- json$do_scale
  if (!is.null(json$do_center))        do_center        <- json$do_center
  if (!is.null(json$scale_max))        scale_max        <- json$scale_max

  if (!is.null(json$npcs))             npcs             <- json$npcs
  if (!is.null(json$weight_by_var))    weight_by_var    <- json$weight_by_var

  if (!is.null(json$run_harmony))             run_harmony             <- json$run_harmony
  if (!is.null(json$harmony_group_by_vars))   harmony_group_by_vars   <- json$harmony_group_by_vars
  if (!is.null(json$harmony_dims_use))        harmony_dims_use        <- json$harmony_dims_use
  if (!is.null(json$harmony_theta))           harmony_theta           <- json$harmony_theta
  if (!is.null(json$harmony_lambda))          harmony_lambda          <- json$harmony_lambda
  if (!is.null(json$harmony_sigma))           harmony_sigma           <- json$harmony_sigma
  if (!is.null(json$harmony_max_iter_harmony)) harmony_max_iter_harmony <- json$harmony_max_iter_harmony
  if (!is.null(json$harmony_max_iter_cluster)) harmony_max_iter_cluster <- json$harmony_max_iter_cluster

  # 解析 harmony_dims_use 字符串 → 整数向量
  harmony_dims_vec <- eval(parse(text = harmony_dims_use))

  # ── 日志 ──
  log_path <- file.path(qc_dir, paste0(project_name, "_qc.log"))
  log_con  <- file(log_path, open = "w")

  log_msg <- function(...) {
    line <- paste0("[QC] ", paste(..., collapse = " "))
    cat(line, "\n", file = log_con, append = TRUE)
    cat(line, "\n")
  }

  log_msg("========================================")
  log_msg("   单细胞全流程质控分析")
  log_msg("========================================")
  log_msg("项目:", project_name)
  log_msg("物种:", species)
  log_msg("样本数:", length(samples))
  log_msg("输出目录:", qc_dir)
  log_msg("")


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 1: 数据导入 — Read10X + CreateSeuratObject
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("── Step 1: 数据导入 ──")

  sample_names <- names(samples)
  seurat_list  <- list()

  for (sname in sample_names) {
    data_path <- samples[[sname]]
    log_msg("  样本:", sname, "→", data_path)

    counts <- Read10X(
      data.dir       = data_path,
      gene.column    = gene_column,
      unique.features = unique_features,
      strip.suffix    = strip_suffix
    )
    log_msg("    原始基因数:", nrow(counts), "原始细胞数:", ncol(counts))

    sobj <- CreateSeuratObject(
      counts       = counts,
      project      = sname,
      min.cells    = min_cells,
      min.features = min_features,
      assay        = assay_name
    )
    log_msg("    建对象后细胞数:", ncol(sobj))

    seurat_list[[sname]] <- sobj
  }


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 2: 添加细胞元数据 — 线粒体% + 核糖体%
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 2: 添加细胞元数据 ──")

  for (sname in sample_names) {
    sobj <- seurat_list[[sname]]
    sobj[["percent.mt"]]   <- PercentageFeatureSet(sobj, pattern = mito_pattern)
    sobj[["percent.ribo"]] <- PercentageFeatureSet(sobj, pattern = ribo_pattern)

    mt_med   <- round(median(sobj[["percent.mt"]][, 1]), 2)
    ribo_med <- round(median(sobj[["percent.ribo"]][, 1]), 2)
    log_msg("  ", sname, "→ 线粒体中位数:", mt_med, "%  核糖体中位数:", ribo_med, "%")

    seurat_list[[sname]] <- sobj
  }


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 3: QC 可视化（每个样本独立出图 → data/qc/）
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 3: 预处理 QC 可视化 ──")

  for (sname in sample_names) {
    sobj <- seurat_list[[sname]]

    # 小提琴图
    vln_p <- VlnPlot(
      sobj,
      features = c("nFeature_RNA", "nCount_RNA", "percent.mt", "percent.ribo"),
      ncol = 2, pt.size = 0.1
    ) + patchwork::plot_annotation(title = paste(sname, "— QC 小提琴图"))
    vln_file <- file.path(qc_dir, paste0(sname, "_qc_vln.pdf"))
    ggsave(vln_file, vln_p, width = 10, height = 8, dpi = 300)
    log_msg("  小提琴图:", vln_file)

    # 散点图
    scat_p <- FeatureScatter(
      sobj,
      feature1 = "nCount_RNA",
      feature2 = "nFeature_RNA",
      pt.size = 0.3
    ) + ggtitle(paste(sname, "— 基因数 vs 测序深度"))
    scat_file <- file.path(qc_dir, paste0(sname, "_qc_scatter.pdf"))
    ggsave(scat_file, scat_p, width = 8, height = 6, dpi = 300)
    log_msg("  散点图:", scat_file)
  }


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 4: 过滤 + 多样本合并
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 4: 过滤 + 多样本合并 ──")

  cells_summary <- list()

  for (sname in sample_names) {
    sobj <- seurat_list[[sname]]
    cells_before <- ncol(sobj)

    sobj <- subset(
      sobj,
      subset = nFeature_RNA > nfeature_rna_low &
               nFeature_RNA < nfeature_rna_high &
               percent.mt   < percent_mt_max &
               percent.ribo > percent_ribo_min
    )

    cells_after  <- ncol(sobj)
    cells_removed <- cells_before - cells_after
    pct_removed   <- round(cells_removed / cells_before * 100, 2)

    log_msg("  ", sname,
            ": 过滤前", cells_before, "→ 过滤后", cells_after,
            "(移除", cells_removed, "=", pct_removed, "%)")

    cells_summary[[sname]] <- list(
      before  = cells_before,
      after   = cells_after,
      removed = cells_removed,
      pct     = pct_removed
    )

    seurat_list[[sname]] <- sobj
  }

  # 多样本合并
  if (length(seurat_list) > 1) {
    log_msg("  合并", length(seurat_list), "个样本...")
    merged <- merge(
      x            = seurat_list[[1]],
      y            = seurat_list[-1],
      add.cell.ids = sample_names,
      merge.data   = merge_data,
      project      = project_name
    )
  } else {
    merged <- seurat_list[[1]]
    merged@project.name <- project_name
  }

  # 关键：生成 batch 列供 Harmony 使用
  merged$batch <- merged$orig.ident
  log_msg("  合并后总细胞数:", ncol(merged))
  log_msg("  batch 分组:", paste(unique(merged$batch), collapse = ", "))


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 5: 归一化 + 高变基因筛选
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 5: 归一化 + 高变基因筛选 ──")

  merged <- NormalizeData(
    object               = merged,
    normalization.method = norm_method,
    scale.factor         = scale_factor
  )
  log_msg("  归一化完成: method =", norm_method, "scale.factor =", scale_factor)

  merged <- FindVariableFeatures(
    object           = merged,
    selection.method = var_method,
    nfeatures        = nfeatures_var,
    clip.max         = vst_clip_max
  )
  n_var <- length(VariableFeatures(merged))
  log_msg("  高变基因数:", n_var, "(method =", var_method, "nfeatures =", nfeatures_var, ")")


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 6: 高变基因可视化
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 6: 高变基因可视化 ──")

  top10_var <- head(VariableFeatures(merged), 10)

  var_p <- VariableFeaturePlot(merged)
  var_p <- LabelPoints(plot = var_p, points = top10_var, repel = TRUE, size = 3)
  var_p <- var_p + ggtitle(paste(project_name, "— 高变基因"))

  var_file <- file.path(qc_dir, paste0(project_name, "_variable_features.pdf"))
  ggsave(var_file, var_p, width = 10, height = 6, dpi = 300)
  log_msg("  高变基因图:", var_file)


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 7: 标准化（Scaling）+ 回归线粒体比例
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 7: 标准化 + 回归 ──")

  merged <- ScaleData(
    object          = merged,
    features        = VariableFeatures(merged),
    vars.to.regress = vars_to_regress,
    model.use       = model_use,
    do.scale        = do_scale,
    do.center       = do_center,
    scale.max       = scale_max
  )
  log_msg("  标准化完成: vars.to.regress =", vars_to_regress,
          "model =", model_use, "scale.max =", scale_max)


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 8: PCA + Harmony 批次校正
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 8: PCA + Harmony 批次校正 ──")

  merged <- RunPCA(
    object         = merged,
    features       = VariableFeatures(merged),
    npcs           = npcs,
    weight.by.var  = weight_by_var
  )
  log_msg("  PCA 完成: npcs =", npcs)

  # PCA 批次分布图（校正前）
  pca_batch_p <- DimPlot(
    merged,
    reduction = "pca",
    group.by  = harmony_group_by_vars,
    pt.size   = 0.3
  ) + ggtitle(paste(project_name, "— PCA 批次分布（校正前）"))

  pca_batch_file <- file.path(qc_dir, paste0(project_name, "_pca_batch.pdf"))
  ggsave(pca_batch_file, pca_batch_p, width = 8, height = 6, dpi = 300)
  log_msg("  PCA 批次图:", pca_batch_file)

  # Harmony 批次校正
  if (run_harmony) {
    merged <- RunHarmony(
      object         = merged,
      group.by.vars  = harmony_group_by_vars,
      assay.use      = assay_name,
      reduction.use  = "pca",
      dims.use       = harmony_dims_vec,
      theta          = harmony_theta,
      lambda         = harmony_lambda,
      sigma          = harmony_sigma,
      max.iter.harmony = harmony_max_iter_harmony,
      max.iter.cluster = harmony_max_iter_cluster
    )
    log_msg("  Harmony 完成: dims =", harmony_dims_use,
            "theta =", harmony_theta, "lambda =", harmony_lambda)

    # Harmony 校正后批次分布图
    harm_p <- DimPlot(
      merged,
      reduction = "harmony",
      group.by  = harmony_group_by_vars,
      pt.size   = 0.3
    ) + ggtitle(paste(project_name, "— Harmony 校正后"))

    harm_file <- file.path(qc_dir, paste0(project_name, "_harmony.pdf"))
    ggsave(harm_file, harm_p, width = 8, height = 6, dpi = 300)
    log_msg("  Harmony 批次图:", harm_file)
  } else {
    log_msg("  Harmony 已跳过 (run_harmony = FALSE)")
  }


  # ═══════════════════════════════════════════════════════════════════════
  #  保存结果 + 日志收尾 + 返回值
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── 保存结果 ──")

  rds_path <- file.path(qc_dir, paste0(project_name, "_filtered.rds"))
  saveRDS(merged, file = rds_path)
  log_msg("  Seurat 对象:", rds_path)

  # 汇总各样本过滤统计
  total_before <- sum(sapply(cells_summary, `[[`, "before"))
  total_after  <- ncol(merged)
  total_removed <- total_before - total_after

  log_msg("  总计: 过滤前", total_before, "→ 过滤后", total_after,
          "(移除", total_removed, "=",
          round(total_removed / total_before * 100, 2), "%)")
  log_msg("")
  log_msg("  质控分析完成。")
  log_msg("========================================")

  close(log_con)

  # 返回值：仅保留关键结果
  return(list(
    status         = "success",
    message        = paste("QC 全流程完成，保留", total_after, "个细胞"),
    project        = project_name,
    cells_before   = total_before,
    cells_after    = total_after,
    cells_removed  = total_removed,
    cells_removed_pct = round(total_removed / total_before * 100, 2),
    per_sample     = cells_summary,
    rds_path       = rds_path,
    log_path       = log_path
  ))
}
