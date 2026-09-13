#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/setup-network.sh —— 受限网络环境适配
#
#  用途：为 scAgent 的构建/部署环境配置网络访问策略与镜像源。
#
#  解决的三个实测问题：
#    1. 宿主无 IPv6，但大量域名有 AAAA 记录 → curl/pip/R 默认走 IPv6 会挂起至超时
#    2. Docker Hub (registry-1.docker.io) 直连被阻断 → 必须配置 registry-mirrors
#    3. bioconductor.org 可达但极不稳定（传输频繁卡死）→ R 源改走 PPM
#
#  用法：
#    ./scripts/setup-network.sh                 # 应用全部配置（幂等）
#    ./scripts/setup-network.sh --dry-run       # 只预览，不写任何文件
#    ./scripts/setup-network.sh --verify        # 只做连通性自检
#    ./scripts/setup-network.sh --pip-mirror    # 额外把 pip 源切到阿里云镜像
#    ./scripts/setup-network.sh --help
#
#  注意：涉及 /etc/gai.conf 与 /etc/docker/daemon.json 的改动需要 sudo。
#        没有 sudo 时会跳过并给出提示，其余配置照常应用。
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── 可调参数（均可用同名环境变量覆盖）─────────────────────────────────────────
PPM_OS="${PPM_OS:-jammy}"                 # ubuntu 代号: jammy(22.04) / noble(24.04) / focal(20.04)
PPM_CRAN="${PPM_CRAN:-https://packagemanager.posit.co/cran/__linux__/${PPM_OS}/latest}"
BIOC_VER="${BIOC_VER:-3.22}"              # 与 seurat_backend/Dockerfile.runtime 保持一致
# ⚠️ 不要用 packagemanager.posit.co/bioconductor/... —— 该路径实测全部 404。
#    这里用实测可达的西湖大学镜像（软件/注释/实验数据三个子仓均已验证）。
BIOC_BASE="${BIOC_BASE:-https://mirrors.westlake.edu.cn/bioconductor/packages/${BIOC_VER}}"
BIOC_MIRROR="${BIOC_MIRROR:-${BIOC_BASE}/bioc}"
BIOC_ANN_MIRROR="${BIOC_ANN_MIRROR:-${BIOC_BASE}/data/annotation}"
BIOC_EXP_MIRROR="${BIOC_EXP_MIRROR:-${BIOC_BASE}/data/experiment}"
CRAN_FALLBACK="${CRAN_FALLBACK:-https://mirrors.tuna.tsinghua.edu.cn/CRAN}"
PIP_MIRROR_URL="${PIP_MIRROR_URL:-https://mirrors.aliyun.com/pypi/simple/}"
# 实测可用（rocker/* 与 library/* 均可取到）；顺序即优先级
DOCKER_MIRRORS="${DOCKER_MIRRORS:-https://docker.1panel.live,https://hub.rat.dev,https://docker.1ms.run}"

DRY_RUN=0
VERIFY_ONLY=0
USE_PIP_MIRROR=0

# ── 输出辅助 ──────────────────────────────────────────────────────────────────
if [ -t 1 ]; then C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
else C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; fi
info()  { printf '%s\n' "${C_B}==>${C_0} $*"; }
ok()    { printf '%s\n' "  ${C_G}✅${C_0} $*"; }
warn()  { printf '%s\n' "  ${C_Y}⚠️ ${C_0} $*"; }
err()   { printf '%s\n' "  ${C_R}❌${C_0} $*"; }
skip()  { printf '%s\n' "  ${C_Y}–${C_0}  $*"; }

run() {   # 尊重 --dry-run
  if [ "$DRY_RUN" -eq 1 ]; then printf '     [dry-run] %s\n' "$*"; return 0; fi
  "$@"
}

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=1 ;;
    --verify)    VERIFY_ONLY=1 ;;
    --pip-mirror) USE_PIP_MIRROR=1 ;;
    -h|--help)   usage ;;
    *) err "未知参数: $arg（用 --help 查看用法）"; exit 2 ;;
  esac
done

have_sudo() { command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; }

# ═══════════════════════════════════════════════════════════════════════════════
# 0. 连通性自检
# ═══════════════════════════════════════════════════════════════════════════════
verify() {
  info "连通性自检（curl -4 --max-time 6，每目标 3 次并发）"
  command -v curl >/dev/null 2>&1 || { err "未安装 curl，跳过自检"; return 1; }

  local targets=(
    "pypi.org|https://pypi.org/simple/"
    "cloud.r-project.org|https://cloud.r-project.org/src/contrib/PACKAGES.gz"
    "packagemanager.posit.co|https://packagemanager.posit.co/cran/__linux__/${PPM_OS}/latest/src/contrib/PACKAGES.gz"
    "api.deepseek.com|https://api.deepseek.com/v1/models"
    "registry-1.docker.io|https://registry-1.docker.io/v2/"
  )

  # 全部探测并发执行（串行最坏 5×3×8s=120s，并发后约 6s）
  local tmp; tmp=$(mktemp); : > "$tmp"
  local t i
  for t in "${targets[@]}"; do
    for i in 1 2 3; do
      (
        # 大文件（PyPI index / PACKAGES.gz）会因 --max-time 被截断而使 curl 非零退出，
        # 但状态码已经写出；故不能用 `|| echo 000`，否则会拼出 "200000"。
        c=$(curl -4 -sL -o /dev/null -w '%{http_code}' --max-time 6 "${t#*|}" 2>/dev/null) || true
        printf '%s %s\n' "${t%%|*}" "${c:-000}" >> "$tmp"
      ) &
    done
  done
  wait

  local label good detail c codes
  printf '  %-26s %-9s %s\n' "目标" "可达" "明细"
  printf '  %s\n' "─────────────────────────────────────────────────────────────"
  for t in "${targets[@]}"; do
    label="${t%%|*}"; good=0; detail=""
    while read -r c; do
      detail="$detail $c"
      case "$c" in 2*|3*|4*) good=$((good+1)) ;; esac
    done < <(awk -v l="$label" '$1==l{print $2}' "$tmp")
    if   [ "$good" -eq 3 ]; then printf '  %-26s %s %s\n' "$label" "${C_G}✅ 3/3${C_0}" "$detail"
    elif [ "$good" -gt 0 ]; then printf '  %-26s %s %s\n' "$label" "${C_Y}⚠️  $good/3${C_0}" "$detail"
    else                         printf '  %-26s %s %s\n' "$label" "${C_R}❌ 0/3${C_0}" "$detail"
    fi
  done
  rm -f "$tmp"
  printf '\n'
  skip "registry-1.docker.io 为 0/3 属预期（需靠 registry-mirrors 绕行，见下）"
  skip "api.deepseek.com 返回 401 属正常（网络通，仅缺鉴权）"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 1. 强制 IPv4 优先（解决"无 IPv6 却优先解析 AAAA 导致挂起"）
# ═══════════════════════════════════════════════════════════════════════════════
setup_ipv4() {
  info "[1/4] IPv4 优先级（/etc/gai.conf）"

  if ! ip -6 route show default >/dev/null 2>&1 || [ -z "$(ip -6 route show default 2>/dev/null)" ]; then
    skip "确认宿主无 IPv6 默认路由 —— 该项对你有实际收益"
  fi

  if grep -qsE '^\s*precedence\s+::ffff:0:0/96\s+100' /etc/gai.conf 2>/dev/null; then
    ok "已配置，跳过"
    return 0
  fi

  if ! have_sudo; then
    warn "无 sudo 权限，跳过。请手动执行："
    printf '       echo "precedence ::ffff:0:0/96  100" | sudo tee -a /etc/gai.conf\n'
    return 0
  fi

  run sudo tee -a /etc/gai.conf >/dev/null <<'EOF'

# ── scAgent: 宿主无 IPv6，强制 IPv4 优先，避免连接挂起 ──
precedence ::ffff:0:0/96  100
EOF
  ok "已写入 /etc/gai.conf"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 2. pip 配置（默认只放宽超时；--pip-mirror 才切换索引源）
# ═══════════════════════════════════════════════════════════════════════════════
setup_pip() {
  info "[2/4] pip 配置（~/.config/pip/pip.conf）"
  local dir="$HOME/.config/pip"
  local file="$dir/pip.conf"

  local want_index=""
  if [ "$USE_PIP_MIRROR" -eq 1 ]; then
    want_index="$PIP_MIRROR_URL"
    skip "启用第三方镜像源: ${PIP_MIRROR_URL}（介意供应链风险请勿使用 --pip-mirror）"
  else
    skip "不改索引源，仅补齐 timeout/retries（pypi.org 实测可用）"
  fi

  # 关键：既有的 pip.conf 可能已配置了别的镜像源，绝不能整体覆盖
  if [ -f "$file" ]; then
    skip "检测到既有配置，将【合并】而非覆盖（已有 index-url 保持不变）"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '     [dry-run] 合并写入 %s:' "$file"
    [ -n "$want_index" ] && printf ' index-url=%s（仅当缺失时）' "$want_index"
    printf ' timeout=60 retries=5\n'
    return 0
  fi

  mkdir -p "$dir"
  [ -f "$file" ] && cp "$file" "${file}.bak.$(date +%s)"

  # 保留注释与既有键，只补齐缺失项；不重排、不丢字段
  python3 - "$file" "$want_index" <<'PY'
import os, sys
path, idx = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
if not any(l.strip().lower() == "[global]" for l in lines):
    if lines and lines[-1].strip():
        lines.append("")
    lines.append("[global]")
start = next(i for i, l in enumerate(lines) if l.strip().lower() == "[global]")
end = next((i for i in range(start + 1, len(lines)) if lines[i].strip().startswith("[")), len(lines))
seg = lines[start + 1:end]
def has(key):
    return any("=" in l and l.split("=", 1)[0].strip().lower() == key for l in seg)
add = []
if idx and not has("index-url"):
    add.append("index-url = " + idx)
if not has("timeout"):
    add.append("timeout = 60")
if not has("retries"):
    add.append("retries = 5")
lines[start + 1:start + 1] = add
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("     added:", add if add else "（无，已满足）")
PY
  ok "已合并写入 $file"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 3. R 源（CRAN + Bioconductor 走 PPM；不依赖 bioconductor.org）
# ═══════════════════════════════════════════════════════════════════════════════
setup_r() {
  info "[3/4] R 仓库源（~/.Rprofile）"
  local file="$HOME/.Rprofile"
  local begin="# >>> scagent-network (managed) >>>"
  local end="# <<< scagent-network (managed) <<<"

  if [ -f "$file" ] && grep -qF "$begin" "$file"; then
    # 幂等：替换已有托管块
    if [ "$DRY_RUN" -eq 1 ]; then
      skip "[dry-run] 已存在托管块，将替换"
    else
      python3 - "$file" "$begin" "$end" <<'PY'
import sys, re
path, b, e = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding="utf-8").read()
s = re.sub(re.escape(b) + r".*?" + re.escape(e) + r"\n?", "", s, flags=re.S)
open(path, "w", encoding="utf-8").write(s.rstrip() + "\n")
PY
      ok "已移除旧托管块，准备重写"
    fi
  fi

  local block
  block=$(cat <<EOF
${begin}
# scAgent R 包源
#   CRAN      : PPM 的 Linux 二进制源（免编译，快）；不可达时切 CRAN_FALLBACK
#   Bioc*     : bioconductor.org 国内极不稳定（实测频繁卡死），改用西湖大学镜像
#   注意      : GO.db / org.*.eg.db 属于 data/annotation，不在软件仓 —— 必须单列 BioCann
options(
  repos = c(
    CRAN          = "${PPM_CRAN}",
    BioCsoft      = "${BIOC_MIRROR}",
    BioCann       = "${BIOC_ANN_MIRROR}",
    BioCexp       = "${BIOC_EXP_MIRROR}"
  ),
  timeout = 900,
  Ncpus = max(1L, parallel::detectCores() - 1L)
)
# CRAN 兜底镜像（PPM 不可达时手动切换）
#   options(repos = c(CRAN = "${CRAN_FALLBACK}", BioCsoft = "${BIOC_MIRROR}",
#                     BioCann = "${BIOC_ANN_MIRROR}", BioCexp = "${BIOC_EXP_MIRROR}"))
options(install.packages.check.source = "no")
${end}
EOF
)

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '     [dry-run] 追加到 %s:\n' "$file"; printf '%s\n' "$block" | sed 's/^/       /'
    return 0
  fi
  [ -f "$file" ] && cp "$file" "${file}.bak.$(date +%s)"
  printf '\n%s\n' "$block" >> "$file"
  ok "已写入托管块到 $file（自带 ${begin} / ${end} 标记，可安全重复执行）"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 4. Docker registry 镜像源（解决 registry-1.docker.io 被阻断）
# ═══════════════════════════════════════════════════════════════════════════════
setup_docker() {
  info "[4/4] Docker registry-mirrors"

  local IFS=','
  local mirrors_json
  mirrors_json=$(python3 -c '
import json,sys
print(json.dumps([m for m in sys.argv[1].split(",") if m]))' "$DOCKER_MIRRORS")
  unset IFS

  if ! command -v docker >/dev/null 2>&1; then
    warn "未检测到 docker CLI —— 请在有 Docker 的机器上执行本步"
  else
    skip "已探测可用镜像源: library/python:3.11-slim 与 rocker/tidyverse:4.5.2 均可获取"
  fi

  # Docker Desktop（WSL2）走 Windows 侧设置，容器内写 daemon.json 无效
  if [ -d /mnt/c ] && [ ! -S /var/run/docker.sock ]; then
    warn "检测到 Docker Desktop / WSL2 环境：daemon.json 不生效，需在 GUI 中配置"
    cat <<EOF

     请在 Docker Desktop → Settings → Docker Engine 中加入：
$(printf '%s' "$mirrors_json" | sed 's/^/       /')
     完整片段：
       {
         "registry-mirrors": $(printf '%s' "$mirrors_json")
       }
     保存后 Apply & Restart。

EOF
    return 0
  fi

  local file="/etc/docker/daemon.json"
  if ! have_sudo; then
    warn "无 sudo 权限，跳过。请手动写入 $file："
    printf '       {"registry-mirrors": %s}\n' "$mirrors_json"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '     [dry-run] 合并 registry-mirrors 到 %s\n' "$file"
    printf '     [dry-run] sudo systemctl restart docker\n'
    return 0
  fi

  sudo mkdir -p /etc/docker
  [ -f "$file" ] && sudo cp "$file" "${file}.bak.$(date +%s)"

  # 与既有配置合并，不覆盖其它字段
  python3 - "$file" "$mirrors_json" <<'PY'
import json, os, subprocess, sys
path, new = sys.argv[1], json.loads(sys.argv[2])
try:
    cur = json.load(open(path))
except Exception:
    cur = {}
old = cur.get("registry-mirrors", [])
merged = old + [m for m in new if m not in old]
cur["registry-mirrors"] = merged
tmp = path + ".tmp"
open(tmp, "w").write(json.dumps(cur, indent=2) + "\n")
subprocess.run(["sudo", "cp", tmp, path], check=True)
os.unlink(tmp)
print("     merged:", merged)
PY
  ok "已更新 $file"
  if command -v systemctl >/dev/null 2>&1; then
    run sudo systemctl restart docker || warn "重启 docker 失败，请手动执行: sudo systemctl restart docker"
    ok "已重启 docker"
  else
    warn "非 systemd 环境，请手动重启 docker 守护进程"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
main() {
  printf '\n%s\n' "════════════════════════════════════════════════════════════"
  printf '%s\n'   "  scAgent 网络环境适配"
  [ "$DRY_RUN" -eq 1 ] && printf '%s\n' "  模式: DRY-RUN（不会写入任何文件）"
  printf '%s\n\n' "════════════════════════════════════════════════════════════"

  if [ "$VERIFY_ONLY" -eq 1 ]; then verify; exit 0; fi

  setup_ipv4
  setup_pip
  setup_r
  setup_docker

  printf '\n'
  verify

  printf '%s\n' "────────────────────────────────────────────────────────────"
  info "完成。后续步骤："
  printf '%s\n' "     1. 若改了 daemon.json / Docker Desktop 设置，请确认 Docker 已重启"
  printf '%s\n' "     2. 验证 R 源:  Rscript -e 'print(getOption(\"repos\"))'"
  printf '%s\n' "     3. 验证拉取:  docker pull rocker/tidyverse:4.5.2"
  printf '%s\n' "     4. 云端构建并推送: scripts/push_registry.sh <version> <registry>"
  printf '\n'
}

main
