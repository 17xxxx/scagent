FROM rocker/tidyverse:4.5.2

# ========== [1/8] 系统依赖 ==========
RUN apt-get update && apt-get install -y --no-install-recommends \
    libglpk40 \
    cmake \
    libssl-dev \
    libcurl4-openssl-dev \
    libxml2-dev \
    libhdf5-dev \
    libbz2-dev \
    liblzma-dev \
    && rm -rf /var/lib/apt/lists/*

# ========== 复制全部本地预下载包 ==========
COPY shared_data/BiocBaseUtils_1.12.0.tar.gz \
     shared_data/Biostrings_2.78.0.tar.gz \
     shared_data/DESeq2_1.50.2.tar.gz \
     shared_data/DOSE_4.4.0.tar.gz \
     shared_data/GO.db_3.22.0.tar.gz \
     shared_data/GenomeInfoDb_1.46.2.tar.gz \
     shared_data/HDF5Array_1.38.0.tar.gz \
     shared_data/Rhdf5lib_1.32.0.tar.gz \
     shared_data/Rhtslib_3.6.0.tar.gz \
     shared_data/Rigraphlib_1.2.0.tar.gz \
     shared_data/Rsamtools_2.26.0.tar.gz \
     shared_data/SingleR_2.12.0.tar.gz \
     shared_data/celldex_1.20.0.tar.gz \
     shared_data/clusterProfiler_4.18.4.tar.gz \
     shared_data/ensembldb_2.34.0.tar.gz \
     shared_data/fgsea_1.36.2.tar.gz \
     shared_data/org.Hs.eg.db_3.22.0.tar.gz \
     shared_data/org.Mm.eg.db_3.22.0.tar.gz \
     shared_data/rtracklayer_1.70.1.tar.gz \
     shared_data/DelayedMatrixStats_1.32.0.tar.gz \   
     shared_data/BiocNeighbors_2.4.0.tar.gz \          
     shared_data/beachmat_2.26.0.tar.gz \              
     shared_data/presto-master.zip \
     /tmp/pkgs/

# ========== [2/8] CRAN 包 ==========
RUN R -e "install.packages(c('plumber', 'Seurat', 'jsonlite', 'patchwork', 'harmony'))"

# ========== [3/8] BiocManager ==========
RUN R -e "if(!requireNamespace('BiocManager', quietly=TRUE)) install.packages('BiocManager')"

# ========== [4/8] 基础 Bioconductor 核心包（本地优先）==========
RUN R -e " \
    options(timeout = 6000); \
    # 本地包（无复杂依赖，先装） \
    install.packages('/tmp/pkgs/GenomeInfoDb_1.46.2.tar.gz', repos = NULL, type = 'source'); \
    install.packages('/tmp/pkgs/BiocBaseUtils_1.12.0.tar.gz', repos = NULL, type = 'source'); \
    # 其余小包从 Bioc 下载 \
    BiocManager::install(c( \
        'BiocGenerics', 'S4Vectors', 'IRanges', 'XVector', \
        'Biobase', 'BiocParallel', 'BiocIO' \
    ), ask = FALSE, update = FALSE, dependencies = TRUE, \
    Ncpus = max(1L, parallel::detectCores() - 1L))"

# ========== [5/8] C 库封装（全部本地）==========
RUN R -e " \
    pkgs <- c( \
        '/tmp/pkgs/Rhtslib_3.6.0.tar.gz', \
        '/tmp/pkgs/Rhdf5lib_1.32.0.tar.gz', \
        '/tmp/pkgs/Rigraphlib_1.2.0.tar.gz' \
    ); \
    install.packages(pkgs, repos = NULL, type = 'source')"

# ========== [6/8] 核心工具包（本地优先，注意依赖顺序）==========
RUN R -e " \
    options(timeout = 6000); \
    # 本地包：按依赖顺序安装 \
    # Biostrings → Rsamtools → rtracklayer; HDF5Array 独立 \
    install.packages('/tmp/pkgs/Biostrings_2.78.0.tar.gz', repos = NULL, type = 'source'); \
    install.packages('/tmp/pkgs/Rsamtools_2.26.0.tar.gz', repos = NULL, type = 'source'); \
    install.packages('/tmp/pkgs/rtracklayer_1.70.1.tar.gz', repos = NULL, type = 'source'); \
    install.packages('/tmp/pkgs/HDF5Array_1.38.0.tar.gz', repos = NULL, type = 'source'); \
    # 其余从 Bioc 下载 \
    BiocManager::install(c( \
        'AnnotationDbi', 'SummarizedExperiment', 'SingleCellExperiment' \
    ), ask = FALSE, update = FALSE, dependencies = TRUE, \
    Ncpus = max(1L, parallel::detectCores() - 1L))"

# ========== [6.5/8] SingleR/celldex 关键依赖 ==========
RUN R -e " \
    install.packages('/tmp/pkgs/beachmat_2.26.0.tar.gz', repos = NULL, type = 'source'); \
    install.packages('/tmp/pkgs/BiocNeighbors_2.4.0.tar.gz', repos = NULL, type = 'source'); \
    install.packages('/tmp/pkgs/DelayedMatrixStats_1.32.0.tar.gz', repos = NULL, type = 'source')"

# ========== [7/8] 目标包 + 大数据注释包 ==========
RUN R -e " \
    options(timeout = 6000); \
    # 远程依赖（enrichplot, GOSemSim — 较小，网络通常可成功） \
    BiocManager::install(c('enrichplot', 'GOSemSim'), \
        ask = FALSE, update = FALSE, dependencies = TRUE, \
        Ncpus = max(1L, parallel::detectCores() - 1L)); \
    # 本地包：按依赖顺序安装 \
    install.packages('/tmp/pkgs/GO.db_3.22.0.tar.gz', repos = NULL, type = 'source'); \
    install.packages('/tmp/pkgs/fgsea_1.36.2.tar.gz', repos = NULL, type = 'source'); \
    install.packages('/tmp/pkgs/DOSE_4.4.0.tar.gz', repos = NULL, type = 'source'); \
    install.packages('/tmp/pkgs/ensembldb_2.34.0.tar.gz', repos = NULL, type = 'source'); \
    install.packages('/tmp/pkgs/SingleR_2.12.0.tar.gz', repos = NULL, type = 'source'); \
    install.packages('/tmp/pkgs/DESeq2_1.50.2.tar.gz', repos = NULL, type = 'source'); \
    install.packages('/tmp/pkgs/celldex_1.20.0.tar.gz', repos = NULL, type = 'source'); \
    install.packages('/tmp/pkgs/org.Hs.eg.db_3.22.0.tar.gz', repos = NULL, type = 'source'); \
    install.packages('/tmp/pkgs/org.Mm.eg.db_3.22.0.tar.gz', repos = NULL, type = 'source'); \
    install.packages('/tmp/pkgs/clusterProfiler_4.18.4.tar.gz', repos = NULL, type = 'source'); \
    # 验证关键包 \
    for (pkg in c('SingleR', 'celldex', 'clusterProfiler', 'DESeq2', 'DOSE', 'fgsea')) { \
        if (!requireNamespace(pkg, quietly = TRUE)) stop('FATAL: ', pkg, ' not installed!'); \
    }"

# ========== [8/8] presto（本地离线，依赖 DESeq2 已在第7步预装）==========
RUN R -e " \
    if(!requireNamespace('remotes', quietly=TRUE)) install.packages('remotes'); \
    remotes::install_local('/tmp/pkgs/presto-master.zip', upgrade=FALSE, dependencies=TRUE)" \
    && rm -rf /tmp/pkgs

WORKDIR /workspace
