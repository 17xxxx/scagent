# .local-r-repo —— 本机临时的"R 源码包本地优先源"（不入库、不进镜像）

## 它解决什么问题

构建 R 运行时镜像时要安装约 110 个 R 包。网络不稳定时（例如国内访问 CRAN/Bioconductor 抖动），
可以把**你已经下载好的源码包**放进这个目录，构建时会**优先用本地的**，本地没有的才联网。

这不是项目的一部分：

- 它**不进 git**（`.gitignore` 已忽略本目录下除本说明与 `.gitkeep` 之外的所有内容）；
- 它**不进镜像**（Dockerfile 用 `--mount=type=bind,ro` 只读挂载，用完即弃）；
- 别人从零构建没有这个目录/内容，也完全不影响 —— 他们会正常走远端镜像。

## 用法

```bash
# 把 shared_data/ 里已有的源码包"硬链接"进来（同盘瞬间完成、不占额外空间）
./scripts/local_r_repo.sh link

# 看看现在本机有哪些包会被优先使用
./scripts/local_r_repo.sh status

# 镜像已构建完成、流程跑通后，清掉（项目里不留）
./scripts/local_r_repo.sh clean
```

## 为什么分两个目录

| 目录 | 属于项目？ | 进构建上下文？ | 用途 |
|---|---|---|---|
| `shared_data/` | 是（`presto-master.zip` 入库） | 是（`*.tar.gz` 被 `.dockerignore` 排除） | 项目自带的构建输入 |
| `.local-r-repo/` | **否**（纯本机） | 是（但只读挂载，不进镜像） | **你的**网络缓解手段 |
