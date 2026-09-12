# shared_data —— R 源码包离线仓（部分）

## 这是什么

预先下载的 R 源码包（.tar.gz），用途是在无法访问 CRAN/Bioconductor 的机器上
尝试离线安装。

## ⚠️ 重要限制：这不是完整依赖闭包

本目录当前包含 **22 个包**，而 scAgent 收敛后的 R 完整依赖闭包是 **108 个包**
（75 CRAN + 29 Bioconductor 软件 + 4 注释/数据）。

因此：

- ✅ **可以**用于补齐若干 Bioconductor 包
- ❌ **不能**单独支撑完整的离线重建（`docker build --network=none` 会失败）

完整论证见 `docs/VENDORING_AUDIT.md` 与 `docs/TARGET_STATE_REVIEW.md` §4.7。

## 正确用法

主分发路径是**私有 registry 中的镜像** —— 镜像里已经装好了全部 108 个包，
服务器不需要再装任何 R 包（见 `docs/CLOUD_DEPLOY_PLAN.md` §8）。

如需生成索引以便 `install.packages(repos="file://...")` 使用：

```bash
Rscript -e 'tools::write_PACKAGES("shared_data", type="source")'
```

## 目录中的其它文件

- `presto-master.zip` —— Seurat 用于加速 Wilcoxon 检验的包，不在 CRAN 上，
  由 `seurat_backend/Dockerfile.runtime` 通过 `remotes::install_local()` 安装。
- `test.txt` —— 早期容器连通性测试的遗留文件。
