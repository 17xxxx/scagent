FROM rocker/tidyverse:4.5.2

# 安装 Seurat 所需的系统依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    libglpk40 \
    && rm -rf /var/lib/apt/lists/*

# 安装 R 包（patchwork=拼图, harmony=批次校正）
RUN R -e "install.packages(c('plumber', 'Seurat', 'jsonlite', 'patchwork', 'harmony'))"

WORKDIR /workspace
