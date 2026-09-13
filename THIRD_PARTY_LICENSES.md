# 第三方依赖许可证清单

> 本清单由 `shared_data/*.tar.gz` 中 22 个 R 包的 `DESCRIPTION` 文件**实测导出**
> （2026-09，Bioconductor 3.22 / R 4.5.2），Python 侧由镜像内包元数据导出。
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

> **待核查**：`Seurat`、`harmony`、`presto` 三个包不在 `shared_data/` 中，
> 尚未导出其许可证字段。按公开信息，**Seurat 与 presto 通常为 GPL-3**。
> 建议在含 R 的环境中执行以下命令补齐：
> ```r
> for (p in c("Seurat","harmony","presto","plumber","patchwork","jsonlite"))
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

## 分发注意事项

1. **本项目的 Docker 镜像包含上述 GPL-3.0 组件的二进制**。对外分发镜像时，
   GPL-3.0 要求提供相应源代码 —— 这些组件的源码可从 CRAN/Bioconductor 获取，
   本项目源码已在仓库中公开，合规成本很低。
2. 若你要**在自己的闭源产品中使用本项目的部分代码**，请注意 GPL-3.0 的传染性：
   与本项目代码链接可能要求你的产品也以 GPL-3.0 发布。
3. 若只需**调用本项目的服务**（HTTP API / `client/scagent.py`），
   客户端代码为纯标准库且同样在 GPL-3.0 下发布，网络调用本身不构成衍生作品
   （AGPL 才有网络服务条款，本项目用的是 GPL 而非 AGPL）。
