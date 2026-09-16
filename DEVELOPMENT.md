# 开发环境

面向**在本地修改 / 调试 scAgent 代码**的开发者。只想把 scAgent 用起来，
请走 **[DEPLOY.md](DEPLOY.md)**（部署速览 → 配置 → 启动 → 放数据）。

---

## 前置条件

- Docker + Docker Compose
- VS Code + Dev Containers 扩展（推荐）

## 目录约定

开发容器把**整个仓库**挂到 `/workspace`，因此数据与参考数据都在仓库内 ——
这与生产部署（数据与密钥放在仓库之外）不同：

| 位置 | 在哪儿 | 放什么 |
|---|---|---|
| `data/rawdata/<样本名>/` | 仓库内 | 10X 原始数据（每个样本一个子目录，三个文件直接放里面） |
| `.biodata/` | 仓库内（已 gitignore） | 参考数据集，运行时只读挂载为 `/ref` |
| `~/.config/scagent/` | 用户主目录 | `deepseek_api_key` 与 `scagent_token` 两个密钥文件 |

与生产部署的对照：

| 生产部署 | 开发容器 |
|---|---|
| 数据在 `<安装根>/workspace/data/` | 数据在仓库内 `data/` |
| 密钥在 `<安装根>/secrets/` | 密钥在 `~/.config/scagent/` |

> 两种用法共用同一套镜像，区别只在目录约定。生产侧说明见 `DEPLOY.md` 的「部署速览」。

---

## 1. 准备数据

将 10X 格式的原始数据放入 `data/rawdata/`，每个样本一个子文件夹，文件夹内直接存放三个文件：

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

## 2. 准备密钥

密钥**不通过 `.env` 注入容器**，而是以 Docker secrets 文件形式挂载 ——
这样密钥不会出现在 `docker inspect`、镜像层或环境变量中。

```bash
./scripts/setup_secrets.sh --target ~/.config/scagent    # 与开发容器的挂载点一致
```

产出（权限 600 的文件）：

| 文件 | 内容 |
|---|---|
| `deepseek_api_key` | LLM API Key（形如 `sk-...`） |
| `scagent_token` | 客户端访问令牌，**必填** —— 缺失时 `server.py` 拒绝启动 |

> **必须放在 `~/.config/scagent/`**：开发编排（`.devcontainer/docker-compose.yml`）
> 就是从那里读取这两个文件。脚本不加 `--target` 时的默认落点是「`deploy/.env` 里的
> `SCAGENT_SECRETS_DIR`，否则是仓库的兄弟目录」，与开发容器不一致，所以这里显式指定。
>
> 密钥也不宜放在仓库内：开发编排挂载了整个仓库（`..:/workspace`），
> 项目内的密钥文件会随挂载进入容器，secrets 就失去意义。
>
> 已有 `.env` 时脚本会自动从中读取；`--check` 只检查现状不写文件。
> 容器内实际读取的是 `SCAGENT_LLM_API_KEY_FILE` / `SCAGENT_TOKEN_FILE`
> 指向的这两个文件（见 `.devcontainer/docker-compose.yml`）。

## 3. 构建镜像（首次约 30–90 分钟）

镜像分两层，`seurat_backend/Dockerfile` 的 `FROM` 指向 runtime 镜像，
**必须先构建 runtime 层** —— 直接 `docker compose build` 会因基础镜像不存在而失败：

```bash
./scripts/dev_build.sh              # 首次：runtime + 应用层
./scripts/dev_build.sh --app-only   # 之后只改了 R/Python 代码：数秒完成
```

## 4. 启动容器

在 VS Code 中打开项目，点击左下角绿色按钮选择 "Reopen in Container"，或手动启动：

```bash
docker compose -f .devcontainer/docker-compose.yml up -d
```

## 5. 运行

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

### 关于 `.env`

只有 `agent_main.py` 会通过 `load_dotenv()` 读取项目根的 `.env`；
`server.py`、`pipeline_cli.py` 和 `docker compose` 都**不读取** `.env`。
因此 `.env` 仅适合本地调试，正式配置请一律走第 2 步的 secrets。

## 自检脚本

| 脚本 | 作用 |
|---|---|
| `bash scripts/check_all.sh` | 一键静态自检：Python/Shell 语法、工具参数契约、硬编码路径、密钥泄漏等 |
| `bash scripts/check_ps_syntax.sh` | PowerShell 脚本的静态体检（Linux/WSL 上即可运行） |
| `bash scripts/check_secrets.sh --prod` | 密钥文件的可读性预检（属主 / 权限 / SELinux 标签） |

> `check_ps_syntax.sh` 只是静态检查，PowerShell 脚本的最终验证需在 Windows 上执行一次。

---

## 维护者：发布镜像

`.github/workflows/publish-images.yml` 负责构建并推送镜像到 GHCR：

- **触发**：Actions 页面手动运行 `publish-images`（填版本号），或 `git tag v1.0.0 && git push origin v1.0.0`；
- **产物**：`ghcr.io/<owner>/scagent/scagent-{runtime,seurat,agent}:<版本>`，
  部署方把 `SCAGENT_IMAGE_PREFIX` 指到 `ghcr.io/<owner>/scagent` 即可拉取；
- **发布后**：在该仓库的 Packages 页面把三个包设为 Public，匿名用户才能直接 `docker pull`。

发布到其他 registry（如私有 Harbor、国内镜像源）见 `scripts/push_registry.sh` 与
`deploy/images.lock` 的说明。
