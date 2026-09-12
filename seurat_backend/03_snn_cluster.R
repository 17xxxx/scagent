# 03_snn_cluster.R —— 单细胞 SNN 图聚类分析
# ======================================================================
# 分析步骤：
#   1. 从 data/pca_umap/seuratobject.json 读取 PCA/UMAP 输出的 Seurat 对象
#   2. 自动检测可用降维方法（harmony > pca）
#   3. FindNeighbors — 构建 SNN 邻接图
#   4. FindClusters — 社区发现分群
#   5. 聚类结果统计
#   6. DimPlot — UMAP 聚类图可视化
#   7. 保存结果 + 更新 seuratobject.json
#
# 预设 JSON 入参格式（注释，非执行代码）：
# ┌─────────────────────────────────────────────────────────────────────┐
# │ {                                                                   │
# │   "input_dir": "/workspace/data/pca_umap",                          │
# │   "output_dir": "/workspace/data/snn_cluster",                      │
# │   "project": "scRNA_project",                                       │
# │                                                                     │
# │   "findneighbor_dims": "1:15",                                      │
# │   "k_param": 20,                                                    │
# │   "annoy_metric": "euclidean",                                      │
# │                                                                     │
# │   "resolution": 0.8,                                                │
# │   "cluster_algorithm": 1,                                           │
# │   "cluster_random_seed": 42,                                        │
# │                                                                     │
# │   "dimplot_group_by": "seurat_clusters",                            │
# │   "dimplot_pt_size": 0.3,                                           │
# │   "dimplot_label": true,                                            │
# │   "dimplot_label_size": 4                                           │
# │ }                                                                   │
# └─────────────────────────────────────────────────────────────────────┘

library(Seurat)
library(ggplot2)


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

run_snn_cluster <- function(...) {

  # ═══════════════════════════════════════════════════════════════════════
  # 〇、集中设置全部默认参数
  # ═══════════════════════════════════════════════════════════════════════

  # ── 输入 / 输出目录 ──
  input_dir   <- scagent_step_dir("pca_umap")
  output_dir  <- scagent_step_dir("snn_cluster")
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  # ── 项目 ──
  project_name <- "scRNA_project"

  # ── FindNeighbors ──
  findneighbor_dims <- "1:15"
  k_param           <- 20
  annoy_metric      <- "euclidean"

  # ── FindClusters ──
  resolution          <- 0.8
  cluster_algorithm   <- 1          # 1 = Louvain, 4 = Leiden
  cluster_random_seed <- 42

  # ── DimPlot ──
  dimplot_group_by  <- "seurat_clusters"
  dimplot_pt_size   <- 0.3
  dimplot_label     <- TRUE
  dimplot_label_size <- 4

  # ── JSON 参数覆盖 ──
  json <- list(...)

  if (!is.null(json$input_dir))          input_dir           <- json$input_dir
  if (!is.null(json$output_dir))         output_dir          <- json$output_dir
  if (!is.null(json$project))            project_name        <- json$project

  if (!is.null(json$findneighbor_dims))  findneighbor_dims   <- json$findneighbor_dims
  if (!is.null(json$k_param))            k_param             <- json$k_param
  if (!is.null(json$annoy_metric))       annoy_metric        <- json$annoy_metric

  if (!is.null(json$resolution))         resolution          <- json$resolution
  if (!is.null(json$cluster_algorithm))  cluster_algorithm   <- json$cluster_algorithm
  if (!is.null(json$cluster_random_seed)) cluster_random_seed <- json$cluster_random_seed

  if (!is.null(json$dimplot_group_by))   dimplot_group_by    <- json$dimplot_group_by
  if (!is.null(json$dimplot_pt_size))    dimplot_pt_size     <- json$dimplot_pt_size
  if (!is.null(json$dimplot_label))      dimplot_label       <- json$dimplot_label
  if (!is.null(json$dimplot_label_size)) dimplot_label_size  <- json$dimplot_label_size

  # 解析 dims 字符串 → 整数向量
  findneighbor_dims_vec <- eval(parse(text = findneighbor_dims))

  # ── 日志 ──
  log_path <- file.path(output_dir, paste0(project_name, "_snn_cluster.log"))
  log_con  <- file(log_path, open = "w")

  log_msg <- function(...) {
    line <- paste0("[SNN] ", paste(..., collapse = " "))
    cat(line, "\n", file = log_con, append = TRUE)
    cat(line, "\n")
  }

  log_msg("========================================")
  log_msg("   单细胞 SNN 图聚类分析")
  log_msg("========================================")
  log_msg("项目:", project_name)
  log_msg("输入目录:", input_dir)
  log_msg("输出目录:", output_dir)
  log_msg("")


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 1: 读取 PCA/UMAP 输出的 Seurat 对象
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("── Step 1: 读取 PCA/UMAP Seurat 对象 ──")

  .idx <- scagent_read_index(input_dir, what = "PCA/UMAP")
  if (!.idx$ok) {
    log_msg("  错误:", .idx$message)
    close(log_con)
    return(list(status = "error", message = .idx$message))
  }
  object_json_path <- .idx$path
  obj_info <- .idx$info
  rds_path <- scagent_resolve_rds(obj_info, "pca_umap")
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

  log_msg("  参数: input_dir =", input_dir, ", project =", project_name)


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 2: 检测可用降维方法
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
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
    log_msg("  错误: 未找到 pca 或 harmony 降维结果")
    close(log_con)
    return(list(status = "error", message = "Seurat 对象中无 pca/harmony 降维结果"))
  }


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 3: FindNeighbors — 构建 SNN 邻接图
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 3: FindNeighbors ──")

  seurat_obj <- FindNeighbors(
    object       = seurat_obj,
    reduction    = reduction_use,
    dims         = findneighbor_dims_vec,
    k.param      = k_param,
    annoy.metric = annoy_metric,
    verbose      = FALSE
  )
  log_msg("  SNN 邻接图构建完成")

  log_msg("  参数: reduction =", reduction_use,
          ", dims =", findneighbor_dims,
          ", k.param =", k_param,
          ", annoy.metric =", annoy_metric)


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 4: FindClusters — 社区发现分群
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 4: FindClusters ──")

  seurat_obj <- FindClusters(
    object     = seurat_obj,
    resolution = resolution,
    algorithm  = cluster_algorithm,
    random.seed = cluster_random_seed
  )

  cluster_count <- length(unique(seurat_obj$seurat_clusters))
  log_msg("  聚类完成: 共", cluster_count, "个亚群")

  log_msg("  参数: resolution =", resolution,
          ", algorithm =", cluster_algorithm,
          "(Louvain)",  # 仅 Louvain
          ", random.seed =", cluster_random_seed)


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 5: 聚类结果统计
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 5: 聚类结果统计 ──")

  cluster_table <- table(seurat_obj$seurat_clusters)
  log_msg("  各亚群细胞数:")
  for (i in seq_along(cluster_table)) {
    log_msg("    Cluster", names(cluster_table)[i], ":", cluster_table[i], "个细胞")
  }


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 6: DimPlot — UMAP 聚类图
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 6: DimPlot 聚类可视化 ──")

  umap_cluster_p <- DimPlot(
    seurat_obj,
    reduction = "umap",
    group.by  = dimplot_group_by,
    pt.size   = dimplot_pt_size,
    label     = dimplot_label,
    label.size = dimplot_label_size
  ) + ggtitle(paste(project_name, "— SNN 聚类 (resolution =", resolution, ")"))

  umap_cluster_file <- file.path(output_dir, paste0(project_name, "_umap_clustered.pdf"))
  ggsave(umap_cluster_file, umap_cluster_p, width = 8, height = 6, dpi = 300)
  log_msg("  UMAP 聚类图已保存:", umap_cluster_file)

  log_msg("  参数: group.by =", dimplot_group_by,
          ", pt.size =", dimplot_pt_size,
          ", label =", dimplot_label,
          ", label.size =", dimplot_label_size)


  # ═══════════════════════════════════════════════════════════════════════
  #  保存结果 + 日志收尾 + 返回值
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── 保存结果 ──")

  rds_path <- file.path(output_dir, paste0(project_name, "_snn_cluster.rds"))
  saveRDS(seurat_obj, file = rds_path)
  log_msg("  Seurat 对象:", rds_path)

  # ── 保存 seuratobject.json：记录本次运行的 RDS 路径，供后续工具读取 ──
  object_json <- file.path(output_dir, "seuratobject.json")
  object_info <- list(
    latest_rds      = basename(rds_path),
    data_root       = scagent_data_root(),
    project         = project_name,
    created_at      = as.character(Sys.time()),
    cells           = ncol(seurat_obj),
    cluster_count   = cluster_count,
    clusters        = as.list(cluster_table),
    reductions      = Reductions(seurat_obj)
  )
  scagent_write_json(object_info, object_json)
  log_msg("  对象索引:", object_json)

  log_msg("")
  log_msg("  SNN 聚类分析完成。")
  log_msg("========================================")

  close(log_con)

  return(list(
    status         = "success",
    message        = paste("SNN 聚类完成，共", cluster_count, "个亚群，", ncol(seurat_obj), "个细胞"),
    project        = project_name,
    cluster_count  = cluster_count,
    cluster_table  = as.list(cluster_table),
    reduction_use  = reduction_use,
    cells          = ncol(seurat_obj),
    rds_path       = rds_path,
    object_json    = object_json,
    log_path       = log_path,
    figures = list(
      umap_clustered = umap_cluster_file
    )
  ))
}
