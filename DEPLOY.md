# 部署指南

面向**部署者**的生产部署说明。支持两种单机部署方式：

| 平台 | 运行方式 | 入口 |
|---|---|---|
| Linux（x86_64） | Docker Engine + Compose v2 | `deploy/*.sh` |
| Windows（x86_64） | Docker Desktop（Linux 容器） | `deploy\*.cmd` / `deploy\scagent.ps1` |

> **架构范围**：以上两行的架构都是 **x86_64**。**arm64（Apple Silicon / ARM 服务器）尚未验证**，不在支持范围内；
> 在 M 系列 Mac 上可以用模拟方式运行（功能可用、明显较慢），见 `FAQ.md`「Apple Silicon」一条。

部署完成后，**使用者不需要安装任何软件**：打开浏览器访问 `http://<主机>:8080`，输入一次访问令牌即可使用。

> 开发环境（VS Code Dev Container）的说明在 **[DEVELOPMENT.md](DEVELOPMENT.md)**。

---

## 部署速览（先读这一节）

### 1. 部署会建立哪三个目录

配置向导（Linux 的 `configure.sh` / Windows 的 `install.cmd`）会先问一个**安装根目录**，
然后在其下自动建立三个目录：

| 目录 | 内容 | 你要做什么 |
|---|---|---|
| `<安装根>/secrets/` | `deepseek_api_key`（LLM 密钥）、`scagent_token`（访问令牌） | 安装时按提示输入，或事后补；**不要**放进仓库、不要提交 |
| `<安装根>/workspace/` | `data/`（你的原始数据 + 全部分析产物）、`state/`（会话与审批记录） | **10X 数据放这里**（见第 3 点） |
| `<安装根>/biodata/` | 参考数据集（细胞类型注释用） | 用一条命令获取一次（见 §5） |

**安装根目录的默认值**

| 平台 | 默认 | 说明 |
|---|---|---|
| Windows | 仓库所在目录的**上一级**（若仓库目录名不是 `scagent`，则为 `<系统盘>:\scagent`） | 例：仓库在 `D:\projects\scagent`，则安装根是 `D:\projects`，工作目录是 `D:\projects\workspace` |
| Linux / WSL | `/srv/scagent`（向导会问，可直接改） | 建议放在仓库之外 |

> 放在**仓库之外**的目的：重新 `git clone` 或删除仓库都不会碰到你的数据与密钥，
> 也不会被误打包、误提交。

### 2. 四步走

| 步骤 | Linux / WSL | Windows |
|---|---|---|
| ① 配置（**在这一步输入 LLM API Key**） | `./deploy/configure.sh` | `deploy\install.cmd` |
| ② 启动 | `./deploy/up.sh` | `deploy\scagent.cmd up` |
| ③ 放数据 | 见第 3 点 | 见第 3 点 |
| ④ 使用 | 浏览器打开 `http://<主机>:8080`，粘贴 `scagent_token` 的内容 | 同 |

Windows 的 `install.cmd` 会一路做到启动（等价于 ①+②）。

### 3. 我的数据应该放在哪个文件夹？

```
<安装根>/workspace/data/rawdata/<样本名>/
├── barcodes.tsv.gz
├── features.tsv.gz
└── matrix.mtx.gz
```

- 每个样本一个子目录，三个文件**直接放在该子目录下**，文件名不要带样本名前缀；
  `.gz` 或未压缩均可；
- Windows 例：`D:\projects\workspace\data\rawdata\sample1\`；
- ⚠️ 是**工作目录**下的 `data/rawdata/`，**不是**仓库目录里的 `data/` —— 这是最常见的放错位置；
- 不确定时执行 `./deploy/doctor.sh`（Windows：`deploy\scagent.cmd doctor`），
  它会打印**容器实际挂载的路径**与**你配置的路径**，两者一致才算放对。

### 4. LLM API Key 在哪里输入、存到了哪里？

| 问题 | 答案 |
|---|---|
| 哪一步输入 | 配置向导的第 3 步（"密钥与数据目录"）。它会提示粘贴，输入不回显；非交互安装可用 `--deepseek-key`（Linux）/ `-DeepSeekKey`（Windows）传入 |
| 存到哪 | **`<安装根>/secrets/deepseek_api_key`** —— 一个独立文件，不写进 `deploy/.env`、不进容器环境变量、不进 `docker inspect` |
| 事后补/改 | `./deploy/configure.sh --force`（Linux）或 `deploy\scagent.cmd secrets`（Windows）；也可直接把新 Key 写进上面那个文件（UTF-8、无换行、权限 600）后 `up` 一次 |
| 访问令牌 | 同目录的 `scagent_token`，浏览器首次访问时粘贴它的内容；忘了就 `cat <安装根>/secrets/scagent_token` |

> **没有密钥服务无法启动**：agent 启动时会校验 LLM 配置，缺密钥会直接退出、容器反复重启
> （只跑确定性流水线时改用 `pipeline_cli.py`，见 `FAQ.md`）。

---

## 0. 先选镜像来源

> **默认是「本机构建」**（`SCAGENT_IMAGE_SOURCE=local`），首次约 **30–90 分钟**（大部分时间在装 R 包）。
> 想跳过它，配置时显式指定已发布镜像即可（见本节末「已发布的镜像」）。
> 注意 Windows 的 `install.cmd` **不会询问**镜像来源，默认同样是本机构建 ——
> 要改用已发布镜像必须显式加 `-ImageSource public -ImagePrefix <前缀>`。

| 路径 | 适用场景 | 首次耗时 |
|---|---|---|
| **A. 本机构建**（默认） | 内网 / 离线环境，拉不到任何镜像仓库 | 30–90 分钟（多数时间在安装 R 包） |
| **B. 使用已发布镜像**（推荐） | 能访问公网镜像仓库 | 几分钟（只拉取） |

由 `deploy/.env` 的 `SCAGENT_IMAGE_SOURCE` 决定：`local`（本机构建）/ `public`（公开发布）/ `private`（自有 registry）。
三者只是**镜像地址不同**，运行时行为完全一致。

### 已发布的镜像

| 镜像源 | `SCAGENT_IMAGE_PREFIX` 填什么 | 说明 |
|---|---|---|
| **GitHub 容器仓库（GHCR）** —— 默认 | `ghcr.io/17xxxx/scagent` | 公开仓库，**无需登录**；由 GitHub Actions 从源码构建；首次拉取约 3.1 GB |
| 阿里云 ACR（中国大陆网络更快） | `crpi-4le1vixwpzhdr5y0.cn-beijing.personal.cr.aliyuncs.com/sqxopen` | 公开仓库，**无需登录**；首次拉取约 2.4 GB |

两个源的镜像在不同环境构建（GitHub Actions / 本地构建），层摘要与体积略有差异，功能一致；
选一个即可，也可以混用（改前缀 + `up` 一次）。中国大陆直连 ghcr.io 通常明显慢于国内镜像源，
网络受限时可直接用阿里云 ACR。

**用法（一条命令）** —— 生成配置时直接指定前缀，然后启动即可，**不需要 `build`**。
以下示例用默认的 GHCR；用阿里云把 `--image-prefix` 换成上面表格里那一行即可。

```bash
# Linux / WSL
./deploy/configure.sh --image-source public \
  --image-prefix ghcr.io/17xxxx/scagent
./deploy/up.sh            # 本机没有镜像时会自动拉取
./deploy/verify.sh
```

```powershell
# Windows（install 会一路装到启动）
deploy\install.cmd -ImageSource public -ImagePrefix ghcr.io/17xxxx/scagent
```

**已经装好、只想换成已发布镜像**：改 `deploy/.env` 里这两行，再 `up` 一次即可：

```ini
SCAGENT_IMAGE_SOURCE=public
SCAGENT_IMAGE_PREFIX=ghcr.io/17xxxx/scagent
SCAGENT_VERSION=1.0.0
```

```bash
# 改完之后
./deploy/up.sh            # Windows： deploy\scagent.cmd up
```

```powershell
deploy\scagent.cmd up
deploy\scagent.cmd verify
```

只想先把镜像拉下来看看（不启动服务）：

```bash
docker pull ghcr.io/17xxxx/scagent/scagent-seurat:1.0.0
docker pull ghcr.io/17xxxx/scagent/scagent-agent:1.0.0

# 阿里云 ACR（把前缀整体替换即可）
docker pull crpi-4le1vixwpzhdr5y0.cn-beijing.personal.cr.aliyuncs.com/sqxopen/scagent-seurat:1.0.0
```

> **前缀里不要自己再拼 `scagent-`** —— 程序会补上：镜像名 = `<前缀>/scagent-<服务>:<版本>`。
> 例如前缀 `ghcr.io/17xxxx/scagent` 对应镜像 `ghcr.io/17xxxx/scagent/scagent-seurat:1.0.0`。
>
> 首次拉取按压缩层计约 3.1 GB（GHCR）/ 2.4 GB（阿里云），之后启动只需几秒。
> `docker images` 里显示的体积是**解压口径**，比下载量大得多，不是下载量。
> `scagent-runtime` 只有需要自己重建 `seurat` 层的人才要拉，普通部署用不到。

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

> **LLM API Key 不能缺**：agent 启动时会先校验 LLM 配置，缺密钥会直接退出、容器反复重启。
> 想先跑起来再补密钥也可以，但补上之前服务不可用；只想跑确定性流水线（不经过网页界面）请用
> `pipeline_cli.py`（见 `FAQ.md`）。用本地模型（`SCAGENT_LLM_PROVIDER=ollama`）则不需要密钥文件。

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
`SCAGENT_MAX_CONCURRENT_RUNS`、`SCAGENT_TOOL_RUN_LIMIT`、`SCAGENT_LLM_MODEL`、`SCAGENT_LLM_PROVIDER`（`deepseek` 默认 / `ollama` 本地模型）。

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
