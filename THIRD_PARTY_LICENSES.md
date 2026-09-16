# 第三方依赖许可证清单

**English**: see the summary at the end of this file. 本文件为中文版（另见文末英文摘要）。

> 数据来源：直接在发布镜像内导出 —— R 侧为 `installed.packages()` 的 `License` 字段
> （`scagent-runtime` / `scagent-seurat`，R 4.5.2 / Bioconductor 3.22），
> Python 侧为 `importlib.metadata`（`scagent-agent`，Python 3.11），
> 系统层为 `dpkg` 与各包的 `copyright` 文件。镜像按 digest 固定（见 `deploy/images.lock`），
> 因此本清单对应的是可追溯的具体镜像内容。
>
> **本项目采用 GPL-3.0**（见 [`LICENSE`](LICENSE)），原因：核心依赖含 GPL-3.0 组件
> （`SingleR`、`celldex`、`harmony`、`presto` 等），且 Docker 镜像会把它们与项目代码装入
> 同一个 R 进程（`api.R` 中 `source()` + `library()`），按 FSF 口径属动态链接而非单纯聚合；
> 采用 GPL-3.0 可消除歧义。

---

## 1. 覆盖范围

| 层 | 内容 | 是否随本仓库分发源码 | 本节位置 |
|---|---|---|---|
| 项目自身代码 | `agent_core/`、`seurat_backend/`、`client/`、`scripts/` | ✅ 是（即本仓库） | `LICENSE`（GPL-3.0） |
| 随仓库分发的第三方源码 | `shared_data/presto-master.zip`（`presto` 1.0.0） | ✅ 是 | §6 |
| **基础镜像** | `rocker/tidyverse:4.5.2`、`python:3.11-slim-bookworm` | ❌ 否（构建时从上游拉取） | §5 |
| **系统包** | apt 显式安装的 8 个库（GLPK / HDF5 / OpenSSL …） | ❌ 否 | §5 |
| **R 包** | 镜像内共 **355 个**（基座自带 + `install_r_deps.R` 另外声明的 18 个直接依赖的闭包） | ❌ 否（构建时从 PPM/CRAN/Bioconductor 获取） | §2 / §3 / §4 |
| **Python 包** | 镜像内 **59 个**（`requirements.lock` 锁定） | ❌ 否 | §3 |

> ⚠️ 常见误解：文档里常提到的"108 个 R 包"指 `install_r_deps.R` **额外安装**的数量；
> 镜像内实际包含 **355 个**（`rocker/tidyverse` 基座已自带大量包）。做许可证审计时请用 355 这个口径。

---

## 2. 传染性许可证（copyleft）

### 2.1 AGPL-3 —— 比 GPL 更严，务必注意

| 包 | 版本 | 许可证 | 来源 | 说明 |
|---|---|---|---|---|
| **fst** | 0.9.8 | `AGPL-3 \| file LICENSE` | CRAN | 传递依赖（Seurat 生态的高性能数据交换） |
| **RhpcBLASctl** | 0.23-42 | `AGPL-3` | CRAN | 传递依赖（BLAS 线程数控制） |

> **为什么单独列**：AGPL-3 比 GPL-3 多一条"通过网络向用户提供服务时也须提供源码"的义务。
> 本项目对这两个包**未作任何修改**，随镜像分发时承担的义务与 GPL 类似（提供源码与许可证），
> 但若将来把它们与项目代码一起修改后再对外提供服务，义务会更严。如需更保守的表述，
> 可把整体许可证口径视作 AGPL-3（见 §7 第 2 条）。

### 2.2 GPL-3 / LGPL

| 包 | 版本 | 许可证 | 用途 |
|---|---|---|---|
| **SingleR** | 2.12.0 | GPL-3 | 细胞类型自动注释（工具 4） |
| **celldex** | 1.20.0 | GPL-3 | SingleR 参考数据集 |
| **harmony** | 2.0.5 | GPL-3 | 批次校正（工具 1 的 Step 8） |
| **presto** | 1.0.0 | GPL-3 | 差异表达 Wilcox/AUC 加速（**源码随本仓库分发**，见 §6） |
| **Rigraphlib** | 1.2.0 | GPL-3 | 图算法库（igraph 依赖） |
| **libglpk40** | 系统包 | `GPL-3+` | GLPK 线性规划（igraph `cluster_*` 依赖） |
| DESeq2 | — | `LGPL (>= 3)` | 传递依赖 |
| Rhtslib | 3.6.0 | `LGPL (>= 2)` | 传递依赖 |
| RSQLite | 2.4.6 | `LGPL (>= 2.1)` | SQLite 接口 |
| survival | 3.8-3 | `LGPL (>= 2)` | 传递依赖 |

镜像内 GPL 家族合计 **124 个包**（GPL-3 50 + GPL-2 55 + "GPL(其它版本)" 7 + GPL-2|GPL-3 双列 12），
LGPL 2 个、AGPL 2 个 —— 完整名单见 §3 的统计口径。

> **注意**：`Seurat` **不是** GPL，而是 **`MIT + file LICENSE`**；`SeuratObject`、`dplyr`、
> `ggplot2`、`plumber`、`patchwork`、`jsonlite`、`scrapper` 同样为 MIT。
> 本项目采用 GPL-3.0 的依据来自上表中的 SingleR / celldex / harmony / presto / libglpk40 等组件，而非 Seurat。

---

## 3. 宽松许可证与统计口径

### 3.1 R 包（355 个）

| 许可证 | 数量 |
|---|---|
| MIT | 144 |
| Artistic-2.0 | 55 |
| GPL-2 | 55 |
| GPL-3 | 50 |
| GPL（其它版本 / `GPL-2 \| GPL-3`） | 7 + 12 |
| Apache-2.0 | 8 |
| BSD（含 BSD_2/3_clause） | 6 |
| MPL-2.0（`data.table` / `fstcore` / `RSpectra`） | 2 + 1 |
| BSL-1.0（`BH` / `polyclip`） | 2 |
| CC（`KernSmooth` 等） | 1 |
| `file LICENSE`（`stringi` / `Rtsne` / 字体包等） | 7 |
| R 自带基础包（`Part of R 4.5.2`） | 13 |
| AGPL-3 | 2 |
| LGPL | 2 |

> `Part of R 4.5.2` 的包（`base` / `stats` / `utils` / `methods` …）随 R 本体发布，
> R 本体采用 `GPL-2 | GPL-3`。`file LICENSE` 表示许可证条款在包内的 `LICENSE` 文件中
> （通常为 MIT/BSD 类，需逐个查看该文件）。

### 3.2 Python 包（59 个）

| 许可证 | 数量 |
|---|---|
| MIT | 18 |
| BSD | 8 |
| Apache-2.0 | 5 |
| MPL-2.0 | 1 |
| **元数据未声明 `License` 字段** | **27** |

主要依赖：`langchain`、`langchain-core`、`langchain-openai`、`langgraph`、`fastapi`、
`uvicorn`、`pydantic`、`httpx`、`openai`、`requests`。

**元数据未声明的 27 个**（这些包实际上是 MIT/BSD/Apache 类，但 `License` 字段为空，
需查其 `License-Expression` / 分类器 / 上游仓库才能确认）：

```
annotated-doc, anyio, click, fastapi, httptools, idna, jiter, langgraph,
langgraph-checkpoint, langgraph-checkpoint-sqlite, langgraph-prebuilt, langgraph-sdk,
packaging, pydantic, pydantic_core, regex, setuptools, starlette, truststore,
typing-inspection, typing_extensions, urllib3, uuid_utils, uvicorn, websockets,
wheel, zstandard
```

> 其中 `zstandard` 上游为 `BSD-3-Clause OR GPL-2.0` 双许可，其余在 Python 生态内以宽松许可证为主。
> 当前**未发现** Python 侧的 GPL/AGPL 强制传染组件。

---

## 4. 直接依赖清单（镜像内版本）

`scripts/install_r_deps.R` 显式声明的 18 个直接依赖，及其在镜像内的实际版本与许可证：

| 包 | 版本 | 许可证 |
|---|---|---|
| Seurat | 5.5.1 | MIT + file LICENSE |
| plumber | 1.3.3 | MIT + file LICENSE |
| jsonlite | 2.0.0 | MIT + file LICENSE |
| patchwork | 1.3.2 | MIT + file LICENSE |
| harmony | 2.0.5 | GPL-3 |
| SingleR | 2.12.0 | GPL-3 |
| celldex | 1.20.0 | GPL-3 |
| clusterProfiler | 4.18.4 | Artistic-2.0 |
| enrichplot | — | Artistic-2.0 |
| GOSemSim | — | Artistic-2.0 |
| DOSE | — | Artistic-2.0 |
| fgsea | — | MIT |
| ensembldb | — | Artistic-2.0 |
| rtracklayer | — | Artistic-2.0 |
| scrapper | 1.4.0 | MIT + file LICENSE |
| GO.db | — | Artistic-2.0 |
| org.Mm.eg.db | — | Artistic-2.0 |
| org.Hs.eg.db | — | Artistic-2.0 |

---

## 5. 基础镜像与系统层

### 5.1 基础镜像

| 基础镜像 | digest（见 `deploy/images.lock`） | 自带内容与许可证 |
|---|---|---|
| `rocker/tidyverse:4.5.2` | `sha256:4813816a…1070a` | Debian + **R 4.5.2 本体（`GPL-2 \| GPL-3`）** + tidyverse 生态（以 MIT 为主）；Rocker 项目自身为 GPL-2/3 |
| `python:3.11-slim-bookworm` | `sha256:528257d4…df84` | Debian + Python 3.11（PSF-2.0） |

### 5.2 显式安装的 apt 包

| 包 | 许可证 | 用途 |
|---|---|---|
| `libglpk40` | **GPL-3+** | GLPK 线性规划（igraph 的社区发现等） |
| `libhdf5-dev` | BSD-3-clause | HDF5（`h5ad` / loom 支持） |
| `libssl-dev` | Apache-2.0 | TLS（Bioconductor 下载与 `httr`） |
| `libcurl4-openssl-dev` | curl（MIT/X 类） | HTTP 客户端 |
| `libxml2-dev` | MIT | XML 解析（`rtracklayer` 等） |
| `cmake` | BSD-3-clause | 部分 R 包的构建 |
| `libbz2-dev` | BSD 变体 | bzip2 压缩 |
| `liblzma-dev` | Public Domain | xz 压缩 |

> 上表之外，基础镜像内还有 Debian 自带的大量系统包（各自许可证随 Debian 分发），
> 完整清单可用 `dpkg-query -W` + `/usr/share/doc/<pkg>/copyright` 获得。

---

## 6. 随仓库分发的第三方源码：`presto`

`shared_data/presto-master.zip`（713 KB）是 **`presto` 1.0.0 的完整上游源码归档**
（GitHub `immunogenomics/presto` 的 `master` 分支快照，98 个条目，**未做任何修改**），
随本仓库一起分发。

之所以入库而不在构建时获取，是因为 `presto` **只发布在 GitHub**（CRAN 与 Bioconductor 均无），
而中国大陆网络访问 GitHub 常出现中断/限速；入库可让构建机在无 GitHub 连通性时仍能完成构建
（`seurat_backend/Dockerfile.runtime` 用 `remotes::install_local()` 直接安装该 zip）。

上游版权与许可（摘自 zip 内 `presto-master/DESCRIPTION`）：

- `Package: presto`，`Version: 1.0.0`，`License: GPL-3`
- 作者：Ilya Korsunsky、Aparna Nathan、Nghia Millard、Soumya Raychaudhuri、
  Kamil Slowikowski（维护者）、Austin Hartman

**合规说明**：GPL-3 要求再分发时随附许可证全文。本项目根本身即为 GPL-3.0，
仓库根的 [`LICENSE`](LICENSE) 就是 GNU GPL-3.0 完整文本，与 `presto` 声明的许可证是同一份；
上游源码保持原样、`DESCRIPTION` 中的版权声明未被移除。

> ⚠️ `presto` 上游仓库自身**未包含独立的 `LICENSE`/`COPYING` 文件**，许可证声明仅位于
> `DESCRIPTION` 的 `License:` 字段。这是上游的状态，本项目原样搬运未作改动；
> 若需向第三方单独再分发该 zip，建议同时附上本仓库的 `LICENSE`。

---

## 7. 各组件的源码位置（再分发时用）

| 组件类别 | 源码位置 |
|---|---|
| CRAN 包（Seurat、harmony、data.table、fst …） | `https://cran.r-project.org/package=<包名>` |
| Bioconductor 包（SingleR、celldex、clusterProfiler、DOSE …） | `https://bioconductor.org/packages/<包名>/` |
| `presto` | 已随本仓库分发：`shared_data/presto-master.zip`（上游 `https://github.com/immunogenomics/presto`） |
| Python 包 | `https://pypi.org/project/<包名>/`（版本见 `agent_core/requirements.lock`） |
| 基础镜像（R / Python / Debian） | Rocker：`https://github.com/rocker-org/rocker`；官方镜像：`https://github.com/docker-library/python` |
| 显式 apt 包 | Debian：`https://packages.debian.org/<发行版>/<包名>`（`apt-get source <包名>` 可取源码） |

---

## 8. 分发注意事项

1. **本项目的 Docker 镜像包含上述 GPL-3.0 / AGPL-3 组件的二进制**。对外分发镜像时，
   GPL 要求提供相应源代码 —— 按 §7 的位置可获得；本项目源码已在仓库中公开，合规成本很低。
   `presto` 的源码**已随本仓库一并分发**，无需另行获取。
2. **两个 AGPL-3 组件**（`fst`、`RhpcBLASctl`）属于传递依赖。当前用法是**未修改地随镜像分发**，
   义务与 GPL 类似（提供源码与许可证文本）；若将来修改它们并以网络服务形式提供，
   需要按 AGPL-3 §13 向使用者提供源码。
3. 若你要**在自己的闭源产品中使用本项目的部分代码**，请注意 GPL-3.0 的传染性：
   与本项目代码链接可能要求你的产品也以 GPL-3.0 发布。
4. 若只需**调用本项目的服务**（HTTP API / `client/scagent.py`），网络调用本身不构成衍生作品
   （AGPL 才有网络服务条款，本项目主体采用 GPL 而非 AGPL）。
5. **只想用本软件做分析、不对外分发**时，无需承担任何再分发义务；但在论文中引用所用到的方法学
   软件（Seurat、SingleR、clusterProfiler、harmony 等）是学术惯例，引用信息见
   [`CITATION.cff`](CITATION.cff) 的 `references` 字段。

---

## English summary

This project is licensed under **GPL-3.0** because its core dependencies include GPL-3.0
components (`SingleR`, `celldex`, `harmony`, `presto`, `libglpk40`) linked into the same
R process as the project code.

- **R image**: 355 R packages — MIT 144, Artistic-2.0 55, GPL-2 55, GPL-3 50, Apache-2.0 8,
  BSD 6, MPL 3, BSL 2, **AGPL-3 2** (`fst`, `RhpcBLASctl`), LGPL 2, CC 1, `file LICENSE` 7,
  part of R 13.
- **Python image**: 59 distributions — MIT 18, BSD 8, Apache-2.0 5, MPL-2.0 1, 27 without a
  declared `License` field (all permissive in practice; no GPL/AGPL found).
- **Base images**: `rocker/tidyverse:4.5.2` (R itself is `GPL-2 | GPL-3`),
  `python:3.11-slim-bookworm` (PSF-2.0); system libs include `libglpk40` (`GPL-3+`).
- **`presto`** (GPL-3) is the only third-party component whose **source** is redistributed
  with this repository (`shared_data/presto-master.zip`, unmodified).
- Redistributing the images triggers GPL/AGPL source-availability obligations; source
  locations are listed in §7. Merely running the software locally triggers none.
