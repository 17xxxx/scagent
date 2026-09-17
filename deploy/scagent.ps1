# ═══════════════════════════════════════════════════════════════════════════════
#  deploy/scagent.ps1 —— Windows 单机部署入口（方案 ①）
#
#  用户只需要装 Docker Desktop，然后双击 deploy\install.cmd 即可。
#  不需要 WSL 发行版、不需要 Git、不需要命令行知识。
#
#  用法：
#      deploy\install.cmd                       # 双击：完整安装（推荐）
#      deploy\scagent.cmd status                # 看状态
#      deploy\scagent.cmd up|down|restart|logs  # 服务控制
#      deploy\scagent.cmd verify                # 部署自检（中文报告）
#      deploy\scagent.cmd secrets               # 只生成/检查密钥
#      powershell -ExecutionPolicy Bypass -File deploy\scagent.ps1 install -Root D:\scagent
#
#  可选参数：
#      -Root <目录>        数据/密钥根目录（默认：仓库上级目录，或 <系统盘>:\scagent）
#      -ImageSource <src>  local | public | private（默认 local：本机构建）
#      -ImagePrefix <前缀> 镜像前缀；配 -ImageSource 用，默认按来源推导
#                          （指向已发布镜像时用，如国内加速：
#                           -ImageSource public -ImagePrefix crpi-4le1vixwpzhdr5y0.cn-beijing.personal.cr.aliyuncs.com/sqxopen）
#      -Refdata <值>       参考数据集（细胞类型注释用）：mouse | human | both | none
#                          不指定时安装向导会询问；-Yes（非交互）默认不下载
#      -Version <tag>      镜像标签（默认 1.0.0）
#      -DeepSeekKey <sk->  非交互提供 LLM 密钥
#      -Yes                不交互（配合 -DeepSeekKey）
#      -NoBrowser          不自动打开浏览器
#      -DryRun             只打印将要执行的命令，不实际执行
#
#  兼容性：Windows PowerShell 5.1（本文件含中文，必须存成 UTF-8 with BOM）
# ═══════════════════════════════════════════════════════════════════════════════
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Verb = 'help',
    [string]$Root = '',
    [string]$ImageSource = '',
    [string]$ImagePrefix = '',
    [string]$Refdata = '',
    [string]$Version = '',
    [string]$DeepSeekKey = '',
    [switch]$Yes,
    [switch]$NoBrowser,
    [switch]$DryRun,
    [switch]$HardenAcl,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

# 注意：**不能**用 'Stop' —— PS 5.1 会把原生命令（docker）写 stderr 当成终止性错误抛出，
# 而"预期内的失败"（探测镜像不存在、V2 守卫故意让 compose 报错）本来就会写 stderr。
# 统一用 Continue，靠 $LASTEXITCODE / try-catch 显式判断。
$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch { }

# 本文件在 deploy\ 下，仓库根 = 上一级
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }

# 部署脚本版本（随发布 tag 更新）
$ScagentBuild = '1.0.0'
$libPath = Join-Path $PSScriptRoot 'lib\Scagent.Common.ps1'

# ── 预检：先解析两个脚本 ──────────────────────────────────────────────────────
#  为什么要有这一步：如果 lib 里有一个解析错误，dot-source 只报一行，
#  但**里面所有函数都没被定义**，于是后续每一行调用都刷出 CommandNotFound ——
#  几十行报错会掩盖真正的原因（例如字符串里的 "$me:" 被当成盘符变量）。
$parseErrors = New-Object System.Collections.ArrayList
foreach ($p in @($libPath, $PSCommandPath)) {
    if (-not $p) { continue }
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host ''
        Write-Host "  [X]  缺少脚本文件： $p" -ForegroundColor Red
        exit 2
    }
    $tokens = $null; $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errs)
    if ($errs) { foreach ($e in $errs) { [void]$parseErrors.Add([pscustomobject]@{ File = $p; Err = $e }) } }
}
if ($parseErrors.Count -gt 0) {
    Write-Host ''
    Write-Host '  [X]  脚本自身有语法错误，已中止（安装包损坏或文件同步不完整）' -ForegroundColor Red
    foreach ($pe in $parseErrors) {
        Write-Host ("      {0}:{1}: {2}" -f (Split-Path -Leaf $pe.File), $pe.Err.Extent.StartLineNumber, $pe.Err.Message) -ForegroundColor Red
    }
    Write-Host '      修复：从仓库重新同步 deploy\scagent.ps1 与 deploy\lib\Scagent.Common.ps1' -ForegroundColor Yellow
    Write-Host ''
    exit 2
}

. $libPath

$EnvFile = Join-Path $PSScriptRoot '.env'

function Show-ScUsage {
    Write-ScBanner "scAgent 部署工具（Windows） · $ScagentBuild"
    Write-Host '  用法：'
    Write-Host '    deploy\install.cmd                    完整安装（自检 -> 生成密钥 -> 起服务 -> 开浏览器）'
    Write-Host '    deploy\scagent.cmd up                 启动 / 更新服务'
    Write-Host '    deploy\scagent.cmd build [-Force] [-NoCache]   本机构建镜像（分两步：runtime 层 → 应用层）'
    Write-Host '    deploy\scagent.cmd down               停止服务（数据与密钥保留）'
    Write-Host '    deploy\scagent.cmd restart            重启服务'
    Write-Host '    deploy\scagent.cmd status             查看状态'
    Write-Host '    deploy\scagent.cmd logs [服务名]      查看日志（默认 agent）'
    Write-Host '    deploy\scagent.cmd verify             部署自检'
    Write-Host '    deploy\scagent.cmd doctor [-Quick]    部署体检（环境/配置/镜像/密钥/数据/服务/网络）'
    Write-Host '    deploy\scagent.cmd backup             备份（.env 脱敏、默认排除密钥与 .rds）'
    Write-Host '    deploy\scagent.cmd rollback [-List]   回滚到 :prev（-List 列出本地镜像版本）'
    Write-Host '    deploy\scagent.cmd refdata           获取参考数据集（细胞类型注释用，需外网）'
    Write-Host '    deploy\scagent.cmd secrets            生成 / 检查密钥文件'
    Write-Host ''
    Write-Host '  常用参数： -Root D:\scagent  -ImageSource local|public|private  -ImagePrefix <前缀>  -Refdata mouse|human|both|none  -DryRun'
    Write-Host '  指向已发布镜像： deploy\install.cmd -ImageSource public -ImagePrefix crpi-4le1vixwpzhdr5y0.cn-beijing.personal.cr.aliyuncs.com/sqxopen'
    Write-Host ''
}

function Get-DefaultRoot {
    $parent = Split-Path -Parent $RepoRoot
    if ((Split-Path -Leaf $RepoRoot) -eq 'scagent' -and $parent) { return $parent }
    if ($env:SystemDrive) { return (Join-Path ($env:SystemDrive + '\') 'scagent') }
    return (Join-Path $parent 'scagent')
}

function Get-ScEnvValue {
    param($Env, [string]$Key, [string]$Default = '')
    if ($Env -and $Env.Contains($Key)) {
        $v = "$($Env[$Key])".Trim()
        if ($v) { return $v }
    }
    return $Default
}

function Get-ScEnvInt {
    param($Env, [string]$Key, [int]$Default = 0)
    $v = Get-ScEnvValue -Env $Env -Key $Key -Default ''
    if ($v -match '^\d+$') { return [int]$v }
    return $Default
}

function Get-ScContext {
    <# 读取 .env（或调用方给的映射，dry-run 用）并解析常用值；问题原因放进 ImageError #>
    param($EnvMap = $null)
    $envMap = $EnvMap
    if ($null -eq $envMap) { $envMap = Read-ScEnvFile -Path $EnvFile }
    $secretsDir = Get-ScSecretsDir -Env $envMap -RepoRoot $RepoRoot -FallbackDir (Join-Path (Get-DefaultRoot) 'secrets')
    $image = $null
    $err = $null
    if ($envMap.Count -gt 0) {
        try {
            $image = Resolve-ScImageSource -Source (Get-ScEnvValue -Env $envMap -Key 'SCAGENT_IMAGE_SOURCE' -Default 'local') `
                                          -Prefix (Get-ScEnvValue -Env $envMap -Key 'SCAGENT_IMAGE_PREFIX') `
                                          -Version (Get-ScEnvValue -Env $envMap -Key 'SCAGENT_VERSION') `
                                          -PullPolicy (Get-ScEnvValue -Env $envMap -Key 'SCAGENT_PULL_POLICY')
        } catch {
            $err = $_.Exception.Message
        }
    } else {
        # .env 缺失/为空：必须显式报错，否则后续把空字符串传给参数会炸在莫名其妙的地方
        $err = 'deploy\.env 缺失或为空（先运行 deploy\install.cmd，或手动 cp .env.sample .env）'
    }
    return [pscustomobject]@{
        Env        = $envMap
        SecretsDir = $secretsDir
        Image      = $image
        ImageError = $err
        Port       = (Get-ScEnvInt -Env $envMap -Key 'SCAGENT_PORT' -Default 8080)
        BindAddr   = (Get-ScEnvValue -Env $envMap -Key 'SCAGENT_BIND_ADDR' -Default '127.0.0.1')
    }
}

# 未配置时的默认上下文（供 build / refdata 这类"配置前"操作使用）
function Get-ScDefaultContext {
    $empty = New-Object System.Collections.Specialized.OrderedDictionary
    $image = $null
    $err = $null
    try { $image = Resolve-ScImageSource -Source 'local' -Prefix '' -Version '1.0.0' -PullPolicy '' }
    catch { $err = $_.Exception.Message }
    # 没有 deploy\.env 时，docker compose 只能从**进程环境**取插值变量 —— 必须显式设置，
    # 否则会报 "required variable SCAGENT_VERSION is missing a value"。
    if ($image) {
        $env:SCAGENT_IMAGE_PREFIX = $image.Prefix
        $env:SCAGENT_VERSION      = $image.Version
        $env:SCAGENT_PULL_POLICY  = $image.PullPolicy
    }
    return [pscustomobject]@{
        Env        = $empty
        SecretsDir = (Join-Path (Get-DefaultRoot) 'secrets')
        Image      = $image
        ImageError = $err
        Port       = 8080
        BindAddr   = '127.0.0.1'
    }
}

function Get-ScContextOrDefault {
    <# build / refdata 用：没有 deploy\.env 时退回默认值（local / scagent / 1.0.0） #>
    $ctx = Get-ScContext
    if ($ctx.Env.Count -eq 0) {
        Write-ScWarn '未找到 deploy\.env —— 使用默认值：SCAGENT_IMAGE_SOURCE=local、前缀 scagent、版本 1.0.0'
        Write-ScStep '（要自定义镜像来源/版本/数据目录，请先运行 deploy\install.cmd，或手动创建 deploy\.env）'
        return (Get-ScDefaultContext)
    }
    return $ctx
}

function Get-ScUrl {
    param($Ctx)
    return "http://127.0.0.1:$($Ctx.Port)"
}

function Assert-ScConfigured {
    param($Ctx)
    if ($Ctx.Env.Count -eq 0) {
        Exit-Sc "缺少 deploy\.env。请先运行： deploy\install.cmd" 2
    }
    if ($Ctx.ImageError) {
        Exit-Sc "部署配置无效：$($Ctx.ImageError)`n    详见 deploy\.env.sample" 2
    }
    foreach ($k in @('SCAGENT_WORKSPACE', 'SCAGENT_BIODATA')) {
        if (-not (Get-ScEnvValue -Env $Ctx.Env -Key $k)) {
            Exit-Sc "deploy\.env 中缺少必填项 $k（必须是绝对路径，如 D:/scagent/workspace）" 2
        }
    }
}

# ── 动词：secrets ─────────────────────────────────────────────────────────────
function Invoke-ScSecretsVerb {
    param($Ctx)
    $dir = $Ctx.SecretsDir
    $keyFile = Join-Path $dir 'deepseek_api_key'
    $tokFile = Join-Path $dir 'scagent_token'

    if (-not (Test-Path -LiteralPath $dir)) {
        if ($DryRun) { Write-ScStep "[dry-run] 创建目录 $dir" }
        else { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    $key = ''
    $keyExisted = Test-Path -LiteralPath $keyFile
    $keyReadable = $false
    if ($keyExisted) {
        $v = Read-ScSecretFile -Path $keyFile
        if ($null -ne $v) { $key = $v; $keyReadable = $true }
    } elseif ($DeepSeekKey) {
        $key = $DeepSeekKey.Trim()
    } elseif (Get-ScEnvValue -Env $Ctx.Env -Key 'DEEPSEEK_API_KEY') {
        $key = Get-ScEnvValue -Env $Ctx.Env -Key 'DEEPSEEK_API_KEY'
    } elseif (-not $Yes -and -not $DryRun) {
        Write-ScInfo '需要 LLM API Key'
        Write-Host '  到 https://platform.deepseek.com/api_keys 创建一个并粘贴（输入不回显）：'
        $sec = Read-Host -AsSecureString '  API Key'
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $key = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr).Trim() }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    if ($key) {
        if ($keyReadable) {
            Write-ScOk "LLM 密钥已存在：$keyFile"
        } elseif ($DryRun) {
            Write-ScStep "[dry-run] 写入 $keyFile"
        } else {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($keyFile, $key, $utf8NoBom)
            Write-ScOk "已写入 LLM 密钥：$keyFile"
        }
    } elseif (-not $keyExisted) {
        Write-ScWarn '未提供 LLM API Key —— agent 要求 LLM 可用，缺密钥会直接退出（容器反复重启）'
        Write-ScStep '  稍后补上即可： deploy\scagent.cmd secrets'
        Write-ScStep '  若用本地模型： deploy\.env 里设 SCAGENT_LLM_PROVIDER=ollama（不需要密钥文件）'
    }

    $token = ''
    $tokExisted = Test-Path -LiteralPath $tokFile
    $tokReadable = $false
    if ($tokExisted) {
        $v = Read-ScSecretFile -Path $tokFile
        if ($null -ne $v) { $token = $v; $tokReadable = $true; Write-ScOk "访问令牌已存在：$tokFile" }
    } else {
        $token = New-ScRandomHex -Bytes 24
        if ($DryRun) {
            Write-ScStep "[dry-run] 写入 $tokFile（新令牌）"
        } else {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($tokFile, $token, $utf8NoBom)
            Write-ScOk "已生成访问令牌：$tokFile"
        }
    }

    # ── 密钥可读性预检 ────────────────────────────────────────────────
    #   容器会以 uid 1000 去读这两个文件；这里先确认**当前用户**读得到。
    #   读不到时容器启动必然失败，且报错很难懂，所以在启动前就点明并给出修复命令。
    $unreadable = @()
    foreach ($f in @($keyFile, $tokFile)) {
        if ((Test-Path -LiteralPath $f) -and -not (Test-ScSecretReadable -Path $f)) { $unreadable += $f }
    }
    if ($unreadable.Count -gt 0) {
        Write-ScWarn "以下密钥文件存在但当前用户**读不到**（容器更读不到）："
        foreach ($f in $unreadable) { Write-ScStep "  $f" }
        Write-ScAclRepairHint -Dir $dir
        if (-not $DryRun) {
            Exit-Sc '请先按上面的命令修复权限（或删掉该目录后重跑 install），再执行安装。' 1
        }
    }

    if ($HardenAcl) {
        # 仅在显式要求收紧时执行（默认不改动 ACL）
        Set-ScAcl -Path $dir -WhatIfOnly:$DryRun
        if (Test-Path -LiteralPath $keyFile) { Set-ScAcl -Path $keyFile -WhatIfOnly:$DryRun }
        if (Test-Path -LiteralPath $tokFile) { Set-ScAcl -Path $tokFile -WhatIfOnly:$DryRun }
    } elseif (-not $DryRun) {
        Write-ScStep '未改动 ACL（默认）。若确需仅限本用户访问，可重跑： deploy\scagent.cmd secrets -HardenAcl'
    }
    return $token
}

function New-ScEnvFromTemplate {
    <# 生成 .env 内容（并写盘，除非 -DryRun）；**返回生成的映射**，
       让 dry-run 也能继续走后面的流程（否则读不到 .env 会中途报错） #>
    param([string]$InstallRoot, [string]$Src, [string]$Ver, [string]$Prefix = '')
    $data = New-Object System.Collections.Specialized.OrderedDictionary
    $data['SCAGENT_IMAGE_SOURCE'] = $Src
    # 显式给的前缀（-ImagePrefix）优先；否则按来源推导默认值
    if ($Prefix) { $data['SCAGENT_IMAGE_PREFIX'] = $Prefix }
    elseif ($Src -eq 'local') { $data['SCAGENT_IMAGE_PREFIX'] = 'scagent' }
    elseif ($Src -eq 'public') { $data['SCAGENT_IMAGE_PREFIX'] = 'ghcr.io/17xxxx/scagent' }
    else { $data['SCAGENT_IMAGE_PREFIX'] = 'harbor.example.com/scagent' }
    $data['SCAGENT_VERSION'] = $Ver
    if ($Src -eq 'local') { $data['SCAGENT_PULL_POLICY'] = 'never' } else { $data['SCAGENT_PULL_POLICY'] = 'missing' }
    $rootFwd = ($InstallRoot -replace '\\', '/').TrimEnd('/')
    $data['SCAGENT_WORKSPACE'] = "$rootFwd/workspace"
    $data['SCAGENT_BIODATA'] = "$rootFwd/biodata"
    $data['SCAGENT_SECRETS_DIR'] = "$rootFwd/secrets"
    $data['SCAGENT_BIND_ADDR'] = '127.0.0.1'
    $data['SCAGENT_PORT'] = '8080'

    $header = "# ═══════════════════════════════════════════════════════════════`n" +
              "#  scAgent 配置（由 deploy\scagent.ps1 install 生成）`n" +
              "#`n" +
              "#  ⚠️ 必须保持 UTF-8 无 BOM、换行 LF —— 用记事本另存会破坏这两点，`n" +
              "#     表现为「令牌明明对却一直 401」。要改请用 VS Code，或重跑 install。`n" +
              "#`n" +
              "#  密钥不在这里：LLM Key 与访问令牌是同级 secrets\ 目录下的两个文件。`n" +
              "# ═══════════════════════════════════════════════════════════════"

    if ($DryRun) {
        Write-ScStep "[dry-run] 生成 $EnvFile"
        return $data
    }
    Write-ScEnvFile -Path $EnvFile -Data $data -Header $header
    Write-ScOk "已生成 deploy\.env（$($data.Count) 项）"
    return $data
}

# ── 动词：build（镜像分层构建）────────────────────────────────────────────────
function Invoke-ScBuild {
    <#
      必须**分两步串行**构建：
        docker compose build 会并行构建各服务，而 seurat 层的 `FROM ${RUNTIME}`
        在 runtime 镜像还不存在时，会按非限定名去 Docker Hub 找
        docker.io/<prefix>/scagent-runtime:<ver> → 必然失败（镜像源会返回 403）。
      depends_on 只约束 up 的顺序，不约束并行 build。
    #>
    param([switch]$Force, [switch]$NoCache)
    # build 属于"配置前"操作：没有 deploy\.env 也能用默认值构建
    $ctx = Get-ScContextOrDefault
    if ($ctx.ImageError) { Exit-Sc "镜像来源配置无效：$($ctx.ImageError)" 2 }
    $buildFile = 'deploy/docker-compose.build.yml'
    $rtImage = Get-ScImageName -Prefix $ctx.Image.Prefix -Version $ctx.Image.Version -Service 'runtime'

    $buildOpts = @()
    if ($NoCache) { $buildOpts += '--no-cache'; $Force = $true }

    # apt 镜像源（可选）：来自环境变量或 deploy\.env 的 APT_MIRROR
    $aptMirror = Get-ScEnvValue -Env $ctx.Env -Key 'APT_MIRROR'
    if (-not $aptMirror) { $aptMirror = "$env:APT_MIRROR".Trim() }
    if ($aptMirror) {
        $buildOpts += @('--build-arg', "APT_MIRROR=$aptMirror")
        Write-ScStep "apt 镜像源：$aptMirror"
    }

    if ($Force -or -not (Test-ScImageExists -Image $rtImage)) {
        Write-ScInfo "构建 R 运行时层（≈4 GB，首次 30–90 分钟）：$rtImage"
        try {
            Invoke-ScCompose -RepoRoot $RepoRoot -Files @($buildFile) -Arguments (@('build') + $buildOpts + @('runtime')) -DryRun:$DryRun | Out-Null
        } catch {
            Write-ScWarn "运行时层构建失败：$($_.Exception.Message)"
            Write-ScStep '常见原因与对策：'
            Write-ScStep '  · 拉基础镜像被拦 → 配 registry mirror（Docker Desktop → Settings → Docker Engine）'
            Write-ScStep '  · apt 退出码 100 / 卡在 InRelease → 换国内 apt 源后重试：'
            Write-ScStep '      $env:APT_MIRROR="https://mirrors.aliyun.com/ubuntu"; deploy\scagent.cmd build -Force'
            Write-ScStep '      （也可把 APT_MIRROR=... 写进 deploy\.env）'
            Write-ScStep '  · R 包拉取慢或超时 → 设置 PPM_CRAN / CRAN_FALLBACK / BIOC_ROOT 构建参数'
            Write-ScStep '  · 磁盘不足（该层约 10 GB）→ Docker Desktop → Settings → Resources 调整'
            Write-ScStep '  · 想直接跳过本地构建 → 把 deploy\.env 的 SCAGENT_IMAGE_SOURCE 改成 public（需镜像已发布）'
            exit 3
        }
    } else {
        Write-ScOk "运行时层已存在，跳过（要强制重建加 -Force）：$rtImage"
    }

    Write-ScInfo '构建应用层（只 COPY 代码，数秒）'
    try {
        Invoke-ScCompose -RepoRoot $RepoRoot -Files @($buildFile) -Arguments (@('build') + $buildOpts + @('seurat', 'agent')) -DryRun:$DryRun | Out-Null
    } catch {
        Write-ScWarn "应用层构建失败：$($_.Exception.Message)"
        Write-ScStep '若提示找不到 runtime 镜像，请先用 -Force 重建运行时层。'
        exit 3
    }
    Write-ScOk '镜像构建完成'
}

# ── 动词：install ─────────────────────────────────────────────────────────────
function Invoke-ScInstall {
    Write-ScBanner "scAgent 安装向导（Windows / Docker Desktop） · $ScagentBuild"

    if (-not $Root) { $Root = Get-DefaultRoot }
    if (-not $ImageSource) { $ImageSource = 'local' }
    if (-not $Version) { $Version = '1.0.0' }
    $InstallRoot = $Root

    # 立刻校验"来源 + 前缀"组合（复用 lib 里与 bash 侧同一套规则），
    # 避免装到一半才在 compose 插值时报错；给的前缀不合法时这里就停下
    try {
        $null = Resolve-ScImageSource -Source $ImageSource -Prefix $ImagePrefix -Version $Version
    } catch {
        Write-ScErr $_.Exception.Message
        Write-ScStep '提示：命令行用 -ImageSource public 指定"已发布镜像"（deploy\.env 里的键名是 SCAGENT_IMAGE_SOURCE）'
        exit 1
    }

    Write-ScInfo '[1/6] 环境体检'
    Assert-ScDocker
    Write-ScOk "docker $(Get-ScDockerInfoValue -Format '{{.ServerVersion}}')"

    $memBytes = Get-ScDockerInfoValue -Format '{{.MemTotal}}'
    $memGb = 0
    if ($memBytes -match '^\d+$') { $memGb = [int]([int64]$memBytes / 1GB) }
    if ($memGb -ge 32) { Write-ScOk "内存 ${memGb} GB（推荐配置）" }
    elseif ($memGb -ge 16) { Write-ScWarn "内存 ${memGb} GB（可用；并发建议设为 1）" }
    elseif ($memGb -gt 0) { Write-ScWarn "内存仅 ${memGb} GB（偏紧：单个 Seurat 对象约 1.6 GB）" }
    else { Write-ScWarn '无法从 Docker 读取内存信息（继续）' }

    Write-ScStep "Docker 数据根：$(Get-ScDockerInfoValue -Format '{{.DockerRootDir}}')（Docker VM 内部路径；镜像真实所在见下一行）"
    $vhdxDir = Join-Path $env:LOCALAPPDATA 'Docker\wsl\data'
    $freeImg = Get-ScFreeSpaceGB -Path $vhdxDir
    if ($freeImg -ne $null) {
        if ($freeImg -lt 20) { Write-ScWarn "镜像盘（$vhdxDir）仅剩 $freeImg GB，可能不足（镜像约 4–5 GB）" }
        else { Write-ScOk "镜像盘可用 $freeImg GB" }
    }
    if (-not $DryRun -and -not (Test-Path -LiteralPath $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    }
    $freeData = Get-ScFreeSpaceGB -Path $InstallRoot
    if ($freeData -ne $null) {
        if ($freeData -lt 50) { Write-ScWarn "数据盘（$InstallRoot）可用 $freeData GB（建议 ≥50 GB）" }
        else { Write-ScOk "数据盘可用 $freeData GB" }
    }

    $port = 8080
    if (Test-Path -LiteralPath $EnvFile) {
        $port = Get-ScEnvInt -Env (Read-ScEnvFile -Path $EnvFile) -Key 'SCAGENT_PORT' -Default 8080
    }
    if (Test-ScPortInUse -Port $port) {
        Write-ScWarn "端口 $port 已被占用 —— 若启动失败请在 deploy\.env 改 SCAGENT_PORT"
    } else {
        Write-ScOk "端口 $port 空闲"
    }

    Write-ScInfo '[2/6] 配置 deploy\.env'
    $generatedEnv = $null
    if (Test-Path -LiteralPath $EnvFile) {
        Write-ScOk '已存在，保留现有配置（要重新生成请先删除 deploy\.env）'
    } else {
        # 返回生成的映射：dry-run 时 .env 不会写盘，后续步骤要直接用它，否则读不到配置
        $generatedEnv = New-ScEnvFromTemplate -InstallRoot $InstallRoot -Src $ImageSource -Ver $Version -Prefix $ImagePrefix
    }

    Write-ScInfo '[3/6] 密钥与数据目录'
    $ctx = Get-ScContext -EnvMap $generatedEnv
    $token = Invoke-ScSecretsVerb -Ctx $ctx
    $wsRaw = Get-ScEnvValue -Env $ctx.Env -Key 'SCAGENT_WORKSPACE'
    if (-not $wsRaw) { $wsRaw = (($InstallRoot -replace '\\', '/').TrimEnd('/')) + '/workspace' }
    $ws = Resolve-ScPath -Path $wsRaw -RepoRoot $RepoRoot
    if (-not $DryRun) {
        foreach ($d in @((Join-Path $ws 'data\rawdata'), (Join-Path $ws 'state'))) {
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        }
    }
    Write-ScOk "工作目录：$ws"
    $wsWin = ($ws -replace '/', '\')
    Write-ScStep "把 10X 数据放到： $wsWin\data\rawdata\<样本名>\（barcodes / features / matrix 三个文件）"
    Write-ScStep '⚠️ 注意：是上面这个**工作目录**，不是仓库目录里的 data\ —— 两者是不同目录（最常见的放错位置）'
    # ── 参考数据集（celldex）：这里只**问**，真正的下载放到镜像就绪之后 ──
    #    原因：下载要用的 celldex 包在 seurat 镜像里，而镜像要到 [4/6] 才准备好。
    $refChoice = 'none'
    $haveMouse = $false
    $haveHuman = $false
    $bioRaw = Get-ScEnvValue -Env $ctx.Env -Key 'SCAGENT_BIODATA'
    if ($bioRaw) {
        $bio = Resolve-ScPath -Path $bioRaw -RepoRoot $RepoRoot
        $celldexDir = Join-Path $bio 'celldex'
        # 先把目录建好（当前用户所有）——否则容器启动时 Docker 会建同名目录，
        # 之后宿主机侧的 refdata 下载可能因权限写不进去。
        if (-not $DryRun -and -not (Test-Path -LiteralPath $celldexDir)) {
            New-Item -ItemType Directory -Path $celldexDir -Force | Out-Null
        }
        $haveMouse = Test-Path -LiteralPath (Join-Path $celldexDir 'MouseRNAseqData.rds')
        $haveHuman = Test-Path -LiteralPath (Join-Path $celldexDir 'HumanPrimaryCellAtlasData.rds')
        if ($haveMouse) { Write-ScOk '参考数据集：小鼠 MouseRNAseqData.rds 已就绪' }
        if ($haveHuman) { Write-ScOk '参考数据集：人类 HumanPrimaryCellAtlasData.rds 已就绪' }
        if (-not $haveMouse -and -not $haveHuman) {
            Write-ScWarn "尚未下载参考数据集（$celldexDir）—— 细胞类型注释（Step 4）需要它"
        }
        $refChoice = Resolve-ScRefdataChoice -Given $Refdata -HaveMouse $haveMouse -HaveHuman $haveHuman
    }

    $ctx = Get-ScContext -EnvMap $generatedEnv
    if ($ctx.ImageError) { Exit-Sc "部署配置无效：$($ctx.ImageError)" 2 }
    $sf = Get-ScSecretsFiles -SecretsDir $ctx.SecretsDir

    Write-ScInfo '[4/6] 准备镜像'
    Write-ScOk "来源：$($ctx.Image.Source)   前缀：$($ctx.Image.Prefix)   版本：$($ctx.Image.Version)"
    $svcSeurat = Get-ScImageName -Prefix $ctx.Image.Prefix -Version $ctx.Image.Version -Service 'seurat'
    $svcAgent  = Get-ScImageName -Prefix $ctx.Image.Prefix -Version $ctx.Image.Version -Service 'agent'

    if ($ctx.Image.PullPolicy -eq 'never') {
        $missing = @()
        foreach ($img in @($svcSeurat, $svcAgent)) {
            if (-not (Test-ScImageExists -Image $img)) { $missing += $img }
        }
        if ($missing.Count -gt 0) {
            Write-ScWarn "本地缺少镜像：$($missing -join ', ')"
            Write-ScWarn '需要本机构建，首次约 30–90 分钟（需要外网）'
            $doBuild = $true
            if (-not $Yes -and -not $DryRun) {
                $ans = Read-Host '  现在开始构建吗？[Y/n]'
                if ($ans -and $ans.Trim().ToLower().StartsWith('n')) { $doBuild = $false }
            }
            if (-not $doBuild) {
                Exit-Sc "已取消。稍后执行： deploy\scagent.cmd build    （或 deploy\scagent.cmd install）" 3
            }
            # 分两步串行：runtime 先建好并打好标签，应用层的 FROM ${RUNTIME} 才能命中本地镜像
            Invoke-ScBuild
        } else {
            Write-ScOk '本地镜像已就绪'
        }
    } else {
        Write-ScInfo '拉取镜像（唯一联网动作）'
        Invoke-ScCompose -RepoRoot $RepoRoot -Files $sf.Files -Arguments @('pull') -DryRun:$DryRun | Out-Null
    }

    # ── 参考数据集下载（此时 seurat 镜像已就绪，celldex 包可用）──
    if ($refChoice -eq 'mouse' -or $refChoice -eq 'both') { Invoke-ScRefdata -Species 'mouse' -NonFatal }
    if ($refChoice -eq 'human' -or $refChoice -eq 'both') { Invoke-ScRefdata -Species 'human' -NonFatal }
    if ($refChoice -eq 'none' -and -not ($haveMouse -or $haveHuman)) {
        Write-ScStep '未下载参考数据集 —— 细胞类型注释（Step 4）会失败；需要时随时执行：'
        Write-ScStep '    deploy\scagent.cmd refdata                  （小鼠）'
        Write-ScStep '    deploy\scagent.cmd refdata -Species human   （人类）'
    }

    Write-ScInfo '[5/6] 启动服务'
    Invoke-ScCompose -RepoRoot $RepoRoot -Files $sf.Files -Arguments @('up', '-d', '--force-recreate', '--pull', $ctx.Image.PullPolicy) -DryRun:$DryRun | Out-Null

    if (-not $DryRun) {
        Write-ScInfo '[6/6] 等待健康检查（seurat 冷启动约 120 秒）'
        if (Wait-ScHealthy -RepoRoot $RepoRoot -Files $sf.Files -TimeoutSec 360) {
            Write-ScOk '全部容器健康'
        } else {
            Write-ScWarn '等待超时 —— 请查看日志： deploy\scagent.cmd logs seurat'
        }
    }

    $url = "http://127.0.0.1:$port"
    Write-Host ''
    Write-Host ('─' * 60) -ForegroundColor DarkCyan
    if ($DryRun) { Write-ScOk 'dry-run 结束：以上命令都**没有真正执行**' } else { Write-ScOk '部署完成' }
    Write-Host "     访问地址： $url"
    if ($token) {
        Write-Host "     访问令牌： $token"
        try { Set-Clipboard -Value $token | Out-Null; Write-Host '     （令牌已复制到剪贴板）' } catch { }
    }
    Write-Host "     下一步： 把 10X 数据放入 $(($ws -replace '/', '\'))\data\rawdata\<样本名>\"
    Write-Host '     局域网访问： deploy\.env 里把 SCAGENT_BIND_ADDR 改成 0.0.0.0，'
    Write-Host '                 并在 Windows 防火墙允许 Docker Desktop 的入站（首次启动会弹窗）'
    Write-Host ('─' * 60) -ForegroundColor DarkCyan
    Write-Host ''
    if (-not $NoBrowser -and -not $DryRun) { Open-ScBrowser -Url $url | Out-Null }
}

# ── 动词：up / down / restart / status / logs ─────────────────────────────────
function Invoke-ScUp {
    $ctx = Get-ScContext
    Assert-ScConfigured -Ctx $ctx
    $sf = Get-ScSecretsFiles -SecretsDir $ctx.SecretsDir
    Write-ScInfo "镜像来源：$($ctx.Image.Source)（前缀 $($ctx.Image.Prefix)，拉取策略 $($ctx.Image.PullPolicy)）"

    foreach ($svc in @('runtime', 'seurat', 'agent')) {
        $img = Get-ScImageName -Prefix $ctx.Image.Prefix -Version $ctx.Image.Version -Service $svc
        if (Test-ScImageExists -Image $img) {
            if (-not $DryRun) {
                $prev = "$($ctx.Image.Prefix)/scagent-$svc`:prev"
                $null = & docker tag $img $prev 2>$null
                if ($LASTEXITCODE -eq 0) { Write-ScOk "$svc -> :prev" }
                else { Write-ScWarn "打 :prev 标签失败（不影响启动）：$img" }
            }
        } else {
            Write-ScWarn "$svc 镜像不在本地，跳过 :prev"
        }
    }

    if ($ctx.Image.PullPolicy -ne 'never') {
        Write-ScInfo '拉取镜像'
        Invoke-ScCompose -RepoRoot $RepoRoot -Files $sf.Files -Arguments @('pull') -DryRun:$DryRun | Out-Null
    }
    Write-ScInfo '启动服务'
    Invoke-ScCompose -RepoRoot $RepoRoot -Files $sf.Files -Arguments @('up', '-d', '--force-recreate', '--pull', $ctx.Image.PullPolicy) -DryRun:$DryRun | Out-Null
    if (-not $DryRun) {
        if (Wait-ScHealthy -RepoRoot $RepoRoot -Files $sf.Files -TimeoutSec 360) { Write-ScOk '全部容器健康' }
        else { Write-ScWarn '等待超时，请查看： deploy\scagent.cmd logs' }
        Write-Host ''
        Write-Host "  访问： $(Get-ScUrl -Ctx $ctx)"
    }
}

function Invoke-ScDown {
    $ctx = Get-ScContext
    Assert-ScConfigured -Ctx $ctx
    $sf = Get-ScSecretsFiles -SecretsDir $ctx.SecretsDir
    Invoke-ScCompose -RepoRoot $RepoRoot -Files $sf.Files -Arguments @('down') -DryRun:$DryRun | Out-Null
    Write-ScOk '服务已停止（数据与密钥未删除）'
}

function Invoke-ScRestart {
    $ctx = Get-ScContext
    Assert-ScConfigured -Ctx $ctx
    $sf = Get-ScSecretsFiles -SecretsDir $ctx.SecretsDir
    Invoke-ScCompose -RepoRoot $RepoRoot -Files $sf.Files -Arguments @('restart') -DryRun:$DryRun | Out-Null
    Write-ScOk '已重启'
}

function Invoke-ScStatus {
    $ctx = Get-ScContext
    if ($ctx.Env.Count -eq 0) {
        Write-ScWarn '尚未配置（没有 deploy\.env）—— 请先运行 deploy\install.cmd'
        exit 2
    }
    if ($ctx.Image) {
        Write-ScOk "镜像来源：$($ctx.Image.Source) -> $($ctx.Image.Prefix)（pull=$($ctx.Image.PullPolicy)）"
    } elseif ($ctx.ImageError) {
        Write-ScErr "配置无效：$($ctx.ImageError)"
    }
    $sf = Get-ScSecretsFiles -SecretsDir $ctx.SecretsDir
    $null = Invoke-ScCompose -RepoRoot $RepoRoot -Files $sf.Files -Arguments @('ps') -AllowFail
    $token = Get-ScToken -Env $ctx.Env -SecretsDir $ctx.SecretsDir
    $h = Get-ScAgentHealth -Url (Get-ScUrl -Ctx $ctx) -Token $token
    if ($h) {
        Write-ScOk "agent 健康：llm=$($h.llm.provider)/$($h.llm.model) ready=$($h.llm.ready) sessions=$($h.sessions)"
    } else {
        Write-ScWarn "agent 无响应（$(Get-ScUrl -Ctx $ctx)/v1/health）"
    }
}

function Invoke-ScLogs {
    param([string]$ServiceName = 'agent')
    $ctx = Get-ScContext
    $sf = Get-ScSecretsFiles -SecretsDir $ctx.SecretsDir
    $null = Invoke-ScCompose -RepoRoot $RepoRoot -Files $sf.Files -Arguments @('logs', '--tail', '200', $ServiceName) -DryRun:$DryRun
}

# ── 动词：verify ──────────────────────────────────────────────────────────────
function Invoke-ScVerify {
    $ctx = Get-ScContext
    $script:pass = 0; $script:warn = 0; $script:fail = 0

    function Item {
        param([string]$Name, [string]$Status, [string]$Detail)
        $pad = $Name.PadRight(30)
        if ($Status -eq 'ok') {
            Write-Host ("  $pad [OK] $Detail") -ForegroundColor Green; $script:pass++
        } elseif ($Status -eq 'warn') {
            Write-Host ("  $pad [!]  $Detail") -ForegroundColor Yellow; $script:warn++
        } else {
            Write-Host ("  $pad [X]  $Detail") -ForegroundColor Red; $script:fail++
        }
    }

    Write-ScBanner 'scAgent 部署自检（Windows）'

    # 先判断"是否部署过"：有容器，或镜像已构建/已拉取。
    # 未部署时不应把"容器 0 个 / 健康无响应"报成阻塞 —— 那是还没装，不是故障
    $deployed = $false
    $sf = $null
    $vSeurat = ''; $vAgent = ''
    if ($ctx.Image) {
        $sf = Get-ScSecretsFiles -SecretsDir $ctx.SecretsDir
        $vSeurat = Get-ScImageName -Prefix $ctx.Image.Prefix -Version $ctx.Image.Version -Service 'seurat'
        $vAgent = Get-ScImageName -Prefix $ctx.Image.Prefix -Version $ctx.Image.Version -Service 'agent'
        $runningNow = @((Get-ScComposeOutput -RepoRoot $RepoRoot -Files $sf.Files -Arguments @('ps', '-q')) |
                        Where-Object { $_ -and "$_".Trim() -ne '' }).Count
        if ($runningNow -gt 0) { $deployed = $true }
        elseif ((Test-ScImageExists -Image $vSeurat) -or (Test-ScImageExists -Image $vAgent)) { $deployed = $true }
    }
    if (-not $deployed) { Write-ScWarn '尚未部署过（没有容器，也没找到本地镜像）—— 服务相关检查以"未部署"处理' }

    if ($ctx.Env.Count -gt 0) { Item '配置文件 deploy\.env' 'ok' '已加载' }
    else { Item '配置文件 deploy\.env' 'fail' '缺失（先运行 deploy\install.cmd）' }
    Item '密钥权限模型' 'ok' 'Windows 用 icacls（不做 POSIX 权限校验）'

    # 密钥可读性：容器以 uid 1000 读取；当前用户都读不到就一定起不来
    $keyFile = Join-Path $ctx.SecretsDir 'deepseek_api_key'
    $tokFile = Join-Path $ctx.SecretsDir 'scagent_token'
    $missing = @(); $unreadable = @()
    foreach ($f in @($keyFile, $tokFile)) {
        if (-not (Test-Path -LiteralPath $f)) { $missing += (Split-Path -Leaf $f) }
        elseif (-not (Test-ScSecretReadable -Path $f)) { $unreadable += (Split-Path -Leaf $f) }
    }
    if ($unreadable.Count -gt 0) {
        Item '密钥文件可读性' 'fail' "读不到：$($unreadable -join ', ')（ACL 被锁）"
        Write-ScAclRepairHint -Dir $ctx.SecretsDir
    } elseif ($missing.Count -gt 0) {
        Item '密钥文件可读性' 'warn' "缺少：$($missing -join ', ')（运行 install 会自动生成）"
    } else {
        Item '密钥文件可读性' 'ok' '两个文件都可读'
    }

    if ($ctx.Image) { Item '镜像来源配置' 'ok' "$($ctx.Image.Source) -> $($ctx.Image.Prefix)（pull=$($ctx.Image.PullPolicy)）" }
    else { Item '镜像来源配置' 'fail' "无效：$($ctx.ImageError)" }

    # V2：compose 的 :? 守卫必须生效 —— 用临时空 env 文件 + 清空相关变量，
    #     并且**校验错误信息里确实提到必填变量**（否则可能因为别的原因失败而假通过）
    $emptyEnv = Join-Path $env:TEMP ("scagent-empty-" + [guid]::NewGuid().ToString('N') + ".env")
    [System.IO.File]::WriteAllText($emptyEnv, '', (New-Object System.Text.UTF8Encoding($false)))
    $saved = @{}
    foreach ($k in @('SCAGENT_IMAGE_PREFIX', 'SCAGENT_VERSION', 'SCAGENT_WORKSPACE', 'SCAGENT_BIODATA')) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $null)
    }
    Push-Location -LiteralPath $RepoRoot
    try {
        $v2out = (& docker compose --env-file $emptyEnv -f deploy/docker-compose.yml config 2>&1 | Out-String)
        $v2 = $LASTEXITCODE
    } finally { Pop-Location }
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    Remove-Item -LiteralPath $emptyEnv -Force -ErrorAction SilentlyContinue
    if ($v2 -ne 0 -and $v2out -match 'SCAGENT_IMAGE_PREFIX|SCAGENT_VERSION|SCAGENT_WORKSPACE|SCAGENT_BIODATA|required variable|必须设置') {
        Item 'V2 compose 变量必填' 'ok' '缺变量时报错且提示了变量名'
    } elseif ($v2 -ne 0) {
        Item 'V2 compose 变量必填' 'warn' '报错了，但原因不是必填变量（请人工确认）'
    } else {
        Item 'V2 compose 变量必填' 'fail' '缺变量时 compose 竟然通过了'
    }

    if ($ctx.Image) {
        $psOut = Get-ScComposeOutput -RepoRoot $RepoRoot -Files $sf.Files -Arguments @('ps', '-q')
        $running = @($psOut | Where-Object { $_ -and "$_".Trim() -ne '' }).Count
        if ($running -ge 2) { Item '运行中的容器' 'ok' "$running 个" }
        elseif (-not $deployed) { Item '运行中的容器' 'warn' '未部署（先运行 deploy\install.cmd）' }
        else { Item '运行中的容器' 'fail' "只有 $running 个（期望 2）—— 看 deploy\scagent.cmd logs" }

        $img = $vSeurat
        if (Test-ScImageExists -Image $img) {
            # 只扫 /workspace（镜像自带的 R 包里有 3000+ 个 .rds，扫 / 必然误报）
            $found = & docker run --rm --entrypoint sh $img -c 'find /workspace \( -name "*.rds" -o -name "*.RDS" \) 2>/dev/null | head -3' 2>$null
            if ("$found".Trim()) { Item 'V3 镜像内无 .rds' 'fail' "发现：$found" }
            else { Item 'V3 镜像内无 .rds' 'ok' '干净' }
        } else {
            Item 'V3 镜像内无 .rds' 'warn' '跳过（镜像还没构建/拉取）'
        }

        # seurat /api/ping：注意 plumber 把标量序列化成数组（"status":["ok"]）
        if ($running -ge 1) {
            $pingRaw = (Get-ScComposeOutput -RepoRoot $RepoRoot -Files $sf.Files -Arguments @(
                            'exec', '-T', 'seurat', 'Rscript', '-e',
                            "cat(tryCatch(jsonlite::toJSON(jsonlite::fromJSON('http://127.0.0.1:9000/api/ping')), error=function(e) 'FAIL'))") -join '')
            if ($pingRaw -match '"status"\s*:\s*\[?"ok"') {
                Item 'seurat /api/ping' 'ok' $(if ($pingRaw -match '"r_version"\s*:\s*\[?"([^"]+)"') { "R $($Matches[1])" } else { 'ok' })
            } elseif ($running -ge 1) {
                Item 'seurat /api/ping' 'fail' ("无响应：" + $pingRaw.Substring(0, [Math]::Min(80, $pingRaw.Length)))
            }
        }
    }

    $token = Get-ScToken -Env $ctx.Env -SecretsDir $ctx.SecretsDir
    $base = Get-ScUrl -Ctx $ctx
    $c1 = Get-ScHttpStatus -Url "$base/v1/health" -Token $token
    if ($c1 -eq 200) { Item 'agent /v1/health（带令牌）' 'ok' '200' }
    elseif (-not $deployed) { Item 'agent /v1/health（带令牌）' 'warn' '未部署（服务未启动）' }
    else { Item 'agent /v1/health（带令牌）' 'fail' "返回 $c1" }
    $c2 = Get-ScHttpStatus -Url "$base/v1/health"
    if ($c2 -eq 401) { Item '无令牌必须 401' 'ok' '401' }
    elseif (-not $deployed) { Item '无令牌必须 401' 'warn' '未部署（服务未启动）' }
    else { Item '无令牌必须 401' 'fail' "返回 $c2" }
    $c3 = Get-ScHttpStatus -Url "$base/"
    if ($c3 -eq 200) { Item '内置网页界面' 'ok' '可访问' }
    elseif (-not $deployed) { Item '内置网页界面' 'warn' '未部署（服务未启动）' }
    else { Item '内置网页界面' 'warn' "返回 $c3" }

    $bioRaw = Get-ScEnvValue -Env $ctx.Env -Key 'SCAGENT_BIODATA'
    if ($bioRaw) {
        $bio = Resolve-ScPath -Path $bioRaw -RepoRoot $RepoRoot
        if (Test-Path -LiteralPath $bio) {
            $n = @(Get-ChildItem -LiteralPath $bio -Filter '*.rds' -Recurse -ErrorAction SilentlyContinue).Count
            if ($n -gt 0) { Item '参考数据（celldex）' 'ok' "$n 个 .rds" }
            else {
                Item '参考数据（celldex）' 'warn' '目录存在但没有 .rds'
                Write-ScStep '一次性获取（需要外网）： deploy\scagent.cmd refdata'
            }
        } else {
            Item '参考数据（celldex）' 'warn' "不存在：$bio（细胞注释会失败）"
            Write-ScStep '一次性获取（需要外网）： deploy\scagent.cmd refdata'
        }
    }

    $wsRaw = Get-ScEnvValue -Env $ctx.Env -Key 'SCAGENT_WORKSPACE'
    if ($wsRaw) {
        $ws = Resolve-ScPath -Path $wsRaw -RepoRoot $RepoRoot
        $raw = Join-Path $ws 'data\rawdata'
        $n = 0
        if (Test-Path -LiteralPath $raw) { $n = @(Get-ChildItem -LiteralPath $raw -Directory -ErrorAction SilentlyContinue).Count }
        if ($n -gt 0) { Item '10X 原始数据' 'ok' "$n 个样本目录" }
        else { Item '10X 原始数据' 'warn' "暂无样本（放入 $raw）" }
    }

    Write-Host ''
    Write-Host ('─' * 60) -ForegroundColor DarkCyan
    Write-Host "  通过 $script:pass   警告 $script:warn   失败 $script:fail"
    if (-not $deployed) {
        Write-Host '  结论：尚未部署 —— 先运行 deploy\install.cmd（或 deploy\scagent.cmd up）'
        Write-Host '        上面标 [!] 的"未部署"项不是故障，装完再跑一次 verify 即可复检。'
        exit 1
    } elseif ($script:fail -eq 0) {
        Write-Host '  结论：可以正常使用'
        exit 0
    } else {
        Write-Host '  结论：存在阻塞问题 —— 请按上面提示逐项处理'
        Write-Host '  排查提示： deploy\scagent.cmd logs seurat'
        exit 1
    }
}

# ── 动词：doctor（部署体检）───────────────────────────────────────────────────
function Invoke-ScDoctor {
    <#
      与 verify 的分工：
        doctor —— 环境与配置**能不能跑起来**（Docker/资源/端口/镜像/密钥/数据/网络）
        verify —— 服务**本身是否可用**（容器健康、端点、令牌、数据目录）
      本命令**只读**：不改配置、不启停容器。
    #>
    param([switch]$Quick)

    $ctx = Get-ScContext
    $script:pass = 0; $script:warn = 0; $script:fail = 0
    $script:envBad = 0; $script:cfgBad = 0; $script:svcBad = 0
    $running = 0

    function DItem {
        param([string]$Name, [string]$Status, [string]$Detail)
        $pad = $Name.PadRight(30)
        if ($Status -eq 'ok')        { Write-Host "  $pad [OK] $Detail" -ForegroundColor Green;  $script:pass++ }
        elseif ($Status -eq 'warn')  { Write-Host "  $pad [!]  $Detail" -ForegroundColor Yellow; $script:warn++ }
        else                         { Write-Host "  $pad [X]  $Detail" -ForegroundColor Red;    $script:fail++ }
    }
    function DGroup { param([string]$T) Write-Host ''; Write-Host "── $T ──" -ForegroundColor Cyan }
    function DHint  { param([string]$T) Write-Host "      $T" -ForegroundColor DarkGray }

    Write-ScBanner "scAgent 部署体检（doctor） · $ScagentBuild"

    # ── 1. 环境与资源 ────────────────────────────────────────────────────────
    DGroup '1. 环境与资源'
    $dockerOk = $false
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $ver = Get-ScDockerInfoValue -Format '{{.ServerVersion}}'
        if ($ver) { DItem 'Docker 守护进程' 'ok' "可访问（Server $ver）"; $dockerOk = $true }
        else {
            DItem 'Docker 守护进程' 'fail' '无法连接'
            DHint '确认 Docker Desktop 已启动（任务栏鲸鱼图标为绿色）'
            $script:envBad = 1
        }
    } else {
        DItem 'docker 命令' 'fail' '未安装'
        DHint 'Windows： https://www.docker.com/products/docker-desktop/'
        $script:envBad = 1
    }

    if ($dockerOk) {
        $memBytes = Get-ScDockerInfoValue -Format '{{.MemTotal}}'
        if ($memBytes -match '^\d+$') {
            $memGb = [int]([int64]$memBytes / 1GB)
            if ($memGb -ge 32) { DItem '可用内存' 'ok' "$memGb GB（推荐）" }
            elseif ($memGb -ge 16) { DItem '可用内存' 'warn' "$memGb GB（可用；并发建议设为 1）" }
            else { DItem '可用内存' 'warn' "$memGb GB（单个 Seurat 对象约 1.6 GB）" }
        }
        $cores = Get-ScDockerInfoValue -Format '{{.NCPU}}'
        if ($cores -match '^\d+$') {
            if ([int]$cores -ge 8) { DItem '可用 CPU' 'ok' "$cores 核" } else { DItem '可用 CPU' 'warn' "$cores 核（建议 ≥8）" }
        }
        $imgFree = Get-ScFreeSpaceGB -Path (Join-Path $env:LOCALAPPDATA 'Docker\wsl\data')
        if ($null -ne $imgFree) {
            if ($imgFree -ge 20) { DItem '镜像盘可用' 'ok' "$imgFree GB" }
            else { DItem '镜像盘可用' 'warn' "$imgFree GB（镜像约 4–10 GB）" }
        }
    }

    $port = $ctx.Port
    if (Test-ScPortInUse -Port $port) {
        DItem "端口 $port" 'warn' '已被占用（若服务正在运行属正常；否则改 SCAGENT_PORT）'
    } else {
        DItem "端口 $port" 'ok' '空闲'
    }

    # ── 2. 配置 ──────────────────────────────────────────────────────────────
    DGroup '2. 配置（deploy\.env）'
    if ($ctx.Env.Count -eq 0) {
        DItem 'deploy\.env' 'fail' '缺失'
        DHint '运行： deploy\install.cmd（会自动生成）'
        $script:cfgBad = 1
    } else {
        DItem 'deploy\.env' 'ok' "已加载（$($ctx.Env.Count) 项）"
        if ($ctx.Image) {
            DItem '镜像来源' 'ok' "$($ctx.Image.Source) -> $($ctx.Image.Prefix):$($ctx.Image.Version)（pull=$($ctx.Image.PullPolicy)）"
        } else {
            DItem '镜像来源' 'fail' "无效：$($ctx.ImageError)"
            $script:cfgBad = 1
        }
        foreach ($k in @('SCAGENT_WORKSPACE', 'SCAGENT_BIODATA')) {
            if (Get-ScEnvValue -Env $ctx.Env -Key $k) { DItem $k 'ok' '已设置' }
            else { DItem $k 'fail' '未设置'; $script:cfgBad = 1 }
        }
    }

    # ── 3. 镜像 ──────────────────────────────────────────────────────────────
    DGroup '3. 镜像'
    if ($dockerOk -and $ctx.Image) {
        $have = 0
        foreach ($svc in @('seurat', 'agent')) {
            $img = Get-ScImageName -Prefix $ctx.Image.Prefix -Version $ctx.Image.Version -Service $svc
            if (Test-ScImageExists -Image $img) { DItem "镜像 scagent-$svc" 'ok' $img; $have++ }
            else { DItem "镜像 scagent-$svc" 'warn' "本地没有 $img" }
        }
        $prev = "$($ctx.Image.Prefix)/scagent-seurat:prev"
        if (Test-ScImageExists -Image $prev) { DItem '回滚标签 :prev' 'ok' '存在' }
        else { DItem '回滚标签 :prev' 'warn' '尚无（首次部署正常；每次 up 会自动保留）' }
        if ($have -eq 0 -and $ctx.Image.PullPolicy -eq 'never') {
            DItem '本地镜像' 'fail' 'local 模式下没有任何本地镜像'
            DHint '先构建： deploy\scagent.cmd build'
        }
    } else {
        DItem '镜像检查' 'warn' '跳过（Docker 不可用或配置无效）'
    }

    # ── 4. 密钥 ──────────────────────────────────────────────────────────────
    DGroup '4. 密钥'
    $keyFile = Join-Path $ctx.SecretsDir 'deepseek_api_key'
    $tokFile = Join-Path $ctx.SecretsDir 'scagent_token'
    if (Test-Path -LiteralPath $ctx.SecretsDir) { DItem '密钥目录' 'ok' $ctx.SecretsDir }
    else { DItem '密钥目录' 'warn' "不存在：$($ctx.SecretsDir)（install 会创建）" }
    foreach ($f in @($keyFile, $tokFile)) {
        $leaf = Split-Path -Leaf $f
        if (-not (Test-Path -LiteralPath $f)) { DItem "密钥文件 $leaf" 'warn' '缺失（install/secrets 会生成）' }
        elseif (-not (Test-ScSecretReadable -Path $f)) {
            DItem "密钥文件 $leaf" 'fail' '存在但不可读（ACL 问题）'
            $script:cfgBad = 1
            Write-ScAclRepairHint -Dir $ctx.SecretsDir
        } else { DItem "密钥文件 $leaf" 'ok' "可读（$((Get-Item -LiteralPath $f).Length) 字节）" }
    }
    if ($ctx.SecretsDir -and $ctx.SecretsDir.StartsWith(($RepoRoot -replace '\\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
        DItem '密钥是否在仓库内' 'warn' '在仓库目录内（建议放到仓库之外）'
    } else {
        DItem '密钥是否在仓库内' 'ok' '在仓库之外'
    }

    # ── 5. 数据 ──────────────────────────────────────────────────────────────
    DGroup '5. 数据目录'
    $wsRaw = Get-ScEnvValue -Env $ctx.Env -Key 'SCAGENT_WORKSPACE'
    $ws = ''
    if ($wsRaw) { $ws = Resolve-ScPath -Path $wsRaw -RepoRoot $RepoRoot }
    if (-not $ws) { DItem 'SCAGENT_WORKSPACE' 'warn' '未设置 —— 跳过数据检查' }
    else {
        if (Test-Path -LiteralPath $ws) { DItem '工作目录' 'ok' $ws } else { DItem '工作目录' 'warn' "不存在：$ws（up/install 会创建）" }
        $rawDir = Join-Path $ws 'data\rawdata'
        $n = 0
        if (Test-Path -LiteralPath $rawDir) { $n = @(Get-ChildItem -LiteralPath $rawDir -Directory -ErrorAction SilentlyContinue).Count }
        if ($n -gt 0) { DItem '10X 原始数据' 'ok' "$n 个样本目录" }
        else {
            DItem '10X 原始数据' 'warn' '没有样本 —— 质控及后续步骤都无法执行'
            DHint "把样本放到 $rawDir\<样本名>\（含 barcodes/features/matrix）"
            DHint '⚠️ 是工作目录，不是仓库目录里的 data\ —— 最常见的放错位置'
        }
        $bioRaw = Get-ScEnvValue -Env $ctx.Env -Key 'SCAGENT_BIODATA'
        if ($bioRaw) {
            $bio = Resolve-ScPath -Path $bioRaw -RepoRoot $RepoRoot
            if (Test-Path -LiteralPath $bio) {
                $bn = @(Get-ChildItem -LiteralPath $bio -Filter '*.rds' -Recurse -ErrorAction SilentlyContinue).Count
                if ($bn -gt 0) { DItem '参考数据（celldex）' 'ok' "$bn 个 .rds" }
                else {
                    DItem '参考数据（celldex）' 'warn' '目录为空 —— 细胞类型注释（Step 4）会失败'
                    DHint '一次性获取（需要外网）： deploy\scagent.cmd refdata'
                }
            } else {
                DItem '参考数据（celldex）' 'warn' "不存在：$bio —— Step 4 会失败"
                DHint '一次性获取（需要外网）： deploy\scagent.cmd refdata'
            }
        }
        DItem '数据目录属主' 'ok' 'Windows 无 POSIX 属主语义（跳过）'
    }

    # ── 6. 服务 ──────────────────────────────────────────────────────────────
    DGroup '6. 服务'
    if ($dockerOk -and $ctx.Image) {
        $sf = Get-ScSecretsFiles -SecretsDir $ctx.SecretsDir
        $ids = Get-ScComposeOutput -RepoRoot $RepoRoot -Files $sf.Files -Arguments @('ps', '-q')
        $running = @($ids | Where-Object { $_ -and "$_".Trim() -ne '' }).Count
        if ($running -ge 2) { DItem '运行中的容器' 'ok' "$running 个" }
        else { DItem '运行中的容器' 'warn' "$running 个（尚未启动？执行 deploy\scagent.cmd up）" }

        if ($running -ge 1) {
            $json = (Get-ScComposeOutput -RepoRoot $RepoRoot -Files $sf.Files -Arguments @('ps', '--format', 'json')) -join "`n"
            $unhealthy = ([regex]::Matches($json, '"Health"\s*:\s*"(?!healthy)[A-Za-z]+"')).Count
            if ($unhealthy -eq 0) { DItem '容器健康' 'ok' '全部 healthy' }
            else { DItem '容器健康' 'fail' "$unhealthy 个 unhealthy"; $script:svcBad = 1; DHint '看日志： deploy\scagent.cmd logs seurat' }

            # 一致性：运行中的容器挂的是哪个宿主目录（Windows 与 WSL 共用一个 daemon 时尤其重要）
            $sid = @($ids | Where-Object { $_ -and "$_".Trim() -ne '' })[0]
            if ($sid) {
                $mnt = (& docker inspect $sid --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' 2>$null)
                $mntNorm = ("$mnt" -replace '\\', '/').Trim()
                $wantNorm = ("$ws/data" -replace '\\', '/').Trim()
                if (-not $mntNorm) { DItem '挂载一致性' 'warn' '读不到容器的 /data 挂载源' }
                elseif ($mntNorm -eq $wantNorm) { DItem '挂载一致性' 'ok' '容器的 /data 就是 .env 里的工作目录' }
                else {
                    DItem '挂载一致性' 'fail' "容器挂的是 $mntNorm，而 .env 写的是 $wantNorm —— 不是同一套部署"
                    $script:cfgBad = 1
                    DHint 'Windows 与 WSL 共用 Docker 引擎，容易混；用对应的一套脚本重启即可'
                }
            }
        }

        $token = Get-ScToken -Env $ctx.Env -SecretsDir $ctx.SecretsDir
        $base = Get-ScUrl -Ctx $ctx
        $code = Get-ScHttpStatus -Url "$base/v1/health" -Token $token
        if ($code -eq 200) { DItem 'agent 端点 /v1/health' 'ok' '200（令牌有效）' }
        elseif ($code -eq 401) {
            DItem 'agent 端点 /v1/health' 'fail' '401 —— 令牌不对'
            DHint "检查 $tokFile 与 deploy\.env 是否一致"
            $script:svcBad = 1
        } elseif ($running -ge 2) { DItem 'agent 端点 /v1/health' 'fail' '无响应（容器在跑但端点不通）'; $script:svcBad = 1 }
        else { DItem 'agent 端点 /v1/health' 'warn' '服务未启动' }

        $wc = Get-ScHttpStatus -Url "$base/"
        if ($wc -eq 200) { DItem '网页界面' 'ok' "可访问（$base）" }
        else { DItem '网页界面' 'warn' "返回 $wc" }
    } else {
        DItem '服务检查' 'warn' '跳过（Docker 不可用或配置无效）'
    }

    # ── 7. 网络与 LLM ────────────────────────────────────────────────────────
    DGroup '7. 网络与 LLM'
    if ($Quick) { DItem '网络检查' 'warn' '已跳过（-Quick）' }
    else {
        $llmHost = Get-ScEnvValue -Env $ctx.Env -Key 'SCAGENT_LLM_BASE_URL' -Default 'https://api.deepseek.com'
        $lc = Get-ScHttpStatus -Url "$llmHost/v1/models" -TimeoutSec 10
        if ($lc -eq 200 -or $lc -eq 401 -or $lc -eq 403) { DItem 'LLM 端点可达性' 'ok' "可达（$llmHost → $lc）" }
        elseif ($lc -eq 0) {
            DItem 'LLM 端点可达性' 'warn' "不可达（$llmHost）—— 防火墙/代理/DNS 或离线"
            DHint '离线可用：把 SCAGENT_LLM_PROVIDER 设为 ollama 或 none'
        } else { DItem 'LLM 端点可达性' 'warn' "返回 $lc（$llmHost）" }

        if ($running -ge 1) {
            $null = & docker exec scagent-agent-1 python -c "import socket;socket.create_connection(('api.deepseek.com',443),5)" 2>$null
            if ($LASTEXITCODE -eq 0) { DItem '容器出网（egress）' 'ok' 'agent 容器可出网' }
            else { DItem '容器出网（egress）' 'warn' 'agent 容器出网失败 —— LLM 调用会失败' }
        } else { DItem '容器出网（egress）' 'warn' '跳过（服务未运行）' }
    }

    Write-Host ''
    Write-Host ('─' * 60) -ForegroundColor DarkCyan
    Write-Host "  通过 $script:pass   警告 $script:warn   失败 $script:fail"
    if ($script:fail -eq 0) {
        Write-Host '  结论：体检通过 —— 可以正常使用'
        Write-Host '  接着建议： deploy\scagent.cmd verify（服务可用性自检）'
        exit 0
    } elseif ($script:envBad -eq 1) {
        Write-Host '  结论：环境不满足 —— 先按上面提示处理 Docker/资源问题'
        exit 1
    } elseif ($script:cfgBad -eq 1) {
        Write-Host '  结论：配置错误 —— 按上面提示修 deploy\.env 或密钥'
        exit 2
    } else {
        Write-Host '  结论：服务/运行期问题 —— 按上面提示逐项处理'
        Write-Host '  排查提示： deploy\scagent.cmd logs seurat'
        exit 3
    }
}

# ── 动词：backup（与 deploy/backup.sh 行为对齐）───────────────────────────────
function Invoke-ScBackup {
    param(
        [switch]$WithRds,
        [switch]$IncludeSecrets,
        [string]$OutDir = './backups'
    )
    $ctx = Get-ScContext
    Assert-ScConfigured -Ctx $ctx
    $ws = Resolve-ScPath -Path (Get-ScEnvValue -Env $ctx.Env -Key 'SCAGENT_WORKSPACE') -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $ws)) { Exit-Sc "工作目录不存在：$ws" 2 }

    if ([System.IO.Path]::IsPathRooted($OutDir)) { $outFull = $OutDir }
    else { $outFull = Join-Path $RepoRoot ($OutDir -replace '^\./', '') }
    if (-not $DryRun) { New-Item -ItemType Directory -Path $outFull -Force | Out-Null }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ('scagent-backup-' + [guid]::NewGuid().ToString('N'))
    Write-ScInfo "备份到 $outFull"
    Write-ScStep "工作目录: $ws"
    Write-ScStep ("包含 .rds: " + $(if ($WithRds) { '是' } else { '否' }))
    if ($DryRun) {
        Write-ScStep "[dry-run] 复制 state/ 与 data/ → $stage"
        Write-ScStep "[dry-run] 打包并回验，输出到 $outFull\scagent-backup-$stamp.tar.gz"
        return
    }
    New-Item -ItemType Directory -Path (Join-Path $stage 'deploy') -Force | Out-Null

    # 1) .env 脱敏（只清密钥值，保留键名）—— 与 backup.sh 同一张正则清单
    $envText = [System.IO.File]::ReadAllText($EnvFile)
    $envText = [regex]::Replace($envText, '(?m)^([ \t]*(?:DEEPSEEK_API_KEY|SCAGENT_LLM_API_KEY|SCAGENT_LLM_API_KEY_FILE|SCAGENT_TOKEN|SCAGENT_TOKEN_FILE)[ \t]*=).*$', '$1')
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $stage 'deploy\.env'), $envText, $utf8NoBom)
    Write-ScOk 'deploy\.env 已脱敏（密钥值清空）'

    # 2) state/（会话检查点）
    $stateDir = Join-Path $ws 'state'
    if (Test-Path -LiteralPath $stateDir) {
        New-Item -ItemType Directory -Path (Join-Path $stage 'workspace') -Force | Out-Null
        Copy-Item -LiteralPath $stateDir -Destination (Join-Path $stage 'workspace') -Recurse -Force
        Write-ScOk '已收集 state/（会话检查点）'
    }

    # 3) data/（默认排除 .rds —— 用 robocopy，顺带处理长路径与大量小文件）
    $dataDir = Join-Path $ws 'data'
    if (Test-Path -LiteralPath $dataDir) {
        $dstData = Join-Path $stage 'workspace\data'
        New-Item -ItemType Directory -Path $dstData -Force | Out-Null
        $xf = @('*.tmp', '*.lock', '~$*')
        if (-not $WithRds) { $xf += @('*.rds', '*.RDS') }
        $null = & robocopy $dataDir $dstData /E /XF @xf /NFL /NDL /NJH /NJS /NP
        if ($LASTEXITCODE -ge 8) { Write-ScWarn "robocopy 返回 $LASTEXITCODE（可能有个别文件未能复制）" }
        Write-ScOk ("已收集 data/（" + $(if ($WithRds) { '含 .rds' } else { '不含 .rds' }) + "）")
    }

    # 4) 密钥（默认排除）
    if ($IncludeSecrets) {
        if (Test-Path -LiteralPath $ctx.SecretsDir) {
            New-Item -ItemType Directory -Path (Join-Path $stage 'secrets') -Force | Out-Null
            Copy-Item -Path (Join-Path $ctx.SecretsDir '*') -Destination (Join-Path $stage 'secrets') -Recurse -Force -ErrorAction SilentlyContinue
            Write-ScWarn "已按 -IncludeSecrets 打包 $($ctx.SecretsDir) —— 请确保备份介质已加密"
        } else {
            Write-ScWarn "指定了 -IncludeSecrets，但 $($ctx.SecretsDir) 不存在"
        }
    } else {
        Write-ScWarn "已排除密钥目录 $($ctx.SecretsDir)（如需一并备份，加 -IncludeSecrets）"
        Remove-Item -LiteralPath (Join-Path $stage 'deploy\secrets'), (Join-Path $stage 'secrets') -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 5) 打包（优先 tar.gz；没有 tar 就退回 zip，并明确告知）
    $tarCmd = Get-Command tar -ErrorAction SilentlyContinue
    $archive = ''
    if ($tarCmd) {
        $archive = Join-Path $outFull "scagent-backup-$stamp.tar.gz"
        Push-Location $outFull
        try { & tar -czf "scagent-backup-$stamp.tar.gz" -C $stage . 2>$null } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archive)) { Exit-Sc 'tar 打包失败' 3 }
        Push-Location $outFull
        try { $check = (& tar -xzOf "scagent-backup-$stamp.tar.gz" ./deploy/.env 2>$null | Out-String) } finally { Pop-Location }
    } else {
        $archive = Join-Path $outFull "scagent-backup-$stamp.zip"
        Write-ScWarn '未找到 tar 命令，改用 Compress-Archive（.zip）'
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive -Force
        $tmpUnzip = Join-Path ([System.IO.Path]::GetTempPath()) ('scagent-unzip-' + [guid]::NewGuid().ToString('N'))
        Expand-Archive -Path $archive -DestinationPath $tmpUnzip -Force
        $check = [System.IO.File]::ReadAllText((Join-Path $tmpUnzip 'deploy\.env'))
        Remove-Item -LiteralPath $tmpUnzip -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue

    # 6) 回验：包内不得有活密钥（脱敏失效时会在这里暴露）
    if ($check -match 'sk-[A-Za-z0-9]{20,}') {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        Exit-Sc '备份包内检出活密钥，已删除该包。请检查 .env 的脱敏规则。' 1
    }
    Write-ScOk '已校验：备份包内无活密钥'

    $sizeMb = [math]::Round((Get-Item -LiteralPath $archive).Length / 1MB, 1)
    Write-Host ''
    Write-Host ('─' * 60) -ForegroundColor DarkCyan
    Write-ScOk "完成：$archive（${sizeMb} MB）"
    Write-ScStep '包内结构： deploy/.env（密钥已清空）、workspace/state/、workspace/data/'
    Write-ScStep '恢复： 解压到临时目录，再把 workspace/ 覆盖回去；.env 里的密钥需重新填写'
    Write-Host ('─' * 60) -ForegroundColor DarkCyan
}

# ── 动词：rollback（与 deploy/rollback.sh 行为对齐）───────────────────────────
function Invoke-ScRollback {
    param([switch]$List)
    $ctx = Get-ScContext
    Assert-ScConfigured -Ctx $ctx

    if ($List) {
        Write-ScInfo '本地已有的 scagent 镜像'
        $out = & docker images --format '{{.Repository}}:{{.Tag}}`t{{.CreatedSince}}`t{{.Size}}' 2>$null
        $hits = @($out | Select-String -Pattern 'scagent-(seurat|agent|runtime)')
        if ($hits.Count -gt 0) { $hits | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (无)' }
        return
    }

    $rolled = 0
    foreach ($svc in @('runtime', 'seurat', 'agent')) {
        $cur = Get-ScImageName -Prefix $ctx.Image.Prefix -Version $ctx.Image.Version -Service $svc
        $prev = "$($ctx.Image.Prefix)/scagent-$svc`:prev"
        if (Test-ScImageExists -Image $prev) {
            Write-ScInfo "回滚 $svc"
            if (-not $DryRun) {
                $null = & docker tag $prev $cur 2>$null
                if ($LASTEXITCODE -ne 0) { Write-ScWarn "打标签失败：$prev → $cur"; continue }
                $id = (& docker image inspect $cur --format '{{.Id}}' 2>$null | Select-Object -First 1)
                Write-ScStep "现在指向：$id"
            }
            $rolled++
        } else {
            Write-ScWarn "$svc 没有 :prev 标签，跳过"
        }
    }

    if ($rolled -eq 0) {
        Exit-Sc "没有任何可回滚的镜像。
      回滚依赖每次升级前保留的 :prev 标签（由 up 或 build 流程打上）。
      若已丢失，请重新拉取目标版本后手工 docker tag（镜像前缀：$($ctx.Image.Prefix)）。" 3
    }

    $sf = Get-ScSecretsFiles -SecretsDir $ctx.SecretsDir
    Write-ScInfo '重启服务'
    Invoke-ScCompose -RepoRoot $RepoRoot -Files $sf.Files -Arguments @('up', '-d', '--force-recreate') -DryRun:$DryRun | Out-Null
    Write-ScOk "已回滚 $rolled 个镜像并重启。建议接着跑： deploy\scagent.cmd verify"
}

# ── 动词：refdata（一次性获取参考数据集）─────────────────────────────────────
function Resolve-ScRefdataChoice {
    <#
      决定要下载哪些参考数据集（celldex）。
      优先级：显式 -Refdata > 交互提问 > 非交互时跳过（不静默联网）。
    #>
    param([string]$Given, [bool]$HaveMouse, [bool]$HaveHuman)

    if ($Given) {
        $g = "$Given".Trim().ToLower()
        if ($g -notin @('mouse', 'human', 'both', 'none')) {
            Exit-Sc "-Refdata 只能是 mouse | human | both | none（当前：$Given）" 2
        }
        return $g
    }
    if ($HaveMouse -and $HaveHuman) { return 'none' }
    if ($DryRun) {
        Write-ScStep '[dry-run] 会询问是否下载参考数据集（1 小鼠 / 2 人类 / 3 两个 / 0 跳过）'
        return 'none'
    }
    if ($Yes) {
        # 非交互模式不做静默下载（可能无外网）；需要时用 -Refdata 显式指定
        return 'none'
    }

    Write-Host ''
    Write-Host '  ── 参考数据集（细胞类型注释 Step 4 需要；下载一次，之后离线可用）──'
    Write-Host ("     [1] 小鼠 MouseRNAseqData（约 17 MB）" + $(if ($HaveMouse) { '   ← 已存在，将跳过' } else { '' }))
    Write-Host ("     [2] 人类 HumanPrimaryCellAtlasData（体积更大）" + $(if ($HaveHuman) { '   ← 已存在，将跳过' } else { '' }))
    Write-Host '     [3] 两个都下载'
    Write-Host '     [0] 先跳过（稍后可随时执行： deploy\scagent.cmd refdata）'
    $ans = "$(Read-Host '  请选择 [1]')".Trim()
    switch ($ans) {
        '2'     { return 'human' }
        '3'     { return 'both' }
        '0'     { return 'none' }
        '1'     { return 'mouse' }
        ''      { return 'mouse' }
        default { Write-ScWarn "无法识别的选项「$ans」—— 按默认（小鼠）处理"; return 'mouse' }
    }
}

function Invoke-ScRefdata {
    <#
      celldex 这个 R 包随镜像自动安装；它提供的**数据集**体积大、不进镜像。
      这里用一个临时容器（带外网）下载并直接写入宿主机的 <SCAGENT_BIODATA>\celldex\，
      生产容器仍然离线、只读挂载 —— 运行期零下载的架构不变。
    #>
    param([string]$Species = 'mouse', [switch]$Force, [switch]$NonFatal)

    # refdata 同理：只依赖 SCAGENT_BIODATA（缺省时用安装根下的 biodata）
    $ctx = Get-ScContextOrDefault
    if (-not $ctx.Image) { Exit-Sc "镜像来源配置无效：$($ctx.ImageError)" 2 }

    $sp = "$Species".Trim().ToLower()
    if ($sp -eq 'human') { $refFun = 'HumanPrimaryCellAtlasData'; $refFile = 'HumanPrimaryCellAtlasData.rds' }
    elseif ($sp -eq 'mouse') { $refFun = 'MouseRNAseqData'; $refFile = 'MouseRNAseqData.rds' }
    else {
        if ($NonFatal) { Write-ScWarn "-Species 只能是 mouse 或 human（当前：$Species）"; return }
        Exit-Sc "-Species 只能是 mouse 或 human（当前：$Species）" 2
    }

    $bioRaw = Get-ScEnvValue -Env $ctx.Env -Key 'SCAGENT_BIODATA'
    if (-not $bioRaw) { $bioRaw = Join-Path (Get-DefaultRoot) 'biodata' }
    $bio = Resolve-ScPath -Path $bioRaw -RepoRoot $RepoRoot
    $target = Join-Path $bio 'celldex'
    $outFile = Join-Path $target $refFile
    $image = Get-ScImageName -Prefix $ctx.Image.Prefix -Version $ctx.Image.Version -Service 'seurat'

    Write-ScBanner "获取参考数据集（celldex） · $ScagentBuild"
    Write-Host "  物种    : $sp（$refFun）"
    Write-Host "  目标目录: $target"
    Write-Host "  使用镜像: $image"
    Write-Host '  说明    : 临时容器联网下载并写入目标目录；生产容器仍然离线只读挂载'

    if ((Test-Path -LiteralPath $outFile) -and -not $Force) {
        $mb = [math]::Round((Get-Item -LiteralPath $outFile).Length / 1MB, 1)
        Write-ScOk "已存在 $outFile（${mb} MB）—— 需要重新下载请加 -Force"
        return
    }
    if ($DryRun) {
        Write-ScStep "[dry-run] docker run --rm --network bridge -v `"$target`":/out --entrypoint Rscript $image -e `"library(celldex); saveRDS($refFun(), '/out/$refFile')`""
        return
    }

    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Assert-ScDocker
    if (-not (Test-ScImageExists -Image $image)) {
        $msg = "本地没有镜像 $image —— 先运行： deploy\scagent.cmd build（或 install）"
        if ($NonFatal) { Write-ScWarn $msg; return }
        Exit-Sc $msg 3
    }

    Write-ScInfo '下载中（体积较大，请耐心等待）'
    $r = "library(celldex); message('正在获取 $refFun() …'); x <- $refFun(); saveRDS(x, '/out/$refFile'); cat('OK', format(file.size('/out/$refFile')), '\n')"
    & docker run --rm --network bridge -v "${target}:/out" --entrypoint Rscript $image -e $r
    if ($LASTEXITCODE -ne 0) {
        $msg = "下载失败。常见原因：容器无法出网（代理/防火墙/DNS）、镜像不存在。
      离线环境可改用自建对象存储： scripts/download_data.sh（见 deploy/data.manifest）"
        if ($NonFatal) {
            Write-ScWarn $msg
            Write-ScStep "网络可用时重试： deploy\scagent.cmd refdata -Species $sp"
            return
        }
        Exit-Sc $msg 3
    }
    $mb = [math]::Round((Get-Item -LiteralPath $outFile).Length / 1MB, 1)
    Write-ScOk "已写入：$outFile（${mb} MB）"
    Write-ScStep '下一步： deploy\scagent.cmd up  →  deploy\scagent.cmd doctor（确认"参考数据（celldex）"为 [OK]）'
}

# ── 分发 ──────────────────────────────────────────────────────────────────────
switch ($Verb.ToLower()) {
    'help'    { Show-ScUsage; exit 0 }
    'install' { Invoke-ScInstall; exit 0 }
    'build'   { Invoke-ScBuild -Force:($Rest -contains '-Force') -NoCache:($Rest -contains '-NoCache'); exit 0 }
    'doctor'  { Invoke-ScDoctor -Quick:($Rest -contains '-Quick'); exit 0 }
    'backup'  {
        Invoke-ScBackup -WithRds:($Rest -contains '-WithRds') `
                        -IncludeSecrets:($Rest -contains '-IncludeSecrets') `
                        -OutDir $(if ($Rest.Count -ge 2 -and $Rest[0] -eq '-Out') { $Rest[1] } else { './backups' })
        exit 0
    }
    'rollback' { Invoke-ScRollback -List:($Rest -contains '-List'); exit 0 }
    'refdata' {
        Invoke-ScRefdata -Species $(if ($Rest.Count -ge 2 -and $Rest[0] -eq '-Species') { $Rest[1] } else { 'mouse' }) `
                         -Force:($Rest -contains '-Force')
        exit 0
    }
    'secrets' { $ctx = Get-ScContext; $null = Invoke-ScSecretsVerb -Ctx $ctx; exit 0 }
    'up'      { Invoke-ScUp; exit 0 }
    'down'    { Invoke-ScDown; exit 0 }
    'restart' { Invoke-ScRestart; exit 0 }
    'status'  { Invoke-ScStatus; exit 0 }
    'verify'  { Invoke-ScVerify; exit 0 }
    'logs'    {
        if ($Rest.Count -gt 0) { Invoke-ScLogs -ServiceName $Rest[0] } else { Invoke-ScLogs }
        exit 0
    }
    default {
        Write-ScErr "未知命令：$Verb"
        Show-ScUsage
        exit 2
    }
}
