# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  api.R —— scAgent R 后端网关（Plumber）                                       ║
# ║                                                                              ║
# ║  职责：                                                                       ║
# ║    1. 加载共享配置 _config.R（路径 / 索引辅助 / 并发锁 / 参考集）               ║
# ║    2. 自动发现并加载全部步骤脚本（^NN_*.R），新增步骤无需改本文件               ║
# ║    3. POST /api/execute_task —— 通用分发网关（含参数白名单校验）                ║
# ║    4. GET  /api/ping         —— 健康检查探针                                   ║
# ║    5. GET  /api/run_test     —— 自检                                          ║
# ║                                                                              ║
# ║  设计要点：                                                                   ║
# ║    · 路径全部来自环境变量，支持多租户（请求级 data_root）                       ║
# ║    · 参数白名单拦截「拼错参数名静默用默认值」这一最隐蔽的 bug                    ║
# ║    · 项目级文件锁，避免并发请求把内存打爆                                       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

library(plumber)

BACKEND_DIR <- Sys.getenv("SCAGENT_BACKEND_DIR", "/workspace/seurat_backend")

# ═══════════════════════════════════════════════════════════════════════════════
# 1. 共享配置（必须最先加载：后续脚本依赖其中的辅助函数）
# ═══════════════════════════════════════════════════════════════════════════════
config_path <- file.path(BACKEND_DIR, "_config.R")
if (!file.exists(config_path)) {
  stop("找不到共享配置: ", config_path,
       "；请设置 SCAGENT_BACKEND_DIR 指向 seurat_backend 目录")
}
source(config_path, encoding = "UTF-8")

# ═══════════════════════════════════════════════════════════════════════════════
# 2. 自动发现步骤脚本
#    _config.R 以 "_" 开头、*.bak 不匹配 ^[0-9]{2}_ ，因此不会被误加载。
# ═══════════════════════════════════════════════════════════════════════════════
step_files <- sort(list.files(BACKEND_DIR, pattern = "^[0-9]{2}_.*\\.R$",
                              full.names = TRUE))
if (length(step_files) == 0) {
  stop("在 ", BACKEND_DIR, " 下未找到任何步骤脚本（应匹配 ^[0-9]{2}_.*\\.R$）")
}

cat("\n╔══════════════════════════════════════════════════════════╗\n")
cat("║  scAgent R 后端启动                                      ║\n")
cat("╚══════════════════════════════════════════════════════════╝\n")
cat("  后端目录 : ", BACKEND_DIR, "\n", sep = "")
cat("  数据根   : ", scagent_data_root(), "\n", sep = "")
cat("  参考集   : ", scagent_refdata_dir(), "\n", sep = "")
for (f in step_files) {
  source(f, encoding = "UTF-8")
  cat("  已加载   : ", basename(f), "\n", sep = "")
}
cat("\n")

# ═══════════════════════════════════════════════════════════════════════════════
# 3. 工具名 → R 函数 映射
# ═══════════════════════════════════════════════════════════════════════════════
FUNC_MAPPING <- list(
  qc         = "run_quality_control",
  pca        = "run_pca_umap_analysis",
  snn        = "run_snn_cluster",
  anno       = "run_cell_annotation",
  dimplot    = "run_dimplot",
  marker_viz = "run_marker_viz",
  cell_ratio = "run_cell_ratio",
  heatmap    = "run_heatmap",
  enrichment = "run_enrichment"
)

# ═══════════════════════════════════════════════════════════════════════════════
# 4. 参数白名单
#
#    每个 R 步骤函数都是 function(...) + `if (!is.null(json$xxx))` 的形式，
#    任何拼错/改名的参数都会被静默丢弃、悄悄使用默认值 —— 这是本架构最隐蔽的坑。
#    白名单在分发前拦截，把静默失效变成显式报错。
#
#    清单与各脚本实际支持的 json$ 参数一一对应；新增参数时同步更新本表。
#    `data_root` 为所有工具共有的可选参数（多租户隔离，见下方 handler）。
# ═══════════════════════════════════════════════════════════════════════════════
PARAM_WHITELIST <- list(
  qc = c("project", "species", "samples",
         "min_cells", "min_features", "assay_name",
         "nfeature_rna_low", "nfeature_rna_high", "percent_mt_max", "percent_ribo_min",
         "mito_pattern", "ribo_pattern", "gene_column", "unique_features", "strip_suffix",
         "merge_data", "norm_method", "scale_factor",
         "var_method", "nfeatures_var", "vst_clip_max",
         "vars_to_regress", "model_use", "do_scale", "do_center", "scale_max",
         "npcs", "weight_by_var", "run_harmony",
         "harmony_group_by_vars", "harmony_dims_use", "harmony_theta", "harmony_lambda",
         "harmony_sigma", "harmony_max_iter_harmony", "harmony_max_iter_cluster"),

  pca = c("project", "qc_dir", "output_dir",
          "elbow_ndims", "elbow_reduction",
          "umap_dims", "umap_n_neighbors", "umap_min_dist", "umap_seed",
          "run_tsne", "tsne_dims", "tsne_perplexity", "tsne_seed",
          "dimplot_group_by", "dimplot_pt_size"),

  snn = c("project", "input_dir", "output_dir",
          "findneighbor_dims", "k_param", "annoy_metric",
          "resolution", "cluster_algorithm", "cluster_random_seed",
          "dimplot_group_by", "dimplot_pt_size", "dimplot_label", "dimplot_label_size"),

  anno = c("project", "input_dir", "output_dir", "species",
           "only_pos", "min_pct", "logfc_threshold", "marker_test_use",
           "max_cells_per_ident", "top_n_markers",
           "singler_de_method", "singler_fine_tune",
           "dimplot_group_by", "dimplot_pt_size", "dimplot_label",
           "dimplot_label_size", "dimplot_repel"),

  dimplot = c("project", "reduction", "group_by", "split_by", "pt_size",
              "label", "label_size", "repel", "cols", "order", "raster",
              "dpi", "width", "height"),

  marker_viz = c("project", "marker_genes", "group_by", "pt_size", "ncol",
                 "split_by", "log", "cluster_idents",
                 "dot_scale", "cols", "col_min", "col_max",
                 "dpi", "vln_width", "vln_height", "dot_width", "dot_height", "dot_angle"),

  cell_ratio = c("project", "group_by_sample", "group_by_celltype", "position",
                 "width", "custom_colors", "dpi", "width_pic", "height_pic", "angle"),

  heatmap = c("project", "top_n", "group_by", "size", "angle", "raster",
              "disp_min", "disp_max", "draw_lines", "lines_width",
              "group_bar", "sample_n", "dpi", "width", "height"),

  enrichment = c("project", "cell_group_names", "species", "org_db", "keytype",
                 "ont", "p_adjust_method", "qvalue_cutoff", "show_category",
                 "dpi", "width", "height")
)

# data_root 为所有工具通用的请求级数据根目录（多租户隔离）
for (nm in names(PARAM_WHITELIST)) {
  PARAM_WHITELIST[[nm]] <- c(PARAM_WHITELIST[[nm]], "data_root")
}

# ═══════════════════════════════════════════════════════════════════════════════
# 5. 健康检查探针
# ═══════════════════════════════════════════════════════════════════════════════

#* @get /api/ping
function() {
  list(
    status      = "ok",
    pid         = Sys.getpid(),
    r_version   = as.character(getRversion()),
    data_dir    = scagent_data_root(),
    backend_dir = BACKEND_DIR,
    refdata_dir = scagent_refdata_dir(),
    tools       = names(FUNC_MAPPING),
    time        = as.character(Sys.time())
  )
}

# ═══════════════════════════════════════════════════════════════════════════════
# 6. 通用分发网关
# ═══════════════════════════════════════════════════════════════════════════════

#* 通用分发网关：按 tool_name 调用对应的 R 函数
#* @post /api/execute_task
function(req, res) {
  body <- req$body
  # 兜底：若 plumber 未注册 JSON 解析器，body 会是原始字符串
  if (is.character(body) && length(body) == 1 && nzchar(body)) {
    body <- tryCatch(jsonlite::fromJSON(body, simplifyVector = FALSE),
                     error = function(e) NULL)
  }
  if (is.null(body) || !is.list(body)) {
    res$status <- 400
    return(list(status = "error", message = "请求体不是合法的 JSON 对象"))
  }

  tool_name   <- body$tool_name
  tool_params <- body$params
  if (is.null(tool_params) || !is.list(tool_params)) tool_params <- list()

  cat("\n══════════════════════════════════════════════════════════\n")
  cat("[api.R] 收到请求\n")
  cat("  tool_name :", if (is.null(tool_name)) "<空>" else tool_name, "\n")
  cat("  params    :", paste(names(tool_params), collapse = ", "), "\n")
  if ("samples" %in% names(tool_params)) {
    cat("  samples   :", length(tool_params$samples), "个 ->",
        paste(names(tool_params$samples), collapse = ", "), "\n")
  }
  cat("══════════════════════════════════════════════════════════\n")

  # ── 工具名校验 ──
  target <- if (is.null(tool_name)) NULL else FUNC_MAPPING[[tool_name]]
  if (is.null(target)) {
    res$status <- 400
    return(list(status = "error",
                message = paste0("未知的工具名: ", tool_name,
                                 "；可用工具: ", paste(names(FUNC_MAPPING), collapse = ", "))))
  }

  # ── 参数白名单校验（拦拼写错误 / 两端命名不一致）──
  allowed <- PARAM_WHITELIST[[tool_name]]
  unknown <- setdiff(names(tool_params), allowed)
  if (length(unknown) > 0) {
    res$status <- 400
    return(list(status = "error",
                message = paste0("未知参数: ", paste(unknown, collapse = ", "),
                                 "；", tool_name, " 允许的参数: ",
                                 paste(allowed, collapse = ", "))))
  }

  # ── 请求级数据根目录（多租户）──
  project <- if (!is.null(tool_params$project)) as.character(tool_params$project) else "scRNA_project"
  restore_root <- NULL
  if (!is.null(tool_params$data_root)) {
    restore_root <- Sys.getenv("SCAGENT_DATA_DIR", unset = NA_character_)
    Sys.setenv(SCAGENT_DATA_DIR = as.character(tool_params$data_root))
    tool_params$data_root <- NULL
  }
  on.exit({
    if (!is.null(restore_root)) {
      if (is.na(restore_root)) Sys.unsetenv("SCAGENT_DATA_DIR")
      else Sys.setenv(SCAGENT_DATA_DIR = restore_root)
    }
  }, add = TRUE)

  # ── 动态执行（项目级锁 + 统一错误包装）──
  tryCatch(
    scagent_with_project_lock(project, do.call(get(target), tool_params)),
    error = function(e) {
      cat("[api.R] 执行失败:", conditionMessage(e), "\n")
      list(status = "error", message = paste0("执行出错: ", conditionMessage(e)))
    }
  )
}

# ═══════════════════════════════════════════════════════════════════════════════
# 7. 自检
# ═══════════════════════════════════════════════════════════════════════════════

#* 运行 run_test.R 自检脚本
#* @get /api/run_test
function() {
  test_path <- file.path(BACKEND_DIR, "run_test.R")
  if (!file.exists(test_path)) {
    return(list(status = "error", message = paste("找不到自检脚本:", test_path)))
  }
  tryCatch({
    invisible(capture.output(source(test_path, encoding = "UTF-8")))
    list(status = "success", message = "run_test 全部通过")
  }, error = function(e) {
    list(status = "error", message = paste("run_test 失败:", conditionMessage(e)))
  })
}

#* @plumber
function(pr) {
  pr
}
