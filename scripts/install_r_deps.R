#!/usr/bin/env Rscript
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  scripts/install_r_deps.R —— 构建期安装 R 依赖（含预检与多源回退）            ║
# ║                                                                              ║
# ║  踩过的坑（保留记录以免重蹈）：                                                 ║
# ║    1. ❌ 曾把 Bioconductor 源写成 packagemanager.posit.co/bioconductor/...     ║
# ║           —— 该路径实测全部 404，PPM 不提供这种格式的镜像。                    ║
# ║    2. ❌ 曾写 pak::pkg_install(pkgs, repos = repos)                          ║
# ║           —— **pak 的 pkg_install() 没有 repos 参数**（报 unused argument）。  ║
# ║           pak 从 options(repos) 与 BiocManager 读取仓库，必须用 options() 设置。║
# ║                                                                              ║
# ║  本脚本做的事：                                                                ║
# ║    · 从 BIOC_ROOT 派生 Bioconductor 三个子仓 URL（与 BiocManager 的拼法一致）   ║
# ║    · 对每个仓库先探测 PACKAGES.gz 是否可达（约 20 秒出结果）                    ║
# ║    · 候选源依次回退：优先 PPM 二进制源（免编译、快），失败则用国内镜像（稳）      ║
# ║    · 任一仓库全部不可达时，打印**具体失败的 URL** 与可复制的处置命令             ║
# ║                                                                              ║
# ║  注意：本文件位于 scripts/ 而非 seurat_backend/，                             ║
# ║        否则会被应用层 Dockerfile 的"运行期禁止装包"断言误判为违规。            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

options(timeout = 900, Ncpus = max(1L, parallel::detectCores() - 1L))

bioc_ver <- Sys.getenv("R_BIOC_VERSION", "3.22")
# Bioconductor 镜像根：BiocManager 与我们都按 ${root}/packages/${ver}/${repo} 拼路径
bioc_root <- sub("/+$", "", Sys.getenv("BIOC_ROOT",
                "https://mirrors.westlake.edu.cn/bioconductor"))

# ── 直接依赖清单（17 个）───────────────────────────────────────────────────────
pkgs <- c(
  # CRAN
  "plumber", "Seurat", "jsonlite", "patchwork", "harmony",
  # Bioconductor 软件包
  "SingleR", "celldex", "clusterProfiler", "enrichplot", "GOSemSim",
  "DOSE", "fgsea", "ensembldb", "rtracklayer",
  # Bioconductor 注释数据包（不在软件仓，而在 data/annotation）
  "GO.db", "org.Mm.eg.db", "org.Hs.eg.db"
)

# ── 仓库可达性探测 ────────────────────────────────────────────────────────────
idx_url <- function(base) paste0(sub("/+$", "", base), "/src/contrib/PACKAGES.gz")

repo_ok <- function(base) {
  u <- idx_url(base)
  ok <- tryCatch({
    con <- gzcon(url(u, open = "rb"))
    on.exit(close(con), add = TRUE)
    length(readLines(con, n = 1)) > 0
  }, error = function(e) FALSE, warning = function(w) FALSE)
  cat(sprintf("      [%s] %s\n", if (ok) "OK  " else "FAIL", u))
  ok
}

pick <- function(label, candidates) {
  candidates <- unique(candidates[nzchar(candidates)])
  cat(sprintf("  %s：\n", label))
  for (u in candidates) if (repo_ok(u)) {
    cat(sprintf("      → 采用 %s\n", u))
    return(sub("/+$", "", u))
  }
  stop(sprintf(
    "\n❌ %s 的所有候选源都不可达。失败的 URL：\n    %s\n\n\
  处置建议：\n\
    1) 先在本机验证网络：./scripts/setup-network.sh --verify\n\
    2) 用 --build-arg 指定可用镜像后重试，例如国内环境：\n\
         BIOC_ROOT=https://mirrors.westlake.edu.cn/bioconductor\n\
         PPM_CRAN=https://mirrors.tuna.tsinghua.edu.cn/CRAN\n\
    3) 若公司有内网 CRAN/Bioc 镜像，同样用 build-arg 指向它",
    label, paste(candidates, collapse = "\n    ")), call. = FALSE)
}

pick_optional <- function(label, candidates) {
  tryCatch(pick(label, candidates), error = function(e) {
    cat(sprintf("      ⚠️  %s 不可达，已跳过（不影响安装）\n", label))
    NULL
  })
}

# ── 选择包源 ──────────────────────────────────────────────────────────────────
cat("\n── 探测包源可达性 ──\n")

cran <- pick("CRAN", c(Sys.getenv("PPM_CRAN"),
                       Sys.getenv("CRAN_FALLBACK",
                                  "https://mirrors.tuna.tsinghua.edu.cn/CRAN")))

bioc <- pick("Bioconductor 软件仓 (packages/*/bioc)",
             c(file.path(bioc_root, "packages", bioc_ver, "bioc"),
               file.path("https://bioconductor.org", "packages", bioc_ver, "bioc")))

ann <- pick("Bioconductor 注释仓 (packages/*/data/annotation)",
            c(file.path(bioc_root, "packages", bioc_ver, "data", "annotation"),
              file.path("https://bioconductor.org", "packages", bioc_ver, "data", "annotation")))

exp <- pick_optional("Bioconductor 实验数据仓 (packages/*/data/experiment)",
                     c(file.path(bioc_root, "packages", bioc_ver, "data", "experiment"),
                       file.path("https://bioconductor.org", "packages", bioc_ver, "data", "experiment")))

repos <- c(CRAN = cran, BioCsoft = bioc, BioCann = ann)
if (!is.null(exp)) repos <- c(repos, BioCexp = exp)

# ── 关键：用 options() 设置仓库，而不是给 pkg_install 传 repos= ───────────────
#   pak::pkg_install() **没有 repos 参数**；它从 options(repos) 读取。
#   BioC_mirror 一并设置，便于 BiocManager 派生出同一镜像的子仓 URL。
options(repos = repos)
options(BioC_mirror = bioc_root)

cat("\n── 生效的仓库配置 ──\n")
print(getOption("repos"))
cat("BioC_mirror:", getOption("BioC_mirror"), "\n")

# ── 安装 ──────────────────────────────────────────────────────────────────────
cat(sprintf("\n── 安装 %d 个直接依赖（传递依赖由求解器处理）──\n", length(pkgs)))

installed_ok <- FALSE
tryCatch({
  pak::pkg_install(pkgs)
  installed_ok <- TRUE
}, error = function(e) {
  cat("\n⚠️  pak 安装失败：", conditionMessage(e), "\n")
  cat("    回退到 install.packages()（它确定支持 repos= 参数）…\n\n")
})

if (!installed_ok) {
  # pak 若因仓库解析问题失败，用 base R 的 install.packages 兜底。
  # 它不如 pak 聪明（不做全局求解），但仓库来自 options(repos)，行为确定。
  install.packages(pkgs, repos = getOption("repos"),
                   dependencies = TRUE, Ncpus = getOption("Ncpus", 1L))
}

# ── 校验 ──────────────────────────────────────────────────────────────────────
missing <- setdiff(pkgs, rownames(installed.packages()))
if (length(missing) > 0) {
  stop("以下直接依赖安装后仍未找到：", paste(missing, collapse = ", "), call. = FALSE)
}

total <- length(rownames(installed.packages()))
cat(sprintf("\n✅ 17 个直接依赖全部就绪；镜像内 R 包总数：%d\n", total))
