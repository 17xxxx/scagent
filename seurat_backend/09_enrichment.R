# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  09_enrichment.R —— 功能富集可视化 (GO/KEGG)                                   ║
# ║  功能：对特定细胞群做 GO 生物学过程富集分析，柱状图可视化                           ║
# ║  读取：data/cell_annotation/seuratobject.json + cluster_markers.csv            ║
# ║  必须参数：cell_group_names — 细胞类型名称列表（此工具要求 LLM 传入）             ║
# ║  输出：data/enrichment/{project}_{group}_go_enrich.pdf、日志、seuratobject.json  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# ── 预设 JSON 格式（注释，供 Agent / Python tool 参考） ──
# cell_group_names 为必须参数，由 LLM 在调用工具时传入
# {
#   "project": "scRNA_project",
#   "cell_group_names": ["T_cells", "B_cells"],
#   "species": "mouse",
#   "org_db": "org.Mm.eg.db",
#   "keytype": "SYMBOL",
#   "ont": "BP",
#   "p_adjust_method": "fdr",
#   "qvalue_cutoff": 0.05,
#   "show_category": 10,
#   "dpi": 300,
#   "width": 10,
#   "height": 6
# }

library(Seurat)
library(ggplot2)
library(dplyr)

# clusterProfiler 可能需要从 Bioconductor 安装，Dockerfile 已添加
suppressPackageStartupMessages({
  library(clusterProfiler)
})


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

run_enrichment <- function(...) {
  json <- list(...)

  # ── 基础参数 ──
  project_name      <- "scRNA_project"
  input_dir         <- scagent_step_dir("cell_annotation")
  output_dir        <- scagent_step_dir("enrichment")

  # ── 必须参数（LLM 传入）──
  cell_group_names  <- NULL

  # ── 物种参数 ──
  species_val       <- "mouse"
  org_db_name       <- "org.Mm.eg.db"

  # ── enrichGO 参数 ──
  keytype_val       <- "SYMBOL"
  ont_val           <- "BP"
  p_adjust_method   <- "fdr"
  qvalue_cutoff     <- 0.05

  # ── 可视化参数 ──
  show_category     <- 10
  dpi_val           <- 300
  width_val         <- 10
  height_val        <- 6

  # ── JSON 覆盖默认值 ──
  if (!is.null(json$project))           project_name     <- json$project
  if (!is.null(json$cell_group_names))  cell_group_names <- unlist(json$cell_group_names)
  if (!is.null(json$species))           species_val      <- json$species
  if (!is.null(json$org_db))            org_db_name      <- json$org_db
  if (!is.null(json$keytype))           keytype_val      <- json$keytype
  if (!is.null(json$ont))               ont_val          <- json$ont
  if (!is.null(json$p_adjust_method))   p_adjust_method  <- json$p_adjust_method
  if (!is.null(json$qvalue_cutoff))     qvalue_cutoff    <- json$qvalue_cutoff
  if (!is.null(json$show_category))     show_category    <- json$show_category
  if (!is.null(json$dpi))               dpi_val          <- json$dpi
  if (!is.null(json$width))             width_val        <- json$width
  if (!is.null(json$height))            height_val       <- json$height

  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  # ── 日志系统 ──
  log_path <- file.path(output_dir, paste0(project_name, "_enrichment.log"))
  log_con  <- file(log_path, open = "wt")
  sink(log_con, append = TRUE, split = TRUE)
  log_msg <- function(...) {
    cat(paste0("[", Sys.time(), "] "), ..., "\n", sep = "")
  }

  log_msg("══════════ 功能富集分析开始 ══════════")
  log_msg("项目:", project_name)

  # ── 检查必须参数 ──
  if (is.null(cell_group_names) || length(cell_group_names) == 0) {
    log_msg("  错误: 缺少必须参数 cell_group_names")
    sink()
    close(log_con)
    return(list(status = "error",
                message = "缺少必须参数 cell_group_names，请提供目标细胞类型名称列表"))
  }
  log_msg("目标细胞群:", paste(cell_group_names, collapse = ", "))

  # ── 加载物种数据库 ──
  suppressPackageStartupMessages({
    library(org_db_name, character.only = TRUE)
  })
  log_msg("物种数据库:", org_db_name)


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

  # 读取标记基因 CSV
  # 用【注释索引里记录的项目名】去找 markers，而不是当前请求的项目名 ——
  # 否则"用项目 A 注释、再用项目 B 富集"会因文件名对不上而误报"请先运行细胞注释"。
  marker_project <- tryCatch(as.character(unlist(obj_info$project))[1],
                             error = function(e) NA_character_)
  if (is.na(marker_project) || !nzchar(marker_project)) marker_project <- project_name

  marker_csv_path <- file.path(input_dir, paste0(marker_project, "_cluster_markers.csv"))
  if (!file.exists(marker_csv_path) && !identical(marker_project, project_name)) {
    marker_csv_path <- file.path(input_dir, paste0(project_name, "_cluster_markers.csv"))
  }
  if (!file.exists(marker_csv_path)) {
    log_msg("  错误: 找不到 cluster_markers.csv（已按项目名 '", marker_project,
            "' 与 '", project_name, "' 查找 ", input_dir, "）")
    sink()
    close(log_con)
    return(list(status = "error",
                message = paste0("cluster_markers.csv 不存在，请先运行细胞注释",
                                 "（已按项目名 '", marker_project, "' 与 '",
                                 project_name, "' 查找 ", input_dir, "）")))
  }

  log_msg("  标记基因表来源项目:", marker_project)
  cluster_markers <- read.csv(marker_csv_path, stringsAsFactors = FALSE)
  log_msg("  标记基因表:", marker_csv_path)

  # 识别列名
  cluster_col <- intersect(c("cluster", "group"), colnames(cluster_markers))[1]
  gene_col    <- intersect(c("gene", "Gene", "gene_name"), colnames(cluster_markers))[1]
  celltype_col_check <- "cell_type" %in% colnames(seurat_obj@meta.data)

  if (is.na(cluster_col) || is.na(gene_col)) {
    log_msg("  错误: 无法识别 cluster 或 gene 列")
    sink()
    close(log_con)
    return(list(status = "error", message = "cluster_markers.csv 格式不兼容"))
  }


  # ═══════════════════════════════════════════════════════════════════════
  #  Step 2: 逐细胞群做 GO 富集
  # ═══════════════════════════════════════════════════════════════════════
  log_msg("")
  log_msg("── Step 2: GO 富集分析 ──")
  log_msg("  参数: ont           =", ont_val)
  log_msg("  参数: pAdjustMethod  =", p_adjust_method)
  log_msg("  参数: qvalueCutoff   =", qvalue_cutoff)
  log_msg("  参数: showCategory   =", show_category)

  enrichment_results <- list()
  pdf_files <- c()

  for (grp_name in cell_group_names) {
    log_msg("")
    log_msg("  处理细胞群:", grp_name)

    # 从标记基因表中提取该群的基因
    # 如果 cluster 列是数字，先用 cell_type 匹配
    if (celltype_col_check) {
      # 找到哪些 cluster ID 属于该细胞类型
      cluster_ids <- unique(
        seurat_obj$seurat_clusters[seurat_obj$cell_type == grp_name]
      )
      grp_genes <- cluster_markers %>%
        filter(cluster %in% cluster_ids) %>%
        pull(.data[[gene_col]]) %>%
        unique()
    } else {
      # 直接用 cluster/group 列名匹配
      grp_genes <- cluster_markers %>%
        filter(.data[[cluster_col]] == grp_name | grepl(grp_name, .data[[cluster_col]], ignore.case = TRUE)) %>%
        pull(.data[[gene_col]]) %>%
        unique()
    }

    log_msg("    匹配基因数:", length(grp_genes))

    if (length(grp_genes) < 5) {
      log_msg("    跳过:", grp_name, "（基因数 < 5）")
      next
    }

    # GO 富集
    go_result <- tryCatch({
      enrichGO(
        gene          = grp_genes,
        OrgDb         = get(org_db_name),
        keyType       = keytype_val,
        ont           = ont_val,
        pAdjustMethod = p_adjust_method,
        qvalueCutoff  = qvalue_cutoff
      )
    }, error = function(e) {
      log_msg("    enrichGO 出错:", e$message)
      return(NULL)
    })

    if (is.null(go_result) || nrow(as.data.frame(go_result)) == 0) {
      log_msg("    跳过:", grp_name, "（无显著富集结果）")
      next
    }

    # 柱状图
    bar_p <- tryCatch({
      barplot(go_result, showCategory = show_category,
              title = paste(grp_name, "GO", ont_val, "Enrichment"))
    }, error = function(e) {
      NULL
    })

    if (!is.null(bar_p)) {
      safe_name <- gsub("[^a-zA-Z0-9_]", "_", grp_name)
      pdf_file <- file.path(output_dir,
                            paste0(project_name, "_", safe_name, "_go_enrich.pdf"))
      ggsave(pdf_file, bar_p, width = width_val, height = height_val, dpi = dpi_val)
      log_msg("    GO 富集图:", pdf_file)
      pdf_files <- c(pdf_files, pdf_file)

      enrichment_results[[grp_name]] <- list(
        file    = pdf_file,
        n_genes = length(grp_genes),
        n_enriched = nrow(as.data.frame(go_result))
      )
    }
  }


  sink()
  close(log_con)

  return(list(
    status             = "success",
    message            = "功能富集分析完成",
    project            = project_name,
    cell_groups        = cell_group_names,
    enrichment_files   = pdf_files,
    enrichment_results = enrichment_results,
    log_path           = log_path,
    cells              = ncol(seurat_obj)
  ))
}
