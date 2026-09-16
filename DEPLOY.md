# 部署指南

面向**部署者**的生产部署说明。支持两种单机部署方式：

| 平台 | 运行方式 | 入口 |
|---|---|---|
| Linux（x86_64） | Docker Engine + Compose v2 | `deploy/*.sh` |
| Windows（x86_64） | Docker Desktop（Linux 容器） | `deploy\*.cmd` / `deploy\scagent.ps1` |

> **架构范围**：以上两行的架构都是 **x86_64**。**arm64（Apple Silicon / ARM 服务器）尚未验证**，不在支持范围内；
> 在 M 系列 Mac 上可以用模拟方式运行（功能可用、明显较慢），见 `FAQ.md`「Apple Silicon」一条。

部署完成后，**使用者不需要安装任何软件**：打开浏览器访问 `http://<主机>:8080`，输入一次访问令牌即可使用。

> 开发环境（VS Code Dev Container）的说明在 `README.md` 的「快速开始」一节。

---

## 0. 先选镜像来源

| 路径 | 适用场景 | 首次耗时 |
|---|---|---|
| **A. 本机构建**（默认） | 内网 / 离线环境，没有私有 registry | 30–90 分钟（多数时间在安装 R 包） |
| **B. 使用已发布镜像** | 已有公开仓库（如 GHCR）或私有 registry | 几分钟（拉取） |

由 `deploy/.env` 的 `SCAGENT_IMAGE_SOURCE` 决定：`local`（本机构建）/ `public`（公开发布）/ `private`（自有 registry）。
三者只是**镜像地址不同**，运行时行为完全一致。

---

## 1. 前置条件

| 项 | 要求 |
|---|---|
| Docker | Linux：Docker Engine + Compose v2；Windows：Docker Desktop（Linux 容器模式） |
| 架构 | **x86_64**（`linux/amd64`）。arm64 尚未验证，见 `FAQ.md`「Apple Silicon」一条 |
| 内存 | ≥ 16 GB（推荐 32 GB；单个 Seurat 对象约 1.6 GB，分析峰值数倍） |
| CPU | ≥ 8 核（分析速度线性相关） |
| 磁盘 | ≥ 50 GB（镜像约 10 GB + 分析产物） |
| 网络 | 需能访问你的 LLM 端点（默认 `https://api.deepseek.com`）；本机构建还需能拉基础镜像与 R 包 |
| 端口 | 默认 `8080` 空闲 |

Windows 上**不需要**安装 WSL 发行版 —— Docker Desktop 自带 Linux 引擎。

### 受限网络（可选设置）

| 目标 | 环境变量（写进 `deploy/.env`） | 说明 |
|---|---|---|
| apt 系统依赖 | `APT_MIRROR=https://mirrors.aliyun.com/ubuntu` | 构建报 `apt-get … exit code: 100` 时使用；**只能在首次构建前设置**（apt 层一变，其上所有层会重建） |
| R 包源 | `PPM_CRAN` / `CRAN_FALLBACK` / `BIOC_ROOT` | 默认值已是可用的国内镜像，一般无需改 |
| R 源码包（可选，仅构建者） | 无需配置 | 网络不稳定时，可把已下载的源码包放进 `.local-r-repo/`（构建时只读挂载、优先使用，**不进镜像、不入库**）。见该目录的 README |
| Python 包源 | `PIP_INDEX_URL`（构建参数） | 仅自建 wheelhouse 时需要 |
| 镜像仓库 | Docker Desktop → Settings → Docker Engine → `registry-mirrors` | 拉基础镜像失败（403/超时）时使用 |

> 这些都是**可选**的；默认配置在无障碍网络下不需要任何设置。

---

## 2. 获取项目

```bash
git clone <本仓库地址> scagent
cd scagent
```

> 请使用 `git clone`，**不要下载 ZIP**：ZIP 会丢失 git 的行尾与可执行位设置，脚本可能无法直接运行（详见 `FAQ.md`）。

---

## 3. 配置

### Linux / WSL

```bash
./deploy/configure.sh          # 交互式：只问 3 项（数据根目录 / 镜像来源 / LLM API Key）
```

它会自动推导 `workspace` / `biodata` / `secrets` 三个目录、生成访问令牌，并写出 `deploy/.env` 与两份密钥文件。

### Windows

```powershell
deploy\install.cmd             # 双击也可以
```

逐步完成：环境体检 → 生成配置与密钥 → 准备镜像（构建或拉取）→ 启动 → 等待健康检查 → 打开浏览器。

### 也可以手写 `deploy/.env`

```ini
SCAGENT_IMAGE_SOURCE=local
SCAGENT_IMAGE_PREFIX=scagent
SCAGENT_VERSION=1.0.0
SCAGENT_PULL_POLICY=never

SCAGENT_WORKSPACE=/srv/scagent/workspace
SCAGENT_BIODATA=/srv/scagent/biodata
SCAGENT_SECRETS_DIR=/srv/scagent/secrets

SCAGENT_BIND_ADDR=127.0.0.1
SCAGENT_PORT=8080
```

| 键 | 含义 | 说明 |
|---|---|---|
| `SCAGENT_IMAGE_SOURCE` | 镜像来源 | `local` / `public` / `private` |
| `SCAGENT_IMAGE_PREFIX` | 镜像前缀 | 镜像名 = `<前缀>/scagent-<seurat\|agent>:<版本>`；`local` 用 `scagent`，`public` 形如 `ghcr.io/<组织>/scagent`，`private` 形如 `harbor.corp.local/scagent` |
| `SCAGENT_VERSION` | 镜像标签 | 升级时改这里 |
| `SCAGENT_PULL_POLICY` | 拉取策略 | `local` 固定 `never`；`public`/`private` 用 `missing` |
| `SCAGENT_WORKSPACE` | 数据根目录 | 其下 `data/` 与 `state/` 会挂进容器 |
| `SCAGENT_BIODATA` | 参考数据目录 | 只读挂载到容器 `/ref` |
| `SCAGENT_SECRETS_DIR` | 密钥目录 | 内含 `deepseek_api_key` 与 `scagent_token` |
| `SCAGENT_BIND_ADDR` | 监听地址 | `127.0.0.1` 仅本机；`0.0.0.0` 允许局域网（需放行防火墙） |
| `SCAGENT_PORT` | 服务端口 | 默认 8080 |

**两条硬性要求**

1. `.env` 必须是 **UTF-8 无 BOM、换行 LF**（用编辑器另存成 CRLF 会让令牌多一个回车符，表现为"令牌对却一直 401"）；
2. 路径写**绝对路径**、用**正斜杠**（如 `D:/scagent/workspace`），结尾不要带斜杠。

可选参数（写在 `.env` 里）：`SCAGENT_HITL`（`interactive` 默认 / `auto_approve` / `deny_all`）、
`SCAGENT_MAX_CONCURRENT_RUNS`、`SCAGENT_TOOL_RUN_LIMIT`、`SCAGENT_LLM_MODEL`、`SCAGENT_LLM_PROVIDER`（`deepseek` / `ollama` / `none`）。

---

## 4. 启动与验证

```bash
# Linux / WSL
./deploy/build.sh        # 仅 local 模式：先构建镜像（可重复执行，已存在会跳过）
./deploy/up.sh           # 启动 / 更新
./deploy/verify.sh       # 服务可用性自检
./deploy/doctor.sh       # 环境与配置体检（起不来时先跑它）
```

```powershell
# Windows
deploy\scagent.cmd build       # 仅 local 模式
deploy\scagent.cmd up
deploy\scagent.cmd verify
deploy\scagent.cmd doctor
```

启动后打开 **http://127.0.0.1:8080**，首次会要求输入访问令牌 —— 它在密钥目录的 `scagent_token` 文件里。

**`doctor` 与 `verify` 的分工**

- `doctor`：环境与配置**能不能跑起来**（Docker、资源、端口、镜像、密钥、数据、网络）；
- `verify`：服务**本身是否可用**（容器健康、端点、令牌、数据目录）。

---

## 5. 数据与参考数据集

### 10X 原始数据

```
<SCAGENT_WORKSPACE>/data/rawdata/
├── sample1/
│   ├── barcodes.tsv.gz
│   ├── features.tsv.gz
│   └── matrix.mtx.gz
└── sample2/…
```

每个样本一个子目录，三个文件直接放在该目录下（文件名不要带样本名前缀）。
⚠️ 是**工作目录**（`SCAGENT_WORKSPACE`）下的 `data/rawdata/`，**不是仓库目录里的 `data/`**。

### 参考数据集（细胞类型注释需要）

`celldex` 这个 **R 包随镜像自动安装**；它提供的**数据集**体积大（小鼠参考集约 17 MB，人类更大），
**不随软件分发**，需要单独获取一次。容器以只读方式挂载 `<SCAGENT_BIODATA>` 到 `/ref`，
程序从 `<SCAGENT_BIODATA>/celldex/` 读取：

| 物种 | 需要的文件 |
|---|---|
| 小鼠（默认） | `MouseRNAseqData.rds` |
| 人类 | `HumanPrimaryCellAtlasData.rds` |

**一条命令获取**（用临时容器联网下载并直接写入该目录，需要外网）：

```bash
./scripts/fetch_refdata.sh                    # 小鼠；人类： --species human
```

```powershell
deploy\scagent.cmd refdata                    # 小鼠；人类： deploy\scagent.cmd refdata -Species human
```

获取完成后，生产容器仍然**离线运行、只读挂载**，运行期不会联网下载任何数据。
若你的环境不能出网，也可以在任何装了 R 与 `celldex` 的机器上生成后拷贝过来：

```r
Rscript -e 'library(celldex); saveRDS(MouseRNAseqData(), "MouseRNAseqData.rds")'
```

（有自建对象存储时，也可用 `scripts/download_data.sh` + `deploy/data.manifest` 做带 sha256 校验的下载。）

---

## 6. 日常运维

| 操作 | Linux / WSL | Windows |
|---|---|---|
| 查看状态 | `./deploy/up.sh` 后看输出 / `docker compose -f deploy/docker-compose.yml ps` | `deploy\scagent.cmd status` |
| 看日志 | `docker compose -f deploy/docker-compose.yml logs --tail 100 seurat` | `deploy\scagent.cmd logs seurat` |
| 体检 | `./deploy/doctor.sh` | `deploy\scagent.cmd doctor` |
| 备份 | `./deploy/backup.sh --out /backup` | `deploy\scagent.cmd backup -Out D:\backups` |
| 回滚 | `./deploy/rollback.sh` | `deploy\scagent.cmd rollback` |
| 停止 | `docker compose -f deploy/docker-compose.yml down` | `deploy\scagent.cmd down` |

**升级**：改 `deploy/.env` 的 `SCAGENT_VERSION` → `build.sh` / `scagent.cmd build`（local）或直接 `up`（public/private）。
每次 `up` 之前会把当前镜像额外打上 `:prev` 标签，回滚就是把它指回去并重启。

**备份包含什么**：`deploy/.env`（**密钥值已清空**）、`workspace/state/`（会话检查点）、`workspace/data/`（默认不含体积大的 `.rds`，需要时加 `--with-rds`）。
密钥目录默认**不**入备份（需要时显式 `--include-secrets`，请自行确保备份介质加密）。

**彻底清理**：`down` 停止服务后，删除 `SCAGENT_WORKSPACE`、`SCAGENT_BIODATA`、`SCAGENT_SECRETS_DIR` 三个目录；若要连镜像一起删除：
`docker rmi $(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^scagent/scagent-')`。

---

## 7. 已知限制

- **细胞类型注释需要自备参考数据集**（见 §5）；未提供时该步骤会明确报错并跳过。
- **仅 x86_64 架构经过验证**；arm64（Apple Silicon / ARM 服务器）尚未验证，见 `FAQ.md`「Apple Silicon」一条。
- Windows 推荐使用 PowerShell 入口（`deploy\*.cmd`）。Git Bash 也能运行 bash 脚本，但不在官方验证范围内。
- Windows 上 `state/`（会话检查点，SQLite）位于绑定挂载目录中，**可直接查看与单独备份**；其体积很小（约 1 MB），跨文件系统的开销可以忽略。
- 默认仅监听 `127.0.0.1`。若要让局域网其他机器访问，见 `FAQ.md`「局域网访问」一条。**公网暴露不在支持范围内**：需要在局域网访问之上再加 TLS、访问控制与多租户隔离，目前未提供也未验证。

---

## 8. 命令速查

| 动词 | Linux / WSL | Windows |
|---|---|---|
| 配置 | `./deploy/configure.sh` | `deploy\install.cmd` |
| 构建镜像 | `./deploy/build.sh` | `deploy\scagent.cmd build` |
| 启动 / 更新 | `./deploy/up.sh` | `deploy\scagent.cmd up` |
| 停止 | — | `deploy\scagent.cmd down` |
| 重启 | — | `deploy\scagent.cmd restart` |
| 状态 | `docker compose -f deploy/docker-compose.yml ps` | `deploy\scagent.cmd status` |
| 日志 | `docker compose … logs` | `deploy\scagent.cmd logs [seurat\|agent]` |
| 自检（服务） | `./deploy/verify.sh` | `deploy\scagent.cmd verify` |
| 体检（环境） | `./deploy/doctor.sh` | `deploy\scagent.cmd doctor` |
| 密钥 | `./scripts/setup_secrets.sh` | `deploy\scagent.cmd secrets` |
| 备份 / 回滚 | `./deploy/backup.sh` / `./deploy/rollback.sh` | `deploy\scagent.cmd backup` / `rollback` |
