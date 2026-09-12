#!/usr/bin/env Rscript
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  scripts/install_r_deps.R —— 构建期安装 R 依赖（含预检与多源回退）            ║
# ║                                                                              ║
# ║  为什么单独成脚本：                                                            ║
# ║    1. 原实现在 Dockerfile 里用 Sys.getenv('PPM_CRAN') 取源地址，而             ║
# ║       PPM 的 Bioconductor 地址是**凭猜测写的、实际 404**，导致构建必然失败。    ║
# ║    2. 内联在 RUN 里无法加"先探测、再选择"的逻辑，网络问题要等 40 分钟才暴露。   ║
# ║                                                                              ║
# ║  本脚本做的事：                                                                ║
# ║    · 对每个仓库先探测 PACKAGES.gz 是否可达（20 秒内出结果）                     ║
# ║    · 候选源依次回退：优先 PPM 二进制源（快），失败则用国内镜像（稳）             ║
# ║    · 任一仓库全部不可达时，打印**具体是哪个 URL 失败**并给出可执行的处置建议      ║
# ║                                                                              ║
# ║  注意：本文件位于 scripts/ 而不是 seurat_backend/，                          ║
# ║        否则会被应用层 Dockerfile 的"运行期禁止装包"断言误判为违规。            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

options(timeout = 900, Ncpus = max(1L, parallel::detectCores() - 1L))

bioc_ver <- Sys.getenv("R_BIOC_VERSION", "3.22")

# ── 直接依赖清单（17 个）───────────────────────────────────────────────────────
# 刻意不加 `bioc::` 前缀：repos 里已同时提供 CRAN 与 Bioconductor 各子仓，
# 让 pak 自行在各仓中查找，比前缀解析更稳。
pkgs <- c(
  # CRAN
  "plumber", "Seurat", "jsonlite", "patchwork", "harmony",
  # Bioconductor 软件包
  "SingleR", "celldex", "clusterProfiler", "enrichplot", "GOSemSim",
  "DOSE", "fgsea", "ensembldb", "rtracklayer",
  # Bioconductor 注释数据包（注意：这三个不在 bioc 软件仓，而在 data/annotation）
  "GO.db", "org.Mm.eg.db", "org.Hs.eg.db"
)

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
  candidates <- candidates[nzchar(candidates)]
  cat(sprintf("  %s：\n", label))
  for (u in candidates) if (repo_ok(u)) {
    cat(sprintf("      → 采用 %s\n", u))
    return(u)
  }
  stop(sprintf(
    "\n❌ %s 的所有候选源都不可达。失败的 URL：\n    %s\n\n\
  处置建议：\n\
    1) 先在本机验证网络：./scripts/setup-network.sh --verify\n\
    2) 国内环境可显式指定镜像（用 --build-arg 覆盖）：\n\
         --build-arg BIOC_MIRROR=https://mirrors.westlake.edu.cn/bioconductor/packages/%s/bioc\n\
         --build-arg BIOC_ANN_MIRROR=https://mirrors.westlake.edu.cn/bioconductor/packages/%s/data/annotation\n\
         --build-arg BIOC_EXP_MIRROR=https://mirrors.westlake.edu.cn/bioconductor/packages/%s/data/experiment\n\
         --build-arg PPM_CRAN=https://mirrors.tuna.tsinghua.edu.cn/CRAN\n\
    3) 若公司有内网 CRAN/Bioc 镜像，同样用上面的 build-arg 指向它",
    label, paste(candidates, collapse = "\n    "),
    bioc_ver, bioc_ver, bioc_ver), call. = FALSE)
}

# 实验数据仓不是安装所必需（celldex 的参考数据是运行期从数据卷读的），
# 因此探测失败只告警、不中断。
pick_optional <- function(label, candidates) {
  tryCatch(pick(label, candidates), error = function(e) {
    cat(sprintf("      ⚠️  %s 不可达，已跳过（不影响安装）\n", label))
    NULL
  })
}

# ── 选择包源 ──────────────────────────────────────────────────────────────────
cat("\n── 探测包源可达性 ──\n")
cran <- pick("CRAN", c(Sys.getenv("PPM_CRAN"), Sys.getenv("CRAN_FALLBACK")))
bioc <- pick("Bioconductor 软件仓 (bioc)",
             c(Sys.getenv("BIOC_MIRROR"), Sys.getenv("BIOC_FALLBACK")))
ann  <- pick("Bioconductor 注释仓 (data/annotation)",
             c(Sys.getenv("BIOC_ANN_MIRROR"), Sys.getenv("BIOC_ANN_FALLBACK")))
exp  <- pick_optional("Bioconductor 实验数据仓 (data/experiment)",
                      c(Sys.getenv("BIOC_EXP_MIRROR"), Sys.getenv("BIOC_EXP_FALLBACK")))

repos <- c(CRAN = cran, BioCsoft = bioc, BioCann = ann)
if (!is.null(exp)) repos <- c(repos, BioCexp = exp)

cat("\n── 最终使用的仓库 ──\n")
print(repos)

# ── 安装 ──────────────────────────────────────────────────────────────────────
cat(sprintf("\n── 安装 %d 个直接依赖（传递依赖由求解器处理）──\n", length(pkgs)))
pak::pkg_install(pkgs, repos = repos)

# ── 校验 ──────────────────────────────────────────────────────────────────────
missing <- setdiff(pkgs, rownames(installed.packages()))
if (length(missing) > 0) {
  stop("以下直接依赖安装后仍未找到：", paste(missing, collapse = ", "), call. = FALSE)
}

total <- length(rownames(installed.packages()))
cat(sprintf("\n✅ 17 个直接依赖全部就绪；镜像内 R 包总数：%d\n", total))
