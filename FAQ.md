# 常见问题（FAQ）

按「症状 → 原因 → 处置」组织。命令以 Linux / WSL 为主，Windows 对应命令见 `DEPLOY.md` §8 速查表。

---

## 启动与连接

### 1. 网页打不开 / 浏览器提示无法连接

**原因**：服务未启动，或监听地址不是你以为的那个。

**处置**：

```bash
./deploy/doctor.sh                  # 先体检：Docker 是否运行、端口是否占用、容器是否健康
./deploy/up.sh                      # 未启动就启动
```

默认只监听 `127.0.0.1`，因此**只能从本机访问**。要让别的机器访问，见第 14 条。

### 2. Docker 未运行 / `docker info` 报错

**原因**：Docker Desktop 未启动（Windows），或 Docker 服务未启动、当前用户不在 `docker` 组（Linux）。

**处置**：

```bash
# Windows：启动 Docker Desktop，等任务栏图标变为运行中
# Linux：
sudo systemctl start docker
sudo usermod -aG docker $USER && newgrp docker      # 重新登录后生效
```

### 3. 端口 8080 被占用

**处置**：改 `deploy/.env` 的 `SCAGENT_PORT`（例如 `18080`），然后 `./deploy/up.sh`。服务若已在运行，端口被占用是正常的。

### 4. 内存不足 / 容器反复重启（Exit 137）

**原因**：单个 Seurat 对象约 1.6 GB，分析峰值是它的数倍；并发数过多会 OOM。

**处置**：把 `SCAGENT_MAX_CONCURRENT_RUNS` 设为 `1`，并确保可用内存 ≥16 GB（Windows 上还要在 Docker Desktop 里给足内存）。

**提示**：不要在同一台机器上同时运行第二套实例或并发多个分析 —— 内存与 CPU 会互相争抢，整机都会明显变卡。

---

## 认证

### 5. 提示 401 / 令牌明明是对的却认证失败

**原因**：`deploy/.env` 被编辑器存成了 **CRLF**，访问令牌末尾多出一个回车符。

**处置**：确认 `.env` 为 **UTF-8 无 BOM + LF**（VS Code 右下角可切换），或直接重跑 `./deploy/configure.sh` 重新生成。

### 6. 访问令牌在哪里？忘了怎么办

```bash
cat /srv/scagent/secrets/scagent_token          # Linux 默认安装根下的密钥文件
# Windows： type D:\scagent\secrets\scagent_token
# 开发容器：cat ~/.config/scagent/scagent_token
```

丢失或想更换：删除该文件后重跑 `./deploy/configure.sh`（或 Windows 的 `deploy\scagent.cmd secrets`），随后 `./deploy/up.sh` 让容器重新读取。

### 6b. LLM API Key 存在哪里？什么时候输入？

**输入时机**：配置向导（Linux `./deploy/configure.sh` / Windows `deploy\install.cmd`）的第 3 步
"密钥与数据目录"会要求粘贴，输入不回显。非交互安装可用 `--deepseek-key`（Linux）/
`-DeepSeekKey`（Windows）传入。

**存放位置**：安装根目录下的 `secrets/deepseek_api_key`，是一个**独立文件** ——
不写进 `deploy/.env`、不进容器环境变量、不进 `docker inspect`。

| 场景 | 路径 |
|---|---|
| 生产部署（Linux） | `/srv/scagent/secrets/deepseek_api_key`（安装根可自定义） |
| 生产部署（Windows） | `<安装根>\secrets\deepseek_api_key`，安装根默认是仓库所在目录的上一级 |
| 开发容器 | `~/.config/scagent/deepseek_api_key` |

**换一个 Key**：`./deploy/configure.sh --force`（Linux）或 `deploy\scagent.cmd secrets`（Windows）；
也可以直接改上面那个文件（UTF-8、无换行、权限 600），再 `up` 一次。

> 缺这个文件时 **agent 会拒绝启动**（容器反复重启），不是"能跑但不会规划"。
> 只跑确定性流水线可以改用 `pipeline_cli.py`（见第 16 条）。

---

## 数据

### 7. agent 说"没有找到任何 10X 数据样本"，但我明明放了数据

**原因**：数据放到了**仓库目录**的 `data/` 下，而容器挂载的是**工作目录**（`SCAGENT_WORKSPACE`）下的 `data/`。

**处置**：

```bash
./deploy/doctor.sh      # 会同时打印"容器实际挂载的路径"与"你配置的路径"
```

正确位置（**生产部署**）：`<安装根>/workspace/data/rawdata/<样本名>/{barcodes,features,matrix}.tsv.gz`

```
D:\projects\workspace\data\rawdata\sample1\      ← Windows 例：安装根 = D:\projects
/srv/scagent/workspace/data/rawdata/sample1/    ← Linux 例
```

**开发容器**（VS Code Dev Container）则相反：数据放**仓库内**的 `data/rawdata/<样本名>/`。
两种用法共用同一套镜像，区别只在目录约定 —— 生产把数据放在仓库之外，
开发把整个仓库挂在 `/workspace`（见 `DEVELOPMENT.md` 的「目录约定」）。

### 8. 报告"参考集缺失"，细胞类型注释跑不了

**原因**：`celldex` 这个 R 包随镜像自动安装，但它提供的**数据集**体积大，不随软件分发，需要单独获取一次。

**处置**（一条命令，需要外网）：

```bash
./scripts/fetch_refdata.sh                    # 小鼠（默认）
./scripts/fetch_refdata.sh --species human    # 人类
```

```powershell
deploy\scagent.cmd refdata
```

它用一个临时容器联网下载，直接写入 `<SCAGENT_BIODATA>/celldex/`（小鼠 `MouseRNAseqData.rds`、人类 `HumanPrimaryCellAtlasData.rds`）；
生产容器仍然离线只读挂载。不能出网时，也可以在任何装了 R 与 `celldex` 的机器上生成后拷贝过来（见 `DEPLOY.md` §5）。

其余分析步骤不受影响。

### 9. 数据目录里出现属主是 root 的文件，容器写不进去

**原因**：早期版本以 root 运行容器；升级后容器以普通用户（uid 1000）运行，旧的 root 文件会挡住写入。

**处置**：

```bash
sudo chown -R $(id -u):$(id -g) <SCAGENT_WORKSPACE>
```

---

## 镜像与网络

### 10. 首次构建很慢，是不是卡住了？

**原因**：R 运行时层要安装上百个 R 包，首次 30–90 分钟属正常，且构建输出可能长时间无回显。

**处置**：另开一个终端看进度：

```bash
docker images        # 会逐步出现中间层，最后出现 scagent/scagent-runtime
docker system df     # 构建缓存占用应持续增长
```

中断也没关系：重新执行 `./deploy/build.sh` 会复用已完成的层，不会从头开始。

### 11. 构建报 `failed to resolve source metadata … 403` / 拉不到基础镜像

**原因**：基础镜像或 R 包的下载被网络策略拦截。

**处置**：

```bash
./scripts/setup-network.sh          # 配置镜像源（Linux/WSL）
# Windows：在 Docker Desktop → Settings → Docker Engine 里配置 registry-mirrors
```

或改用已发布镜像：把 `SCAGENT_IMAGE_SOURCE` 改成 `public`（需要该镜像已发布）。

### 11b. 构建报 `apt-get … did not complete successfully: exit code: 100` / 卡在 `Get:… InRelease`

**原因**：构建运行时层时要从 Ubuntu 官方源（`archive.ubuntu.com` / `security.ubuntu.com`）安装系统依赖，
该网络访问不稳定或被限制时会失败。

**处置**（按顺序尝试）：

1. **直接重试**（多数是瞬时波动）：`deploy\scagent.cmd build -Force`（不要加 `-NoCache`，已完成的层会被复用）；
2. **换国内 apt 源**（首次构建前设置，写进 `deploy\.env` 或临时设环境变量）：

```ini
# deploy/.env
APT_MIRROR=https://mirrors.aliyun.com/ubuntu
```

```powershell
$env:APT_MIRROR="https://mirrors.aliyun.com/ubuntu"; deploy\scagent.cmd build -Force
```

> ⚠️ apt 层改变后，**其上的所有层（含 R 包安装）都会重建**（30–90 分钟）—— 所以请在首次构建前决定，
> 别在已有镜像之后才切换；否则宁可保持默认源重试。

3. **不构建**：使用已发布/私有 registry 的现成镜像（`SCAGENT_IMAGE_SOURCE=public|private`）。

### 11c. 不想本地构建，直接用已发布镜像

**处置**：配置时直接指定前缀，然后启动（本机没有镜像时会自动拉取，**不需要 `build`**）：

```bash
# Linux / WSL：前缀二选一，然后 ./deploy/up.sh
# ① 默认：GitHub（GHCR）
./deploy/configure.sh --image-source public --image-prefix ghcr.io/17xxxx/scagent

# ② 中国大陆网络更快：阿里云 ACR
./deploy/configure.sh --image-source public \
  --image-prefix crpi-4le1vixwpzhdr5y0.cn-beijing.personal.cr.aliyuncs.com/sqxopen
./deploy/up.sh
```

```powershell
# Windows（前缀二选一，同上）
deploy\install.cmd -ImageSource public -ImagePrefix ghcr.io/17xxxx/scagent
```

已经装好、只想换镜像源的，改 `deploy/.env` 的 `SCAGENT_IMAGE_PREFIX` 这两行再 `up` 也可以。

两个源都是公开仓库、**不需要 `docker login`**，镜像由不同环境构建、功能一致（见 `DEPLOY.md` §0）。
首次拉取按压缩层计约 **3.1 GB（GHCR）/ 2.4 GB（阿里云）**，之后启动只需几秒。
注意前缀里**不要**再拼 `scagent-` —— 镜像名由程序拼成 `<前缀>/scagent-<服务>:<版本>`。

### 12. 服务拉不到镜像 / 提示认证失败（私有 registry）

**处置**：

```bash
docker login <你的 registry>
```

并确认 `deploy/.env` 的 `SCAGENT_IMAGE_PREFIX` 与实际推送路径一致（构建推送脚本 `scripts/push_registry.sh` 会提示应填的值）。

---

## 运维

### 13. 备份包含什么？能不能连密钥一起备份？

- 包含：`deploy/.env`（**密钥值已清空**）、`workspace/state/`、`workspace/data/`（默认**不含**体积大的 `.rds`）；
- 不含：密钥目录（默认排除；`--include-secrets` 可包含，但请自行确保备份介质加密）；
- 需要中间产物（`.rds`）时加 `--with-rds`；
- 打包后会**回验**：一旦包内出现活密钥，归档会被自动删除并报错。

### 14. 局域网里其他机器访问不到

**处置**：

1. `deploy/.env` 里 `SCAGENT_BIND_ADDR=0.0.0.0`，然后 `./deploy/up.sh`；
2. 放行防火墙（Windows 首次启动会弹出 Docker Desktop 的入站提示，选择允许）；
3. 其他机器访问 `http://<主机IP>:8080`，仍需输入访问令牌。

注意：`0.0.0.0` 意味着同网段的人都能访问，请务必保管好令牌；公网暴露还需另行配置 TLS。

### 15. 如何回滚到上一个版本？

```bash
./deploy/rollback.sh --list     # 先看本地有哪些镜像版本
./deploy/rollback.sh            # 把 :prev 重新指向并重启
```

`up` 每次都会把当前版本额外打上 `:prev` 标签；若该标签已丢失，回滚脚本会明确提示，可以重新拉取目标版本后手工 `docker tag`。

### 16. 想只跑确定性流水线（不调用 LLM）

**先说清一个边界**：网页界面（agent 服务）**必须有可用的 LLM** —— 启动时会校验
`SCAGENT_LLM_PROVIDER` 与密钥，不通过就直接退出、容器反复重启。所以"不调用 LLM"指的是
**绕开网页界面**，直接用容器内的确定性 CLI（它不走 LLM）：

```bash
docker compose -f deploy/docker-compose.yml exec agent python /workspace/agent_core/pipeline_cli.py status
```

想保留网页界面但不想用云端 API，可以把 `SCAGENT_LLM_PROVIDER` 设为 `ollama` 指向本地模型服务
（这条路不需要密钥文件）。

---

## 其他

### 17. 为什么不能下载 ZIP 安装？

ZIP 不携带 git 的行尾与可执行位设置：脚本可能带上 CRLF（导致令牌认证失败）或丢失可执行权限。请用 `git clone`。

### 18. Windows 上必须装 WSL 吗？

不需要。Docker Desktop 自带 Linux 引擎，直接用 PowerShell 入口（`deploy\install.cmd`、`deploy\scagent.cmd …`）即可。
Git Bash 也能运行 bash 脚本，但不在官方验证范围内（路径转换等细节需自行注意）。

### 19. 如何彻底删除本项目的数据？

```bash
./deploy/… down            # 或 Windows： deploy\scagent.cmd down
rm -rf <SCAGENT_WORKSPACE> <SCAGENT_BIODATA> <SCAGENT_SECRETS_DIR>
docker rmi $(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^scagent/scagent-')
```

### 20. Apple Silicon（M 系列 Mac）能用吗？

**现状**：镜像与部署流程只在 **x86_64** 上验证过；**arm64 尚未验证**，因此不在支持范围内。

**处置**：以模拟方式运行 x86_64 镜像（在 Docker Desktop → Settings → General 里勾选
"Use Rosetta for x86_64/amd64 emulation" 可显著提速）：

```bash
export DOCKER_DEFAULT_PLATFORM=linux/amd64      # Linux / macOS
./deploy/up.sh
```

```powershell
$env:DOCKER_DEFAULT_PLATFORM="linux/amd64"
deploy\scagent.cmd up
```

两点提醒：

1. **不要在本机构建**（`SCAGENT_IMAGE_SOURCE=local`）：模拟环境下安装上百个 R 包会慢到难以接受。请改用已发布镜像（`public`）或私有 registry 里的 `amd64` 镜像；
2. 模拟运行有明确的性能损失（分析耗时可能翻倍）。长期使用建议部署在 x86_64 机器上。

### 21. 还有别的问题？

先跑 `./deploy/doctor.sh`（Windows：`deploy\scagent.cmd doctor`）—— 它会按「环境 / 配置 / 镜像 / 密钥 / 数据 / 服务 / 网络」逐项给出结论与修复建议，多数问题能直接定位。
