# 第三方依赖许可证清单

> 本清单由 `shared_data/*.tar.gz` 中 22 个 R 包的 `DESCRIPTION` 文件**实测导出**
> （2026-09，Bioconductor 3.22 / R 4.5.2），外加随仓库分发的
> `shared_data/presto-master.zip` 内的 `DESCRIPTION`；Python 侧由镜像内包元数据导出。
>
> **本项目采用 GPL-3.0**（见 `LICENSE`），原因：核心生信依赖含 GPL-3.0 组件，
> 且 Docker 镜像会把它们与项目代码装入同一个 R 进程（`api.R` 中 `source()` +
> `library()`），按 FSF 口径属动态链接而非单纯聚合，采用 GPL-3.0 可消除歧义。

## ⚠️ 传染性许可证（copyleft）

| 包 | 许可证 | 用途 | 影响 |
|---|---|---|---|
| **SingleR** | **GPL-3** | 细胞类型自动注释（工具 4） | 强 copyleft |
| **celldex** | **GPL-3** | SingleR 参考数据集 | 强 copyleft |
| BiocNeighbors | GPL-3 | SingleR 依赖 | 强 copyleft |
| beachmat | GPL-3 | SingleR/celldex 依赖 | 强 copyleft |
| Rigraphlib | GPL-3 | 图算法库 | 强 copyleft |
| DESeq2 | LGPL (>= 3) | 传递依赖 | 弱 copyleft |
| Rhtslib | LGPL (>= 2) | 传递依赖 | 弱 copyleft |
| **presto** | **GPL-3** | 差异表达 Wilcox/AUC 加速 | 强 copyleft，**源码随本仓库分发** |

> **已实测**：`presto` 的许可证字段于 2026-09 直接从
> `shared_data/presto-master.zip` 内的 `DESCRIPTION` 导出，结果为 `License: GPL-3`。
>
> **待核查**：`Seurat`、`harmony` 不在 `shared_data/` 中，尚未导出其许可证字段。
> 按公开信息，**Seurat 通常为 GPL-3**。建议在含 R 的环境中执行以下命令补齐：
> ```r
> for (p in c("Seurat","harmony","plumber","patchwork","jsonlite"))
>   cat(p, as.character(packageDescription(p)$License), "\n")
> ```

## 无传染性（宽松许可证）

| 包 | 许可证 |
|---|---|
| clusterProfiler | Artistic-2.0 |
| GO.db / org.Hs.eg.db / org.Mm.eg.db | Artistic-2.0 |
| Biostrings / GenomeInfoDb / HDF5Array / Rhdf5lib | Artistic-2.0 |
| Rsamtools / rtracklayer / BiocBaseUtils / DOSE | Artistic-2.0 |
| DelayedMatrixStats | MIT |
| fgsea | MIT |

## Python 依赖

实测镜像内 59 个包，许可证分布：**MIT（14）、BSD（7）、Apache-2.0（5）、
MPL-2.0（1）**，其余元数据未声明 `License` 字段（27 个，需逐个核查，
但 Python 生态在此依赖集内以宽松许可证为主，**未发现 GPL/AGPL**）。

主要依赖：`langchain` / `langgraph` / `langchain-openai` / `fastapi` / `uvicorn`
/ `pydantic` / `httpx` / `openai`。

## 随仓库分发的第三方源码：`presto`

`shared_data/presto-master.zip`（713 KB）是 **`presto` 1.0.0 的完整上游源码归档**
（GitHub `immunogenomics/presto` 的 `master` 分支快照，98 个条目，**未做任何修改**），
随本仓库一起分发。

之所以入库而不在构建时从 CRAN/Bioconductor 获取，是因为 `presto` **只发布在 GitHub**，
CRAN 与 Bioconductor 均无该包；中国大陆网络访问 GitHub 常出现中断/限速，
入库可让构建机在无 GitHub 连通性时仍能完成镜像构建
（`seurat_backend/Dockerfile.runtime:79` 用 `remotes::install_local()` 直接安装该 zip）。

上游版权与许可（实测摘自 zip 内 `presto-master/DESCRIPTION`）：

- `Package: presto`，`Version: 1.0.0`
- `License: GPL-3`
- 作者：Ilya Korsunsky、Aparna Nathan、Nghia Millard、Soumya Raychaudhuri、
  Kamil Slowikowski（维护者）、Austin Hartman

**合规说明**：GPL-3 要求再分发时随附许可证全文。本项目根本身即为 GPL-3.0，
仓库根的 [`LICENSE`](LICENSE) 就是 **GNU GPL-3.0 完整文本**（674 行），
与 `presto` 声明的许可证是同一份，因此该要求在仓库层面已满足；
上游源码保持原样、`DESCRIPTION` 中的版权声明未被移除。

> ⚠️ 注意：`presto` 上游仓库自身**未包含独立的 `LICENSE`/`COPYING` 文件**，
> 其许可证声明仅位于 `DESCRIPTION` 的 `License:` 字段。这是上游的状态，
> 本项目原样搬运未作改动；若需向第三方单独再分发该 zip，建议同时附上本仓库的
> `LICENSE`。

## 分发注意事项

1. **本项目的 Docker 镜像包含上述 GPL-3.0 组件的二进制**。对外分发镜像时，
   GPL-3.0 要求提供相应源代码 —— 这些组件的源码可从 CRAN/Bioconductor 获取，
   本项目源码已在仓库中公开，合规成本很低。
   其中 `presto` 的源码**已随本仓库一并分发**
   （`shared_data/presto-master.zip`，见上一节），无需另行获取。
2. 若你要**在自己的闭源产品中使用本项目的部分代码**，请注意 GPL-3.0 的传染性：
   与本项目代码链接可能要求你的产品也以 GPL-3.0 发布。
3. 若只需**调用本项目的服务**（HTTP API / `client/scagent.py`），
   客户端代码为纯标准库且同样在 GPL-3.0 下发布，网络调用本身不构成衍生作品
   （AGPL 才有网络服务条款，本项目用的是 GPL 而非 AGPL）。
