# 保持原有的基础镜像版本[cite: 1]
FROM rocker/tidyverse:4.5.2

# ========== [1/4] 系统依赖 ==========
# 保留你原有的底层系统库[cite: 1]
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

# ========== [2/4] 安装 pak 包管理器 ==========
# 安装 pak，专门用于处理复杂的依赖和恶劣网络环境
RUN R -e "install.packages('pak', repos = 'https://cran.rstudio.com/')"

# 配置 Posit Package Manager (PPM) Linux 二进制源（自动匹配 Ubuntu/R 版本，免编译）
ENV R_REPOS_OPT="https://packagemanager.posit.co/cran/__linux__/jammy/latest"

# ========== [3/4] 核心包全量安装 ==========
# 使用 pak::pkg_install 并发安装清单中的所有包[cite: 1]
# 注意：Bioconductor 包前添加了 'bioc::' 前缀以精准定位
RUN R -e " \
    pak::pkg_install(c( \
        'plumber', 'Seurat', 'jsonlite', 'patchwork', 'harmony', \
        'bioc::BiocBaseUtils', 'bioc::Biostrings', 'bioc::DESeq2', \
        'bioc::DOSE', 'bioc::GO.db', 'bioc::GenomeInfoDb', \
        'bioc::HDF5Array', 'bioc::Rhdf5lib', 'bioc::Rhtslib', \
        'bioc::Rigraphlib', 'bioc::Rsamtools', 'bioc::SingleR', \
        'bioc::celldex', 'bioc::clusterProfiler', 'bioc::ensembldb', \
        'bioc::fgsea', 'bioc::org.Hs.eg.db', 'bioc::org.Mm.eg.db', \
        'bioc::rtracklayer', 'bioc::DelayedMatrixStats', \
        'bioc::BiocNeighbors', 'bioc::beachmat', \
        'bioc::enrichplot', 'bioc::GOSemSim' \
    ))"

# ========== [4/4] 独立安装本地非标包 ==========
COPY shared_data/presto-master.zip /tmp/

# 针对本地 .zip 文件，使用 remotes::install_local 进行解压安装
RUN R -e " \
    if(!requireNamespace('remotes', quietly=TRUE)) install.packages('remotes'); \
    remotes::install_local('/tmp/presto-master.zip', upgrade='never', dependencies=FALSE)" \
    && rm -rf /tmp/*

# ========== [新增] 单独补充 scrapper (利用缓存，避免重装前面的包) ==========
RUN R -e "pak::pkg_install('bioc::scrapper')"

WORKDIR /workspace