# shared_data —— 构建期需要的少量源码包 + 可选的 R 源码包仓（部分）

## 这是什么

- `presto-master.zip` —— **构建必需**，且已入库（`seurat_backend/Dockerfile.runtime` 用它 `remotes::install_local()`；
  `presto` 不在 CRAN 上）。
- 其余 `*.tar.gz` —— 预先下载的 R 源码包，**不属于项目**：不在 git 中（`.gitignore` 已忽略，
  单文件最大 105 MB 也超过 GitHub 限制），也**不参与构建**（`.dockerignore` 把它们排除出上下文，
  镜像里不会有、别人从零 build 也没有）。默认构建全部从 PPM/CRAN/Bioconductor 镜像安装 R 包。
  网络不稳定时的临时缓解手段见 `.local-r-repo/README.md`（本机专用，同样不入库、不进镜像）。

## 镜像构建实际用到什么

```
seurat_backend/Dockerfile.runtime 的 COPY：
    COPY scripts/install_r_deps.R        /tmp/install_r_deps.R
    COPY shared_data/presto-master.zip   /tmp/presto-master.zip     ← 本目录唯一被构建使用的文件
```

本目录的 `*.tar.gz` **不参与构建**；`.dockerignore` 已排除它们，保持构建上下文精简。

## ⚠️ 重要限制：这不是完整依赖闭包

本目录的 `*.tar.gz` 当前包含 **22 个包**，而 scAgent 收敛后的 R 完整依赖闭包是 **108 个包**
（75 CRAN + 29 Bioconductor 软件 + 4 注释/数据）。

因此：

- ✅ **可以**用于补齐若干 Bioconductor 包
- ❌ **不能**单独支撑完整的离线重建（`docker build --network=none` 会失败）


## 正确用法

默认路径是**本机构建镜像**（`./deploy/build.sh` / `deploy\scagent.cmd build`）：
镜像里会装好全部 108 个包，运行期不需要再装任何 R 包。
另有可选的镜像分发路径（自有 registry / 公开发布镜像），服务器只拉取、不构建。

如需生成索引以便 `install.packages(repos="file://...")` 使用：

```bash
Rscript -e 'tools::write_PACKAGES("shared_data", type="source")'
```

## 目录中的其它文件

- `presto-master.zip` —— 见上（构建必需，已入库）。
- `test.txt` —— 容器连通性测试用的小文件。
