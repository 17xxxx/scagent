# scAgent — AI-driven single-cell RNA-seq analysis agent

**English** · **[简体中文](README.zh-CN.md)**

**License**: [GPL-3.0](LICENSE) · Citation info: [`CITATION.cff`](CITATION.cff)

scAgent is a two-tier, AI-driven scRNA-seq analysis pipeline: a **Python LangChain/LangGraph agent** drives an **R / Seurat backend** over HTTP (Plumber API). Everything runs in containers.

## Architecture

```
User input (natural language)
  --> agent_main.py  (LangGraph agent + DeepSeek LLM)
    --> The agent picks a tool
      --> Python @tool function
        --> HTTP POST JSON --> seurat:9000/api/execute_task
          --> api.R dispatches to the matching R function
            --> Seurat analysis → writes to /workspace/data/<step>/
            --> returns a JSON result
          <-- HTTP response
        <-- Python returns the result
      <-- The agent interprets the result
    <-- Reply to the user
```

### Tech stack

| Layer | Technology |
|---|---|
| AI agent | Python 3.11 + LangChain + LangGraph + DeepSeek V4 |
| Bioinformatics | R 4.5 + Seurat V5 + SingleR + clusterProfiler |
| API gateway | Plumber (R) |
| Containerization | Docker Compose + Dev Container |

## Project layout

```
scagent/
├── agent_core/                  # Python AI agent
│   ├── agent_main.py            # Entry point: model, middleware, chat loop
│   ├── requirements.txt         # Python dependencies
│   ├── Dockerfile               # Python container
│   └── tools/                   # 10 LangChain @tools
│       ├── __init__.py          # Tool exports
│       ├── _log.py              # API call logging
│       ├── check_status_tool.py # Tool 0: pipeline status (local)
│       ├── qc_tool.py           # Tool 1: quality control
│       ├── pca_umap_tool.py     # Tool 2: PCA / UMAP
│       ├── snn_cluster_tool.py  # Tool 3: SNN clustering
│       ├── cell_annotation_tool.py # Tool 4: cell type annotation
│       ├── dimplot_tool.py      # Tool 5: scatter plots
│       ├── marker_viz_tool.py   # Tool 6: marker gene visualization
│       ├── cell_ratio_tool.py   # Tool 7: cell ratio plots
│       ├── heatmap_tool.py      # Tool 8: heatmaps
│       └── enrichment_tool.py   # Tool 9: GO enrichment
├── seurat_backend/              # R bioinformatics backend
│   ├── api.R                    # Plumber API gateway (port 9000)
│   ├── Dockerfile               # R container (full Bioconductor stack)
│   ├── run_test.R               # Self-check script
│   ├── 01_qc.R                  # QC (8 steps: Read10X → Harmony)
│   ├── 02_pca_umap.R            # PCA reduction + UMAP
│   ├── 03_snn_cluster.R         # SNN graph clustering
│   ├── 04_cell_annotation.R     # FindAllMarkers + SingleR annotation
│   ├── 05_dimplot.R             # Grouped scatter plots
│   ├── 06_marker_viz.R          # Violin + dot plots
│   ├── 07_cell_ratio.R          # Stacked cell-ratio bar charts
│   ├── 08_heatmap.R             # Marker gene heatmaps
│   └── 09_enrichment.R          # GO functional enrichment
├── shared_data/                 # Build-time sources: presto-master.zip (required); other *.tar.gz are local-only, not in git
├── .devcontainer/               # VS Code Dev Container setup
│   ├── devcontainer.json
│   └── docker-compose.yml       # agent + seurat services
├── DEPLOY.md                    # Deployment guide (deployers) — Chinese
├── DEVELOPMENT.md               # Development environment (developers) — Chinese
├── FAQ.md                       # Troubleshooting — Chinese
└── TOOLS_HELP.txt               # Tool parameter reference
```

## Quick start

> Four steps for deployers. Per-step details, Windows commands and troubleshooting are in
> **[DEPLOY.md](DEPLOY.md)** (Chinese).

| Step | What | Command |
|---|---|---|
| ① Get the code | `git clone` (do not download a ZIP — the reason is in the FAQ) | `git clone <repo-url> scagent` |
| ② Configure | Generates the config and the secrets — **this is where you paste the LLM API key** | Linux: `./deploy/configure.sh`<br>Windows: `deploy\install.cmd` |
| ③ Start | Pull (or build) the images and start the services — Windows `install` already covers this | Linux: `./deploy/up.sh`<br>Windows: `deploy\scagent.cmd up` |
| ④ Add data and use | Put the 10X data under the workspace, then open the browser and paste the access token | see [DEPLOY.md](DEPLOY.md) §5 |

> **Skip the 30–90 minute first build** by using the published images: add one flag in step ②.
>
> ```bash
> # Linux / WSL
> ./deploy/configure.sh --image-source public --image-prefix ghcr.io/17xxxx/scagent
> ```
>
> ```powershell
> # Windows
> deploy\install.cmd -ImageSource public -ImagePrefix ghcr.io/17xxxx/scagent
> ```
>
> Without `-ImageSource` / `--image-source` the default is a **local build** (`local`, 30–90 minutes
> on the first run); on Windows `install.cmd` does not ask for the image source at all.

Three things worth knowing up front:

- **LLM API key** — asked for in step ②, stored in `<install-root>/secrets/deepseek_api_key`
  (a standalone file, never written into `.env`); **the service will not start without it**.
- **Where the data goes** — `<install-root>/workspace/data/rawdata/<sample>/`: one sub-directory per
  sample, with the `barcodes` / `features` / `matrix` files directly inside. **It is not** the `data/`
  directory inside the repository.
- **Access token** — `scagent_token` in the same directory; paste its contents on the first browser visit.

## Documentation

| Document | Audience | Contents |
|---|---|---|
| [DEPLOY.md](DEPLOY.md) | deployers | deployment overview, image sources, configuration, data placement, operations, command reference **(Chinese)** |
| [FAQ.md](FAQ.md) | deployers / users | troubleshooting, organised as "symptom → cause → fix" **(Chinese)** |
| [DEVELOPMENT.md](DEVELOPMENT.md) | developers | Dev Container workflow, directory conventions, build & run entry points, self-checks, publishing images **(Chinese)** |
| [TOOLS_HELP.txt](TOOLS_HELP.txt) | users / developers | parameter reference for the 10 tools |

## Usage

Inside the interactive session, describe what you want in natural language. English and Chinese
prompts both work (the agent's replies and the built-in web UI are currently in Chinese):

```
> run quality control
> do PCA and UMAP
> cluster with Leiden, resolution 0.8
> annotate cell types using the mouse reference
> plot the cell-type UMAP
> show the current pipeline status
```

### Built-in commands

| Command | Purpose |
|---|---|
| `quit` | Exit the session |
| `new` | Start a new session |
| `history` | Show the current session history |

### Human-in-the-loop

Before every tool call, the tool name and its parameters are shown for manual confirmation:

```
⚠️ [HITL 拦截] 准备执行分析工具 run_qc_for_all_samples
  工具名称: run_qc_for_all_samples
  预设参数: {}
  请确认 (y: 允许 / n: 拒绝):
```

*(shown exactly as the current build prints it — the built-in UI is in Chinese)*

## Analysis pipeline

```
[Tool 1] Quality control
  ├─ Read10X import
  ├─ Metadata (MT%, ribosomal%)
  ├─ QC visualisation
  ├─ Filtering + merging
  ├─ LogNormalize
  ├─ Variable feature selection
  ├─ ScaleData
  └─ PCA + Harmony batch correction
      │
      ▼
[Tool 2] PCA / UMAP
  ├─ ElbowPlot
  ├─ RunUMAP
  └─ DimPlot
      │
      ▼
[Tool 3] SNN clustering
  ├─ FindNeighbors
  └─ FindClusters (Louvain / Leiden)
      │
      ▼
[Tool 4] Cell type annotation
  ├─ FindAllMarkers
  └─ SingleR annotation
      │
      ▼
[Tools 5-9] Visualisation (all depend on tool 4)
  ├─ DimPlot scatter
  ├─ Marker gene violin + dot plots
  ├─ Cell ratio stacked bars
  ├─ Marker gene heatmap
  └─ GO enrichment
```

- Tools 1–4 must run **in order**; each one requires the previous step to succeed.
- Tools 5–9 are independent visualisations; all depend on tool 4's output.
- Not sure where you are? Call `check_pipeline_status` first.

## Middleware

The agent ships with three middleware layers:

| Middleware | Purpose |
|---|---|
| `SummarizationMiddleware` | Summarises the message history once it exceeds the token budget, keeping the most recent N messages verbatim |
| `ToolCallLimitMiddleware` | Executes at most 2 tool calls per turn, preventing runaway loops |
| `HumanInTheLoopMiddleware` | Requires manual `y/n` confirmation of the parameters before every tool call |

## Output layout

All results are written under the `data/` directory:

```
data/
├── qc/                    # quality control
│   ├── object.json        # index file
│   ├── {project}_qc_*.pdf # QC plots
│   └── {project}_qc.rds   # Seurat object
├── pca_umap/              # dimensionality reduction
├── snn_cluster/           # clustering
├── cell_annotation/       # annotation
│   ├── seuratobject.json
│   ├── {project}_annotated.rds
│   ├── {project}_cluster_markers.csv
│   ├── {project}_cluster_markers.rds
│   └── {project}_umap_celltype.pdf
├── dimplot/               # scatter plots
├── marker_viz/            # marker gene visualisation
├── cell_ratio/            # cell ratio plots
├── heatmap/               # heatmaps
└── enrichment/            # GO enrichment
```

---

## ⚠️ Disclaimer

**This tool is for research use only and must not be used for clinical diagnosis or medical decisions.**

- All results (cell type annotation, clustering, enrichment, …) are **computational inferences**
  that have not been validated experimentally.
- Users are responsible for ensuring the **compliance and privacy** of the input data
  (informed consent, ethics approval, human genetic resource regulations, GDPR and other
  applicable laws).
- The project collects and uploads no data; all analysis runs in your own environment. The only
  external call is the LLM API (point it at your own service by switching to a local model).
- The authors accept no liability for any consequences of using this tool.

## Third-party licenses

The **core bioinformatics dependencies include GPL-3.0 components**
(SingleR, celldex, harmony, presto, GLPK, …), so this project is licensed under **GPL-3.0**
for consistency. (Seurat itself is MIT; the licence inventory lists every component.)

The full dependency licence inventory — base images, system libraries, 355 R packages and
59 Python distributions, with the copyleft ones called out — is in
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).
**If you redistribute the Docker images, comply with the third-party licences listed there.**

**What redistribution actually requires** (citation is a separate matter — see below):

- GPL-3.0 / AGPL-3.0 components (`SingleR`, `celldex`, `harmony`, `presto`, GLPK, `fst`,
  `RhpcBLASctl`) — ship their corresponding source and licence texts; the inventory lists where
  to obtain each one, and `presto`'s source already ships in this repository;
- permissive components (MIT / BSD / Apache / Artistic) — keep their copyright notices;
- running the software yourself, without redistributing it, triggers **none** of these.

## License

[GNU General Public License v3.0](LICENSE) (GPL-3.0)

## Citation

If this project helps your research, please cite it. Machine-readable citation metadata is in
[`CITATION.cff`](CITATION.cff) (GitHub shows a "Cite this repository" button), and author /
 copyright information is in [`AUTHORS`](AUTHORS).

**Please also cite the upstream tools you actually used** — for a paper based on this pipeline
that typically means the methodology behind the steps you ran. The `references:` list in
`CITATION.cff` contains ready-to-use entries for:

| Tool | Used for | Reference |
|---|---|---|
| **Seurat v5** | core single-cell analysis (tools 1–4) | Hao et al., *Nature Biotechnology* 2024 |
| **SingleR** | cell type annotation (tool 4) | Aran et al., *Nature Immunology* 2019 |
| **celldex** | reference datasets for SingleR | Bioconductor package |
| **clusterProfiler** | GO enrichment (tool 9) | Wu et al., *The Innovation* 2021 |
| **harmony** | batch correction (tool 1, step 8) | Korsunsky et al., *Nature Methods* 2019 |
| **presto** | fast Wilcoxon/AUC marker tests | Korsunsky et al., *bioRxiv* 2019 |
| **LangChain** / **LangGraph** | agent framework and HITL state machine | project repositories |

Depending on the steps you run, you may also want to cite the tools those depend on
(e.g. sctransform, UMAP/uwot, Leiden).
