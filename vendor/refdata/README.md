# 参考数据不在这里

基因/参考数据属于「数据」而非「软件」，**不进仓库、不进镜像、不进 registry**。

- 存放：对象存储（OSS / S3 / MinIO）
- 分发：`scripts/download_data.sh`（断点续传 + sha256 校验）
- 落盘：独立物理盘，如 `/data/biodata`
- 挂载：compose `-v /data/biodata:/ref:ro`（只读）

分发与挂载的完整约定见 `scripts/download_data.sh` 与 `deploy/docker-compose.yml`。

本目录仅作为占位，说明 refdata 的正确去向；请勿在此放置数据文件。
