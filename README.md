# scAgent —— AI 驱动的单细胞 RNA 测序分析 Agent

**许可证 / License**：[GPL-3.0](LICENSE) · 引用信息见 [`CITATION.cff`](CITATION.cff)

scAgent 是一个双层架构的 AI 驱动 scRNA-seq 数据分析流水线，由 **Python LangChain/LangGraph AI Agent** 与 **R Seurat 生物信息学后端** 组成，两端通过 HTTP（Plumber API）通信，全程容器化运行。

## 架构概览

```
用户输入（自然语言）
  --> agent_main.py  (LangGraph Agent + DeepSeek LLM)
    --> Agent 决定调用哪个工具
      --> Python @tool 函数
        --> HTTP POST JSON --> seurat:9000/api/execute_task
          --> api.R 分发到对应 R 函数
            --> Seurat 分析 → 输出到 /workspace/data/<step>/
            --> 返回 JSON 结果
          <-- HTTP 响应
        <-- Python 返回结果
      <-- Agent 解读结果
    <-- 回复用户
```

### 技术栈

| 层 | 技术 |
|---|---|
| AI Agent | Python 3.11 + LangChain + LangGraph + DeepSeek V4 |
| 生物信息学 | R 4.5 + Seurat V5 + SingleR + clusterProfiler |
| API 网关 | Plumber (R) |
| 容器化 | Docker Compose + DevContainer |

## 项目结构

```
scagent/
├── agent_core/                  # Python AI Agent
│   ├── agent_main.py            # Agent 入口：模型、中间件、对话循环
│   ├── requirements.txt         # Python 依赖
│   ├── Dockerfile               # Python 容器
│   └── tools/                   # 10 个 LangChain @tool
│       ├── __init__.py          # 工具统一导出
│       ├── _log.py              # API 调用日志
│       ├── check_status_tool.py # 工具0: 流水线进度查询（本地）
│       ├── qc_tool.py           # 工具1: 质控
│       ├── pca_umap_tool.py     # 工具2: PCA/UMAP 降维
│       ├── snn_cluster_tool.py  # 工具3: SNN 聚类
│       ├── cell_annotation_tool.py # 工具4: 细胞注释
│       ├── dimplot_tool.py      # 工具5: 散点图可视化
│       ├── marker_viz_tool.py   # 工具6: 标记基因可视化
│       ├── cell_ratio_tool.py   # 工具7: 细胞比例图
│       ├── heatmap_tool.py      # 工具8: 热图
│       └── enrichment_tool.py   # 工具9: GO 富集分析
├── seurat_backend/              # R 生物信息学后端
│   ├── api.R                    # Plumber API 网关 (端口 9000)
│   ├── Dockerfile               # R 容器（含完整 Bioconductor 依赖）
│   ├── run_test.R               # 自检脚本
│   ├── 01_qc.R                  # 质控（8步流水线：Read10X → Harmony）
│   ├── 02_pca_umap.R            # PCA 降维 + UMAP 可视化
│   ├── 03_snn_cluster.R         # SNN 图聚类分群
│   ├── 04_cell_annotation.R     # FindAllMarkers + SingleR 自动注释
│   ├── 05_dimplot.R             # 多分组散点图
│   ├── 06_marker_viz.R          # 小提琴图 + 气泡图
│   ├── 07_cell_ratio.R          # 细胞比例堆叠柱状图
│   ├── 08_heatmap.R             # 标记基因热图
│   └── 09_enrichment.R          # GO 功能富集分析
├── shared_data/                 # R 包离线安装包（22个）
├── .devcontainer/               # VS Code DevContainer 配置
│   ├── devcontainer.json
│   └── docker-compose.yml       # agent + seurat 双服务编排
└── TOOLS_HELP.txt               # 工具参数参考文档
```

## 快速开始

### 前置条件

- Docker + Docker Compose
- VS Code + Dev Containers 扩展（推荐）

### 1. 准备数据

将 10X 格式的原始数据放入 `data/rawdata/` 目录，每个样本一个子文件夹，文件夹内直接存放三个文件：

```
data/rawdata/
├── sample1/
│   ├── barcodes.tsv.gz
│   ├── features.tsv.gz
│   └── matrix.mtx.gz
├── sample2/
│   ├── barcodes.tsv.gz
│   ├── features.tsv.gz
│   └── matrix.mtx.gz
└── ...
```

### 2. 准备密钥

密钥**不通过 `.env` 注入容器**，而是生成到项目目录之外，再以 Docker secrets
文件形式挂载 —— 这样密钥不会出现在 `docker inspect`、镜像层或环境变量中。

```bash
./scripts/setup_secrets.sh          # 交互式索取，写入权限 600 的文件
```

产出（默认在 `~/.config/scagent/`）：

| 文件 | 内容 |
|---|---|
| `deepseek_api_key` | LLM API Key（形如 `sk-...`） |
| `scagent_token` | 客户端访问令牌，**必填** —— 缺失时 `server.py` 拒绝启动 |

> **为什么必须放在项目外**：开发编排挂载了整个仓库（`..:/workspace`），
> 放在项目内的密钥文件会随挂载进入容器，secrets 就失去意义。
>
> 已有 `.env` 时脚本会自动从中读取；`--check` 只检查现状不写文件。
> 容器内实际读取的是 `SCAGENT_LLM_API_KEY_FILE` / `SCAGENT_TOKEN_FILE`
> 指向的这两个文件（见 `.devcontainer/docker-compose.yml`）。

### 3. 构建镜像（首次约 30–90 分钟）

镜像分两层，`seurat_backend/Dockerfile` 的 `FROM` 指向 runtime 镜像，
**必须先构建 runtime 层** —— 直接 `docker compose build` 会因基础镜像不存在而失败：

```bash
./scripts/dev_build.sh              # 首次：runtime + 应用层
./scripts/dev_build.sh --app-only   # 之后只改了 R/Python 代码：数秒完成
```

### 4. 启动容器

在 VS Code 中打开项目，点击左下角绿色按钮选择 "Reopen in Container"，或手动启动：

```bash
docker compose -f .devcontainer/docker-compose.yml up -d
```

### 5. 运行

容器默认 `sleep infinity` 常驻，服务需手动启动。按需选择入口：

```bash
DC="docker compose -f .devcontainer/docker-compose.yml"

# A. HTTP 服务 + 网页界面 → http://127.0.0.1:8080
$DC exec agent python /workspace/agent_core/server.py

# B. 本地交互式 CLI（开发 / 调试用）
$DC exec agent python /workspace/agent_core/agent_main.py

# C. 确定性流水线（无需 LLM、无需 API Key）
$DC exec agent python /workspace/agent_core/pipeline_cli.py status
```

> 网页界面首次打开会要求输入 `scagent_token` 的内容作为访问令牌。

> ⚠️ **关于 `.env`**：只有 `agent_main.py` 会通过 `load_dotenv()` 读取项目根的
> `.env`；`server.py`、`pipeline_cli.py` 和 `docker compose` 都**不读取** `.env`。
> 因此 `.env` 仅适合本地调试，正式配置请一律走第 2 步的 secrets。

## 使用方式

进入交互式对话后，直接用自然语言描述分析需求：

```
> 帮我做质控
> 做 PCA 降维和 UMAP 可视化
> 用 Leiden 算法聚类，resolution 设 0.8
> 用小鼠参考做细胞类型注释
> 画细胞类型的 UMAP 图
> 查看当前流水线进度
```

### 内置命令

| 命令 | 功能 |
|---|---|
| `quit` | 退出对话 |
| `new` | 新建会话 |
| `history` | 查看当前会话历史 |

### Human-in-the-Loop（人机协同）

每次工具调用前，系统会展示工具名称和参数，要求人工确认：

```
⚠️ [HITL 拦截] 准备执行分析工具 run_qc_for_all_samples
  工具名称: run_qc_for_all_samples
  预设参数: {}
  请确认 (y: 允许 / n: 拒绝):
```

## 分析流水线

```
[工具1] 质控 (QC)
  ├─ Read10X 导入
  ├─ 元数据添加（MT%、核糖体%）
  ├─ QC 可视化
  ├─ 过滤合并
  ├─ LogNormalize
  ├─ 高变基因筛选
  ├─ ScaleData
  └─ PCA + Harmony 批次校正
      │
      ▼
[工具2] PCA/UMAP 降维
  ├─ ElbowPlot
  ├─ RunUMAP
  └─ DimPlot 可视化
      │
      ▼
[工具3] SNN 聚类
  ├─ FindNeighbors
  └─ FindClusters (Louvain/Leiden)
      │
      ▼
[工具4] 细胞类型注释
  ├─ FindAllMarkers
  └─ SingleR 自动注释
      │
      ▼
[工具5-9] 可视化（均依赖工具4输出）
  ├─ DimPlot 散点图
  ├─ 标记基因小提琴图+气泡图
  ├─ 细胞比例堆叠图
  ├─ 标记基因热图
  └─ GO 功能富集分析
```

- 工具 1-4 必须**按顺序执行**，前一步成功后才能调用下一步
- 工具 5-9 为独立可视化，均依赖工具 4 的输出
- 不确定当前进度时，先调用 `check_pipeline_status`

## 中间件

Agent 内置三层中间件：

| 中间件 | 功能 |
|---|---|
| `SummarizationMiddleware` | 消息 tokens 超阈值时自动摘要压缩，保留最近 N 条原文 |
| `ToolCallLimitMiddleware` | 每次调用最多执行 2 次工具，防止循环失控 |
| `HumanInTheLoopMiddleware` | 每次工具调用前需人工 `y/n` 确认参数 |

## 输出结构

所有分析结果输出到 `data/` 目录：

```
data/
├── qc/                    # 质控输出
│   ├── object.json        # 索引文件
│   ├── {project}_qc_*.pdf # QC 可视化
│   └── {project}_qc.rds   # Seurat 对象
├── pca_umap/              # 降维输出
├── snn_cluster/           # 聚类输出
├── cell_annotation/       # 注释输出
│   ├── seuratobject.json
│   ├── {project}_annotated.rds
│   ├── {project}_cluster_markers.csv
│   ├── {project}_cluster_markers.rds
│   └── {project}_umap_celltype.pdf
├── dimplot/               # 散点图
├── marker_viz/            # 标记基因可视化
├── cell_ratio/            # 比例图
├── heatmap/               # 热图
└── enrichment/            # GO 富集
```

---

## ⚠️ 免责声明

**本工具仅供科研参考，不应用于直接的临床诊断或医疗决策。**

- 所有分析结果（细胞类型注释、聚类、富集等）均为**计算推断**，未经实验验证
- 使用者需自行确保输入数据的**合规性与隐私安全**（样本知情同意、伦理审批、
  人类遗传资源管理、GDPR/《个人信息保护法》等适用的法规要求）
- 本项目不收集、不上传任何数据；全部分析在自建环境中完成，
  唯一的外部调用是 LLM API（可通过 `SCAGENT_LLM_PROVIDER=none` 完全关闭）
- 作者不对使用本工具产生的任何后果承担责任

## 依赖许可证

本项目的**核心生信依赖包含 GPL-3.0 组件**（Seurat、SingleR、celldex 等），
因此本项目采用 **GPL-3.0** 授权以保持一致。

完整的依赖许可证清单（含 GPL/LGPL 传染性组件的标注）见
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md)。
**分发本项目的 Docker 镜像时，请一并遵守其中列出的第三方许可证条款。**

## 许可证

[GNU General Public License v3.0](LICENSE) (GPL-3.0)

## 引用

若本项目对你的研究有帮助，欢迎引用。机器可读的引用信息见
[`CITATION.cff`](CITATION.cff)（GitHub 侧栏会显示 "Cite this repository"），
作者与版权信息见 [`AUTHORS`](AUTHORS)。
