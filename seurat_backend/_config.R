# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  _config.R —— scAgent 共享配置与辅助函数                                      ║
# ║                                                                              ║
# ║  目的：消灭全部硬编码绝对路径，让 R 后端可以在任意目录 / 任意挂载约定下运行。    ║
# ║  所有路径均来自环境变量，代码中的默认值只是容器内的约定值。                     ║
# ║                                                                              ║
# ║  环境变量：                                                                   ║
# ║    SCAGENT_DATA_DIR     数据根目录（全部产物的父目录）  默认 /data             ║
# ║    SCAGENT_BACKEND_DIR  R 脚本目录                     默认 /workspace/seurat_backend ║
# ║    SCAGENT_REFDATA_DIR  参考集目录（只读数据卷挂载）     默认 /ref/celldex       ║
# ║                                                                              ║
# ║  注意：本文件名以 `_` 开头，不匹配 api.R 的步骤脚本发现规则 `^[0-9]{2}_.*\.R$`，  ║
# ║        因此不会被当作一个分析步骤加载。                                        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# ── 路径来源 ──────────────────────────────────────────────────────────────────

scagent_data_root <- function() {
  # 与镜像 ENV / docker-compose 保持一致（R2 清理）；compose 会显式覆盖
  Sys.getenv("SCAGENT_DATA_DIR", "/data")
}

scagent_backend_dir <- function() {
  Sys.getenv("SCAGENT_BACKEND_DIR", "/workspace/seurat_backend")
}

scagent_refdata_dir <- function() {
  Sys.getenv("SCAGENT_REFDATA_DIR", "/ref/celldex")
}

#' 取得某个步骤的输出目录（不存在则创建）
scagent_step_dir <- function(name) {
  d <- file.path(scagent_data_root(), name)
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  d
}

# ── 索引文件读写 ──────────────────────────────────────────────────────────────

#' 原子写 JSON：先写临时文件再 rename，避免中途失败留下半截索引
scagent_write_json <- function(x, path) {
  tmp <- paste0(path, ".tmp", Sys.getpid())
  jsonlite::write_json(x, tmp, pretty = TRUE, auto_unbox = TRUE)
  if (!file.rename(tmp, path)) {
    file.remove(tmp)
    stop("索引文件写入失败: ", path)
  }
  invisible(path)
}

#' 读取上游步骤的对象索引
#'
#' QC 步骤写的是 object.json，其余步骤写 seuratobject.json；
#' 这里两种都尝试，调用方无需关心。
#'
#' @return list(ok = TRUE/FALSE, path = , info = ) —— 不抛异常，便于调用方
#'         保持 `return(list(status = "error", ...))` 的既有契约。
scagent_read_index <- function(dir, what = "上游") {
  for (fn in c("seuratobject.json", "object.json")) {
    p <- file.path(dir, fn)
    if (!file.exists(p)) next
    info <- tryCatch(
      jsonlite::fromJSON(p, simplifyVector = FALSE),
      error = function(e) NULL
    )
    if (is.null(info)) {
      return(list(ok = FALSE,
                  message = paste0("索引文件已损坏，无法解析: ", p)))
    }
    return(list(ok = TRUE, path = p, info = info))
  }
  list(ok = FALSE,
       message = paste0(what, "对象索引不存在: ", dir,
                        "（请先运行上游步骤；或用 SCAGENT_DATA_DIR 指定正确的数据根目录）"))
}

#' 由索引解析出 RDS 的绝对路径
#'
#' 优先使用索引中的相对文件名 + 当前数据根目录（可移植）；
#' 若索引是旧格式（只有绝对路径 latest_rds_path），则回退使用它。
scagent_resolve_rds <- function(info, subdir) {
  p <- info$latest_rds_path
  if (!is.null(p) && length(p) == 1 && nzchar(p) && file.exists(p)) {
    return(p)                      # 向后兼容旧索引
  }
  nm <- info$latest_rds
  if (is.null(nm) || length(nm) != 1 || !nzchar(nm)) {
    stop("索引中缺少 latest_rds 字段，无法定位 RDS 文件")
  }
  cand <- file.path(scagent_data_root(), subdir, nm)
  if (!file.exists(cand)) {
    stop("RDS 文件不存在: ", cand,
         "（索引中的相对文件名: ", nm, "；数据根目录: ", scagent_data_root(), "）")
  }
  cand
}

# ── 并发控制 ──────────────────────────────────────────────────────────────────

#' 项目级锁：同一个项目同一时刻只允许一个分析流程
#'
#' Plumber 默认单进程，但两个并发请求仍会各自把 1.6 GB 的 RDS 读进内存；
#' 用文件锁给出明确的中文报错，而不是把机器 OOM 掉。
scagent_with_project_lock <- function(project, expr) {
  lock <- file.path(scagent_data_root(), paste0(".", project, ".lock"))
  dir.create(dirname(lock), showWarnings = FALSE, recursive = TRUE)
  if (file.exists(lock)) {
    info <- tryCatch(readLines(lock, warn = FALSE)[1], error = function(e) "未知")
    stop("项目 ", project, " 正在被另一个请求处理中（加锁于 ", info,
         "），请稍后重试。锁文件: ", lock)
  }
  writeLines(as.character(Sys.time()), lock)
  on.exit(unlink(lock), add = TRUE)
  force(expr)
}

# ── 参考数据 ──────────────────────────────────────────────────────────────────

#' 载入参考集：只读本地数据卷，绝不联网，缺失即报错
#'
#' 参考数据属于「数据」，不属于「软件」—— 不进镜像、不进 registry，
#' 由 scripts/download_data.sh 从对象存储下载后以只读卷挂载。
scagent_load_refdata <- function(species = "mouse") {
  ref_dir  <- scagent_refdata_dir()
  ref_name <- if (identical(species, "human")) {
    "HumanPrimaryCellAtlasData.rds"
  } else {
    "MouseRNAseqData.rds"
  }
  ref_file <- file.path(ref_dir, ref_name)
  if (!file.exists(ref_file)) {
    stop("参考集缺失: ", ref_file,
         "\n该步骤需要参考数据集（由部署者在宿主机一次性下载，之后以只读方式挂载）。",
         "\n请在宿主机执行（按你的系统二选一）：",
         "\n    Windows : deploy\\scagent.cmd refdata               （人类参考集： -Species human）",
         "\n    Linux   : ./scripts/fetch_refdata.sh                （人类参考集： --species human）",
         "\n下载后文件位于 <SCAGENT_BIODATA>/celldex/，容器内只读挂载为 ", ref_dir,
         "；无需重启服务，重新执行本步骤即可。")
  }
  readRDS(ref_file)
}
