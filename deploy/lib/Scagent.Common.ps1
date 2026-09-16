# ═══════════════════════════════════════════════════════════════════════════════
#  deploy/lib/Scagent.Common.ps1 —— PowerShell 侧公共库（Windows 原生启动路径）
#
#  与 deploy/lib/image-source.sh 一一对应：**同一套契约、同一个动词表**。
#  两边都只做"薄编排"，真正的逻辑留在 deploy/docker-compose.yml 里。
#
#  兼容性：Windows PowerShell 5.1（不要求 PS7）。因此：
#    · 不使用 `??`、三元运算符、`-SkipCertificateCheck` 等 7.x 语法
#    · 本文件含中文，**必须存成 UTF-8 with BOM**，否则 PS 5.1 会按 ANSI 解码导致乱码/语法错误
#
#  加载方式（由 deploy/scagent.ps1 点源加载）：
#      . "$PSScriptRoot\lib\Scagent.Common.ps1"
# ═══════════════════════════════════════════════════════════════════════════════

# ── 输出 ──────────────────────────────────────────────────────────────────────
function Write-ScBanner {
    param([string]$Text)
    Write-Host ''
    Write-Host ('═' * 60) -ForegroundColor DarkCyan
    Write-Host ("  $Text") -ForegroundColor Cyan
    Write-Host ('═' * 60) -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-ScInfo {
    param([string]$Text)
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Write-ScOk {
    param([string]$Text)
    Write-Host "  [OK] $Text" -ForegroundColor Green
}

function Write-ScWarn {
    param([string]$Text)
    Write-Host "  [!]  $Text" -ForegroundColor Yellow
}

function Write-ScErr {
    param([string]$Text)
    Write-Host "  [X]  $Text" -ForegroundColor Red
}

function Write-ScStep {
    param([string]$Text)
    Write-Host "      $Text" -ForegroundColor DarkGray
}

# 退出码约定（与 §7.6 动词契约一致）
function Exit-Sc {
    param(
        [string]$Message = '',
        [int]$Code = 1
    )
    if ($Message) { Write-ScErr $Message }
    exit $Code
}

# ── Docker 基础 ───────────────────────────────────────────────────────────────
function Test-ScDocker {
    <# 返回 $true/$false：docker CLI 可用且守护进程可达 #>
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    try {
        $null = & docker info --format '{{.ServerVersion}}' 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Assert-ScDocker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Exit-Sc "未找到 docker 命令。请先安装 Docker Desktop： https://www.docker.com/products/docker-desktop/" 1
    }
    if (-not (Test-ScDocker)) {
        Exit-Sc @"
无法连接 Docker 守护进程。请检查：
      · Docker Desktop 是否已启动（任务栏鲸鱼图标为绿色/运行中）
      · Windows 下**不需要** WSL 发行版；Docker Desktop 自带 Linux 引擎
      · 若刚安装，等它完成初始化后重试
    验证命令： docker info
"@ 1
    }
}

function Get-ScDockerInfoValue {
    param([Parameter(Mandatory)][string]$Format)
    try {
        $v = & docker info --format $Format 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ([string]$v).Trim()
    } catch {
        return $null
    }
}

function Invoke-ScCompose {
    <# 在仓库根目录执行 docker compose；失败即抛异常（除非 -AllowFail） #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$Files = @(),
        [string[]]$Arguments = @(),
        [switch]$AllowFail,
        [switch]$DryRun
    )
    $cmd = @('compose')
    foreach ($f in $Files) { $cmd += @('-f', $f) }
    $cmd += $Arguments

    if ($DryRun) {
        Write-ScStep ("[dry-run] " + (($cmd | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '))
        return 0
    }

    Push-Location -LiteralPath $RepoRoot
    try {
        & docker @cmd
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($code -ne 0 -and -not $AllowFail) {
        throw "docker compose 执行失败（退出码 $code）： compose $($Arguments -join ' ')"
    }
    return $code
}

function Get-ScComposeArgs {
    <# 组装 `compose -f ... -f ...` 参数前缀 #>
    param([string[]]$Files = @())
    # 不要用 $args 作变量名：它是 PowerShell 的自动变量
    $composeArgs = @('compose')
    foreach ($f in $Files) { $composeArgs += @('-f', $f) }
    # 逗号运算符：避免单元素数组被展开成字符串后，后续 += 变成字符串拼接
    return , $composeArgs
}

function Get-ScComposeOutput {
    <# 执行 compose 并返回输出行（不因失败抛异常） #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $cmd = Get-ScComposeArgs -Files $Files
    $cmd += $Arguments
    Push-Location -LiteralPath $RepoRoot
    try {
        $out = & docker @cmd 2>$null
    } finally {
        Pop-Location
    }
    return @($out)
}

# ── .env 读写（UTF-8 无 BOM + LF，见 C8）──────────────────────────────────────
function Read-ScEnvFile {
    param([Parameter(Mandatory)][string]$Path)
    $result = New-Object System.Collections.Specialized.OrderedDictionary
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $t = $line.Trim()
        if ($t.Length -eq 0) { continue }
        if ($t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $t.Substring(0, $i).Trim()
        $v = $t.Substring($i + 1).Trim()
        if ($v.Length -ge 2) {
            $dq = $v.StartsWith('"') -and $v.EndsWith('"')
            $sq = $v.StartsWith("'") -and $v.EndsWith("'")
            if ($dq -or $sq) { $v = $v.Substring(1, $v.Length - 2) }
        }
        $result[$k] = $v
    }
    # 逗号运算符：字典实现 IEnumerable，避免被管道展开成 DictionaryEntry
    return , $result
}

function Write-ScEnvFile {
    <# 写 UTF-8 无 BOM + LF —— 这两点都必须保证，否则令牌会带 \r 导致 401 #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Data,          # OrderedDictionary
        [string]$Header = ''
    )
    $sb = New-Object System.Text.StringBuilder
    if ($Header) {
        foreach ($l in ($Header -split "`n")) { [void]$sb.Append(($l -replace "`r", '') + "`n") }
    }
    foreach ($k in $Data.Keys) {
        [void]$sb.Append("$k=$($Data[$k])`n")
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), $utf8NoBom)
}

function New-ScRandomHex {
    param([int]$Bytes = 24)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buf = New-Object byte[] $Bytes
        $rng.GetBytes($buf)
        return (($buf | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $rng.Dispose()
    }
}

# ── 镜像来源解析（与 image-source.sh 同规则）──────────────────────────────────
function Assert-ScNotPublicHub {
    param([Parameter(Mandatory)][string]$Prefix)
    $p = $Prefix.ToLower()
    if ($p -match '^(docker\.io|index\.docker\.io|registry-1\.docker\.io)(/|$)' -or
        $p -match '^library/' -or $p -match '/library/') {
        throw "拒绝使用公网 Docker Hub 命名空间：$Prefix"
    }
}

function Resolve-ScImageSource {
    <# 由 SCAGENT_IMAGE_SOURCE 推导前缀与拉取策略；失败即抛异常（调用方决定退出码） #>
    param(
        [string]$Source = 'local',
        [string]$Prefix = '',
        [string]$Version = '',
        [string]$PullPolicy = ''
    )
    if (-not $Version) { throw "未设置 SCAGENT_VERSION（镜像标签，见 deploy\.env.sample）" }

    $src = "$Source".Trim().ToLower()
    if (-not $src) { $src = 'local' }

    if ($src -eq 'local') {
        if (-not $Prefix) { $Prefix = 'scagent' }
        Assert-ScNotPublicHub $Prefix
        if ($Prefix -match '[.:]') {
            throw "local 模式的 SCAGENT_IMAGE_PREFIX 是本地镜像名，不应含 registry 主机名：$Prefix（若镜像来自 registry，请把 SCAGENT_IMAGE_SOURCE 改成 private 或 public）"
        }
        $PullPolicy = 'never'      # local 强制不拉取
    } elseif ($src -eq 'public') {
        if (-not $Prefix) { $Prefix = 'ghcr.io/17xxxx/scagent' }
        Assert-ScNotPublicHub $Prefix
        if (-not $PullPolicy) { $PullPolicy = 'missing' }
    } elseif ($src -eq 'private') {
        if (-not $Prefix) { throw "private 模式必须显式设置 SCAGENT_IMAGE_PREFIX（如 harbor.corp.local/scagent）" }
        Assert-ScNotPublicHub $Prefix
        if (-not ($Prefix -match '[.:]')) {
            throw "private 模式的 SCAGENT_IMAGE_PREFIX 必须含 registry 主机名（含点或冒号）：$Prefix"
        }
        if (-not $PullPolicy) { $PullPolicy = 'missing' }
    } else {
        throw "SCAGENT_IMAGE_SOURCE 只能是 local / public / private（当前：$Source）"
    }

    return [pscustomobject]@{
        Source     = $src
        Prefix     = $Prefix
        Version    = $Version
        PullPolicy = $PullPolicy
    }
}

function Get-ScImageName {
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Service
    )
    return "$Prefix/scagent-$Service`:$Version"
}

# ── 路径解析 ──────────────────────────────────────────────────────────────────
function Resolve-ScPath {
    <# 支持 D:/x、D:\x、/mnt/d/x（WSL 写法，自动转成 D:/x）与相对 deploy/ 的路径 #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $p = $Path.Trim()
    if ($p -match '^/mnt/([A-Za-z])/(.*)$') {
        $drive = $Matches[1].ToUpper()
        $p = ($drive + ':/' + $Matches[2])
    }
    if ($p -match '^[A-Za-z]:[\\/]') {
        return ($p -replace '\\', '/')
    }
    if ($p.StartsWith('/')) { return $p }
    $rel = $p
    if ($rel.StartsWith('./')) { $rel = $rel.Substring(2) }
    return (($RepoRoot -replace '\\', '/').TrimEnd('/') + '/deploy/' + $rel)
}

function Get-ScFreeSpaceGB {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetPathRoot($full)
        if (-not $root) { return $null }
        $d = New-Object System.IO.DriveInfo($root)
        return [math]::Round($d.AvailableFreeSpace / 1GB, 1)
    } catch {
        return $null
    }
}

function Test-ScPortInUse {
    param(
        [string]$TargetHost = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 800
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $ok) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Set-ScAcl {
    <#
      Windows 上没有 chmod 600，只能用 icacls 收紧（C3）。三条经验（P2.1）：
        1. 主体必须用**完整身份**（DOMAIN\user），只写用户名可能落到不可解析的 SID，
           结果是自己也访问不了；
        2. **必须保留 SYSTEM 与 Administrators**，否则文件会变成谁也改不了、删不掉的"死锁"；
        3. 因此默认**不做** ACL 收紧（NTFS 继承 ACL 已经限制其他普通用户），
           需要时用 -HardenAcl 显式开启。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$WhatIfOnly
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $me = ''
    try { $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { }
    if (-not $me) { $me = "$env:USERDOMAIN\$env:USERNAME" }
    # 注意：不能写 "$me:(OI)(CI)F" —— PowerShell 会把 `$me:` 当成"盘符变量"导致**解析错误**
    # （整文件解析失败 → 所有函数都没定义 → 调用处刷屏报 CommandNotFound）。必须用 ${} 界定。
    $grantMe = "${me}:(OI)(CI)F"
    if ($WhatIfOnly) {
        Write-ScStep ('[dry-run] icacls "{0}" /inheritance:r /grant:r "{1}" /grant:r "SYSTEM:(OI)(CI)F" /grant:r "Administrators:(OI)(CI)F"' -f $Path, $grantMe)
        return
    }
    try {
        $null = & icacls "$Path" /inheritance:r `
            /grant:r $grantMe `
            /grant:r 'SYSTEM:(OI)(CI)F' `
            /grant:r 'Administrators:(OI)(CI)F' 2>&1
        if ($LASTEXITCODE -eq 0) { Write-ScOk "已收紧访问权限（保留 SYSTEM/Administrators 以便恢复）：$Path" }
        else { Write-ScWarn "icacls 未成功（可忽略）：$Path" }
    } catch {
        Write-ScWarn "icacls 调用失败（可忽略）：$Path"
    }
}

function Open-ScBrowser {
    param([Parameter(Mandatory)][string]$Url)
    try {
        Start-Process $Url | Out-Null
        return $true
    } catch {
        Write-ScWarn "无法自动打开浏览器：$Url"
        return $false
    }
}

# ── 健康检查 ──────────────────────────────────────────────────────────────────
function Wait-ScHealthy {
    <# 轮询容器健康状态；返回 $true/$false。seurat 冷启动约需 120 秒 #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$Files,
        [int]$TimeoutSec = 300
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $json = Get-ScComposeOutput -RepoRoot $RepoRoot -Files $Files -Arguments @('ps', '--format', 'json')
        $ids  = Get-ScComposeOutput -RepoRoot $RepoRoot -Files $Files -Arguments @('ps', '-q')

        $idCount = 0
        if ($ids) { $idCount = @($ids | Where-Object { $_ -and "$_".Trim() -ne '' }).Count }

        $unhealthy = 0
        if ($json) {
            $raw = ($json -join "`n")
            # 兼容 compose 两种输出形态（逐行 JSON 或 JSON 数组）
            $unhealthy = ([regex]::Matches($raw, '"Health"\s*:\s*"(?!healthy)[A-Za-z]+"')).Count
        }
        if ($idCount -ge 2 -and $unhealthy -eq 0) { return $true }
        Write-Host "`r  ... 等待容器健康（剩余 $([int](($deadline - (Get-Date)).TotalSeconds)) 秒）" -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds 5
    }
    Write-Host ''
    return $false
}

function Get-ScHttpStatus {
    <# 返回 HTTP 状态码（失败返回 0）；用于验证"无令牌必须 401" #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Token = '',
        [int]$TimeoutSec = 10
    )
    $headers = @{}
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    try {
        $resp = Invoke-WebRequest -Uri $Url -Headers $headers -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        return [int]$resp.StatusCode
    } catch {
        $r = $_.Exception.Response
        if ($r -ne $null) {
            try { return [int]$r.StatusCode } catch { return 0 }
        }
        return 0
    }
}

function Get-ScAgentHealth {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Token = ''
    )
    $headers = @{}
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    try {
        return Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec 15 -ErrorAction Stop
    } catch {
        return $null
    }
}

function Get-ScToken {
    <# 取访问令牌：优先 secrets 文件，其次 .env #>
    param(
        [Parameter(Mandatory)]$Env,
        [Parameter(Mandatory)][string]$SecretsDir
    )
    $f = Join-Path $SecretsDir 'scagent_token'
    if (Test-Path -LiteralPath $f) {
        return ([System.IO.File]::ReadAllText($f)).Trim()
    }
    if ($Env.Contains('SCAGENT_TOKEN')) { return ([string]$Env['SCAGENT_TOKEN']).Trim() }
    return ''
}

function Read-ScSecretFile {
    <# 读密钥文件：成功返回值；失败返回 $null（不抛异常，避免刷屏） #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        return ([System.IO.File]::ReadAllText($Path)).Trim()
    } catch {
        return $null
    }
}

function Test-ScSecretReadable {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
        $stream.Close()
        return $true
    } catch {
        return $false
    }
}

function Write-ScAclRepairHint {
    <# 密钥文件被 ACL 锁住时给出的修复指引（见 docs §9.3 W-4/W-6） #>
    param([Parameter(Mandatory)][string]$Dir)
    Write-ScStep '该目录的 ACL 可能被收紧到了别的账户（旧的 icacls /inheritance:r 遗留）。修复（管理员 PowerShell）：'
    Write-ScStep "  takeown /F `"$Dir`" /R /D Y"
    Write-ScStep "  icacls `"$Dir`" /reset /T /C"
    Write-ScStep "  icacls `"$Dir`"        # 确认已恢复继承来的 Users/Administrators"
    Write-ScStep '若仍不可读，也可整个删掉让 install 重新生成： Remove-Item "<目录>" -Recurse -Force'
}

function Get-ScSecretsDir {
    <# 密钥目录：优先 .env 里的 SCAGENT_SECRETS_DIR；否则用调用方给的默认目录
       （默认目录 = 安装根下的 secrets，**不在仓库内**，与 setup_secrets.sh 的默认一致） #>
    param(
        [Parameter(Mandatory)]$Env,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$FallbackDir = ''
    )
    $raw = ''
    if ($Env.Contains('SCAGENT_SECRETS_DIR')) { $raw = "$($Env['SCAGENT_SECRETS_DIR'])".Trim() }
    if ($raw) { return (Resolve-ScPath -Path $raw -RepoRoot $RepoRoot) }
    if ($FallbackDir) { return $FallbackDir }
    return (Resolve-ScPath -Path '../secrets' -RepoRoot $RepoRoot)
}

function Get-ScSecretsFiles {
    <# 返回本套部署要用的 compose 文件列表（有密钥文件时自动叠加 secrets 覆盖） #>
    param(
        [Parameter(Mandatory)][string]$SecretsDir
    )
    $files = @('deploy/docker-compose.yml')
    $hasSecrets = (Test-Path -LiteralPath (Join-Path $SecretsDir 'deepseek_api_key')) -and
                  (Test-Path -LiteralPath (Join-Path $SecretsDir 'scagent_token'))
    if ($hasSecrets) { $files += 'deploy/docker-compose.secrets.yml' }
    return [pscustomobject]@{ Files = $files; HasSecrets = $hasSecrets }
}

function Test-ScImageExists {
    param([Parameter(Mandatory)][string]$Image)
    try {
        $null = & docker image inspect $Image 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}
