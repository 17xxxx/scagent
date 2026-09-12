# scAgent —— AI 驱动的单细胞 RNA 测序分析 Agent

> ⚠️ **本 README 部分内容已过时。** 请优先阅读：
> - `docs/CHANGELOG.md` —— 本轮改造全量记录 + 剩余待办
> - `docs/PROD_HANDOVER.md` —— 开发 → 生产交付手册
> - `docs/CLOUD_DEPLOY_PLAN.md` —— 架构方案

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

### 2. 配置环境变量

在项目根目录创建 `.env` 文件：

```env
DEEPSEEK_API_KEY=your_api_key_here
DEEPSEEK_BASE_URL=https://api.deepseek.com/v1
MAX_HISTORY_TOKENS=6000
KEEP_RECENT_MESSAGES=10
```

### 3. 启动容器

在 VS Code 中打开项目，点击左下角绿色按钮选择 "Reopen in Container"，或手动启动：

```bash
docker compose -f .devcontainer/docker-compose.yml up -d
```

### 4. 启动 Agent

```bash
cd agent_core
python agent_main.py
```

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
