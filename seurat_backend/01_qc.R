# scripts/01_qc.R
library(Seurat)

#' 单细胞 RNA-seq 质量控制
#'
#' @param data_path  10X 数据目录路径（含 matrix.mtx.gz, barcodes.tsv.gz, features.tsv.gz）
#' @param min_cells  基因至少在多少个细胞中表达才保留（默认 3）
#' @param min_features  细胞至少表达多少个基因才保留（默认 200）
#' @param nFeature_RNA_low  nFeature_RNA 下阈值（默认 200）
#' @param nFeature_RNA_high nFeature_RNA 上阈值（默认 2500）
#' @param percent_mt_max    线粒体基因比例上限（默认 5）
#' @param ...  忽略多余参数，防止 Python 端传入额外字段时报错
#'
#' @return list 包含过滤前后的细胞数和统计信息
run_quality_control <- function(
    data_path,
    min_cells = 3,
    min_features = 200,
    nFeature_RNA_low = 200,
    nFeature_RNA_high = 2500,
    percent_mt_max = 5,
    project_name = "scRNA",
    ...
) {
  print(paste("[QC] 数据目录:", data_path))
  print(paste("[QC] 过滤参数: min_cells =", min_cells, ", min_features =", min_features))
  print(paste("[QC] 过滤参数: nFeature_RNA ∈ [", nFeature_RNA_low, ",", nFeature_RNA_high, "], percent.mt <", percent_mt_max))

  # 1. 读取 10X 数据
  counts <- Read10X(data.dir = data_path)
  print(paste("[QC] 原始基因数:", nrow(counts), ", 原始细胞数:", ncol(counts)))

  # 2. 创建 Seurat 对象
  seurat_obj <- CreateSeuratObject(
    counts = counts,
    project = project_name,
    min.cells = min_cells,
    min.features = min_features
  )
  cells_before <- ncol(seurat_obj)
  print(paste("[QC] CreateSeuratObject 后细胞数:", cells_before))

  # 3. 计算线粒体基因比例
  seurat_obj[["percent.mt"]] <- PercentageFeatureSet(seurat_obj, pattern = "^MT-")
  mito_median <- median(seurat_obj[["percent.mt"]][, 1])
  print(paste("[QC] 线粒体比例中位数:", round(mito_median, 2), "%"))

  # 4. 基于 QC 指标过滤细胞
  seurat_obj <- subset(
    seurat_obj,
    subset = nFeature_RNA > nFeature_RNA_low &
             nFeature_RNA < nFeature_RNA_high &
             percent.mt < percent_mt_max
  )
  cells_after <- ncol(seurat_obj)
  print(paste("[QC] 过滤后细胞数:", cells_after, "(移除", cells_before - cells_after, "个细胞)"))

  # 5. 保存结果到 data/qc/
  qc_dir <- "/workspace/data/qc"
  if (!dir.exists(qc_dir)) {
    dir.create(qc_dir, recursive = TRUE)
    print(paste("[QC] 创建输出目录:", qc_dir))
  }

  # 保存过滤后的 Seurat 对象
  rds_path <- file.path(qc_dir, paste0(project_name, "_filtered.rds"))
  saveRDS(seurat_obj, file = rds_path)
  print(paste("[QC] Seurat 对象已保存:", rds_path))

  # 汇总统计
  stats <- list(
    genes_before_qc   = nrow(counts),
    cells_before_qc   = cells_before,
    cells_after_qc    = cells_after,
    cells_removed     = cells_before - cells_after,
    cells_removed_pct = round((cells_before - cells_after) / cells_before * 100, 2),
    mito_median_pct   = round(mito_median, 2),
    nFeature_median   = round(median(seurat_obj[["nFeature_RNA"]][, 1])),
    nCount_median     = round(median(seurat_obj[["nCount_RNA"]][, 1]))
  )

  # 保存统计到 JSON
  json_path <- file.path(qc_dir, paste0(project_name, "_stats.json"))
  write(jsonlite::toJSON(stats, pretty = TRUE, auto_unbox = TRUE), json_path)
  print(paste("[QC] 统计结果已保存:", json_path))

  return(list(
    status    = "success",
    message   = paste("QC 完成，保留", cells_after, "个细胞"),
    stats     = stats,
    rds_path  = rds_path,
    json_path = json_path
  ))
}