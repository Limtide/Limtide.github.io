<#
.SYNOPSIS
  OpenClaw 一键安装脚本 (Windows) - 增强 UI 与错误诊断版
.DESCRIPTION
  自动检测并安装 Node.js v22+、Git，然后安装并配置 OpenClaw。
  包含结构化错误拦截与环境预检功能。
.NOTES
  用法:
    powershell -ExecutionPolicy Bypass -File install-openclaw.ps1
#>

# ── 执行策略自修复：如果当前策略阻止脚本运行，自动以 Bypass 重启 ──
if ($MyInvocation.MyCommand.Path) {
    try {
        $policy = Get-ExecutionPolicy -Scope Process
        if ($policy -eq "Restricted" -or $policy -eq "AllSigned") {
            Write-Host "  ℹ️  检测到执行策略为 $policy，正在以 Bypass 策略重新启动..." -ForegroundColor Blue
            Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -Wait -NoNewWindow
            exit $LASTEXITCODE
        }
    } catch {}
}

# ── 强制 UTF-8 编码 ──
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "  ❌ 需要 PowerShell 5.0 或更高版本，当前版本: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── 1. 新版 UI 与故障排查引擎 ──

function Write-UI {
    param(
        [ValidateSet("Title", "Step", "Info", "Success", "Warn", "Error", "Menu")]
        [string]$Type,
        [string]$Message
    )
    switch ($Type) {
        "Title"   { Write-Host "`n🦞 $Message `n$('-' * 55)" -ForegroundColor Cyan }
        "Step"    { Write-Host "`n▶ $Message" -ForegroundColor Magenta }
        "Info"    { Write-Host "  ℹ️  $Message" -ForegroundColor Blue }
        "Success" { Write-Host "  ✅  $Message" -ForegroundColor Green }
        "Warn"    { Write-Host "  ⚠️  $Message" -ForegroundColor Yellow }
        "Error"   { Write-Host "  ❌  $Message" -ForegroundColor Red }
        "Menu"    { Write-Host "  👉 $Message" -ForegroundColor Cyan }
    }
}

function Show-Solution {
    param([string]$Context, [string]$ErrorMsg)
    
    Write-Host "`n  💡 错误分析与解决建议 ($Context):" -ForegroundColor Yellow
    Write-Host "  $('-' * 55)" -ForegroundColor DarkGray
    if ($ErrorMsg) { Write-Host "  [原生报错] $ErrorMsg" -ForegroundColor DarkGray }

    switch ($Context) {
        "NodeDownload" {
            Write-Host "  1. 网络问题: 无法连接到 Node.js 镜像源。请检查是否开启了代理，或者尝试关闭/切换代理节点。"
            Write-Host "  2. 权限问题: 尝试右键 PowerShell，选择【以管理员身份运行】后再次执行此脚本。"
            Write-Host "  3. 手动安装: 访问 https://nodejs.org/ 手动安装 Node.js v22，然后重试。"
        }
        "GitInstall" {
            Write-Host "  1. 文件损坏: 下载过程可能被中断，请重新运行脚本尝试再次下载。"
            Write-Host "  2. 安全拦截: 杀毒软件可能拦截了 Git 的静默安装，请暂时放行。"
            Write-Host "  3. 手动安装: 访问 https://git-scm.com/downloads 手动安装 Git 后重试。"
        }
        "PnpmInstall" {
            Write-Host "  1. npm 缓存异常: 在终端运行 'npm cache clean --force' 后重试。"
            Write-Host "  2. 权限不足: 无法写入全局 npm 目录，请【以管理员身份运行】PowerShell。"
        }
        "OpenClawInstall" {
            Write-Host "  1. GitHub 网络受限: OpenClaw 的底层依赖需要从 GitHub 拉取。如果直连失败，请在代理工具开启后，运行以下命令设置 Git 代理:"
            Write-Host "     git config --global http.https://github.com.proxy http://127.0.0.1:你的代理端口"
            Write-Host "  2. pnpm 缓存损坏: 尝试运行 'pnpm store prune' 清理缓存后重试。"
        }
        Default {
            Write-Host "  1. 请检查网络连通性。"
            Write-Host "  2. 尝试重启终端或计算机后重试。"
        }
    }
    Write-Host "  $('-' * 55)`n" -ForegroundColor DarkGray
}

# ── 2. 全局变量 ──

$script:NodeBinDir = $null
$script:NvmManaged = $false
$script:RequiredNodeMajor = 22
$script:Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }

function Get-LocalAppData {
    if ($env:LOCALAPPDATA) { return $env:LOCALAPPDATA }
    return (Join-Path $HOME "AppData\Local")
}

# ── 3. 核心工具函数 ──

function Refresh-PathEnv {
    $machinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    $env:PATH = "$machinePath;$userPath"
}

function Add-ToUserPath {
    param([string]$Dir)
    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($currentPath -notlike "*$Dir*") {
        [Environment]::SetEnvironmentVariable("PATH", "$Dir;$currentPath", "User")
        $env:PATH = "$Dir;$env:PATH"
        Write-UI "Info" "已将 $Dir 添加到用户 PATH"
    }
}

function Ensure-ExecutionPolicy {
    try {
        $currentPolicy = Get-ExecutionPolicy -Scope CurrentUser
        if ($currentPolicy -eq "Restricted" -or $currentPolicy -eq "AllSigned") {
            Write-UI "Info" "当前执行策略为 $currentPolicy，正在调整以允许运行 pnpm 脚本..."
            Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
            Write-UI "Success" "已将执行策略设置为 RemoteSigned（仅当前用户）"
        }
    } catch {
        Write-UI "Warn" "无法自动设置执行策略，请手动执行: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
    }
}

function Get-NodeVersion {
    param([string]$NodeExe = "node")
    try {
        $output = & $NodeExe -v 2>$null
        if ($output -match "v(\d+)") {
            $major = [int]$Matches[1]
            if ($major -ge $script:RequiredNodeMajor) {
                return $output.Trim()
            }
        }
    } catch {}
    return $null
}

function Pin-NodePath {
    foreach ($dir in $env:PATH.Split(";")) {
        if (-not $dir) { continue }
        $nodeExe = Join-Path $dir "node.exe"
        if (Test-Path $nodeExe) {
            try {
                $output = & $nodeExe -v 2>$null
                if ($output -match "v(\d+)" -and [int]$Matches[1] -ge $script:RequiredNodeMajor) {
                    $script:NodeBinDir = $dir
                    $rest = ($env:PATH.Split(";") | Where-Object { $_ -ne $dir }) -join ";"
                    $env:PATH = "$dir;$rest"
                    Write-UI "Info" "锁定 Node.js v22 路径: $dir"
                    return
                }
            } catch {}
        }
    }
}

function Get-PnpmCmd {
    if ($script:NodeBinDir) {
        $cmd = Join-Path $script:NodeBinDir "pnpm.cmd"
        if (Test-Path $cmd) { return $cmd }
    }
    $defaultPnpmHome = Join-Path (Get-LocalAppData) "pnpm"
    $cmd = Join-Path $defaultPnpmHome "pnpm.cmd"
    if (Test-Path $cmd) { return $cmd }
    try {
        $resolved = (Get-Command pnpm.cmd -ErrorAction Stop).Source
        if (Test-Path $resolved) { return $resolved }
    } catch {}
    return "pnpm.cmd"
}

function Ensure-PnpmHome {
    $pnpmHome = $env:PNPM_HOME
    if (-not $pnpmHome) { $pnpmHome = [Environment]::GetEnvironmentVariable("PNPM_HOME", "User") }
    if (-not $pnpmHome) { $pnpmHome = Join-Path (Get-LocalAppData) "pnpm" }

    $env:PNPM_HOME = $pnpmHome
    if ($env:PATH -notlike "*$pnpmHome*") { $env:PATH = "$pnpmHome;$env:PATH" }

    $savedHome = [Environment]::GetEnvironmentVariable("PNPM_HOME", "User")
    if ($savedHome -ne $pnpmHome) {
        [Environment]::SetEnvironmentVariable("PNPM_HOME", $pnpmHome, "User")
        Write-UI "Info" "已持久化 PNPM_HOME=$pnpmHome"
    }
    Add-ToUserPath $pnpmHome
}

function Find-OpenclawBinary {
    $searchDirs = @()
    try {
        $pnpmCmd = Get-PnpmCmd
        $pnpmBin = (& $pnpmCmd bin -g 2>$null).Trim()
        if ($pnpmBin -and (Test-Path $pnpmBin)) { $searchDirs += $pnpmBin }
    } catch {}

    if ($env:PNPM_HOME -and (Test-Path $env:PNPM_HOME)) { $searchDirs += $env:PNPM_HOME }
    
    $searchDirs = $searchDirs | Where-Object { $_ } | Select-Object -Unique
    foreach ($dir in $searchDirs) {
        foreach ($name in @("openclaw.cmd", "openclaw.exe", "openclaw.ps1")) {
            $candidate = Join-Path $dir $name
            if (Test-Path $candidate) { return @{ Path = $candidate; Dir = $dir } }
        }
    }
    return $null
}

function Download-File {
    param([string]$Dest, [string[]]$Urls)
    foreach ($url in $Urls) {
        $hostName = ([Uri]$url).Host
        Write-UI "Info" "正在从 $hostName 下载..."
        try {
            Invoke-WebRequest -Uri $url -OutFile $Dest -UseBasicParsing -TimeoutSec 300
            Write-UI "Success" "下载完成"
            return $true
        } catch {
            Write-UI "Warn" "从 $hostName 下载失败，尝试备用源..."
        }
    }
    return $false
}

# ── 4. 依赖安装流程 ──

function Install-NodeDirect {
    Write-UI "Info" "正在直接下载安装 Node.js v22..."
    $version = "v22.14.0" # 这里可替换为动态获取逻辑
    $filename = "node-$version-win-$($script:Arch).zip"
    $tmpPath = Join-Path $env:TEMP "openclaw-install"
    $tmpFile = Join-Path $tmpPath $filename
    $extractedName = "node-$version-win-$($script:Arch)"
    $installDir = Join-Path (Get-LocalAppData) "nodejs"

    New-Item -ItemType Directory -Force -Path $tmpPath | Out-Null

    $downloaded = Download-File -Dest $tmpFile -Urls @(
        "https://npmmirror.com/mirrors/node/$version/$filename",
        "https://nodejs.org/dist/$version/$filename"
    )

    if (-not $downloaded) {
        Show-Solution "NodeDownload" "全部镜像源下载超时或被拒绝。"
        return $false
    }

    try {
        Write-UI "Info" "正在解压安装..."
        Expand-Archive -Path $tmpFile -DestinationPath $tmpPath -Force
        if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force }
        Move-Item (Join-Path $tmpPath $extractedName) $installDir

        $env:PATH = "$installDir;$env:PATH"
        Add-ToUserPath $installDir
    } catch {
        Show-Solution "NodeDownload" "解压或移动文件时发生错误: $_"
        return $false
    }

    $ver = Get-NodeVersion
    if ($ver) {
        Write-UI "Success" "Node.js $ver 安装成功"
        return $true
    }
    return $false
}

function Install-GitDirect {
    Write-UI "Info" "正在下载 Git for Windows..."
    $filename = "Git-2.45.2-64-bit.exe" # 可替换为动态获取
    $tmpPath = Join-Path $env:TEMP "openclaw-install"
    $tmpFile = Join-Path $tmpPath $filename

    New-Item -ItemType Directory -Force -Path $tmpPath | Out-Null

    $downloaded = Download-File -Dest $tmpFile -Urls @(
        "https://registry.npmmirror.com/-/binary/git-for-windows/v2.45.2.windows.1/$filename",
        "https://github.com/git-for-windows/git/releases/download/v2.45.2.windows.1/$filename"
    )

    if (-not $downloaded) {
        Show-Solution "GitInstall" "无法下载 Git 安装程序。"
        return $false
    }

    Write-UI "Info" "正在静默安装 Git..."
    try {
        Start-Process -FilePath $tmpFile -ArgumentList "/VERYSILENT","/NORESTART","/NOCANCEL","/SP-","/CLOSEAPPLICATIONS","/RESTARTAPPLICATIONS" -Wait
        Refresh-PathEnv
        Write-UI "Success" "Git 安装成功"
        return $true
    } catch {
        Show-Solution "GitInstall" "静默安装进程执行失败: $_"
        return $false
    }
}

function Run-PnpmInstall {
    param([string]$PnpmCmd, [string]$Label = "安装")

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "cmd.exe"
        $psi.Arguments = "/c `"$PnpmCmd`" add -g openclaw@latest"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
    } catch {
        Write-UI "Error" "启动${Label}进程失败: $_"
        return @{ Success = $false; Stderr = ""; Stdout = "" }
    }

    $progress = 0
    $width = 30
    while (-not $proc.HasExited) {
        if ($progress -lt 90) { $progress += 2 }
        $filled = [math]::Floor($progress * $width / 100)
        $empty = $width - $filled
        $bar = ([string]::new([char]0x2588, $filled)) + ([string]::new([char]0x2591, $empty))
        Write-Host "`r  ⏳ ${Label}中 [$bar] $($progress.ToString().PadLeft(3))%" -ForegroundColor Cyan -NoNewline
        Start-Sleep -Seconds 1
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $fullBar = [string]::new([char]0x2588, $width)
    if ($proc.ExitCode -eq 0) {
        Write-Host "`r  ✅ ${Label}完成 [$fullBar] 100%" -ForegroundColor Green
        return @{ Success = $true; Stderr = $stderr; Stdout = $stdout }
    }

    Write-Host "`r  ❌ ${Label}失败 [$fullBar] 异常退出" -ForegroundColor Red
    return @{ Success = $false; Stderr = $stderr; Stdout = $stdout; ExitCode = $proc.ExitCode }
}

# ── 5. 主流程步骤 ──

function Step-CheckNode {
    Write-UI "Step" "步骤 1/6: 准备 Node.js 环境"
    
    $ver = Get-NodeVersion
    if ($ver) {
        Write-UI "Success" "Node.js $ver 已安装，版本满足要求 (>= 22)"
        Pin-NodePath
        return $true
    }

    Write-UI "Warn" "未检测到合格的 Node.js，准备自动安装..."
    if (Install-NodeDirect) {
        Pin-NodePath
        return $true
    }
    return $false
}

function Step-CheckGit {
    Write-UI "Step" "步骤 2/6: 准备 Git 环境"

    try { $ver = (& git --version 2>$null).Trim() } catch { $ver = $null }
    if ($ver) {
        Write-UI "Success" "$ver 已安装"
        return $true
    }

    Write-UI "Warn" "未检测到 Git，正在自动安装..."
    return (Install-GitDirect)
}

function Step-InstallPnpm {
    Write-UI "Step" "步骤 3/6: 安装 pnpm 包管理器"

    $pnpmCmd = Get-PnpmCmd
    try {
        $pnpmVer = (& $pnpmCmd -v 2>$null).Trim()
        if ($pnpmVer) {
            Write-UI "Success" "pnpm $pnpmVer 已安装，跳过"
            Ensure-PnpmHome
            return $true
        }
    } catch {}

    Write-UI "Info" "正在通过 npm 安装 pnpm..."
    try {
        $savedEAP = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        & npm install -g pnpm 2>$null | Out-Null
        $npmExit = $LASTEXITCODE
        $ErrorActionPreference = $savedEAP
        
        if ($npmExit -ne 0) { throw "退出码 $npmExit" }
        
        $pnpmVer = (& (Get-PnpmCmd) -v 2>$null).Trim()
        Write-UI "Success" "pnpm $pnpmVer 安装成功"
        Ensure-PnpmHome
        return $true
    } catch {
        Show-Solution "PnpmInstall" "npm install -g pnpm 执行失败: $_"
        return $false
    }
}

function Step-InstallOpenClaw {
    Write-UI "Step" "步骤 4/6: 安装 OpenClaw 核心框架"

    Write-UI "Info" "正在拉取依赖并安装，请耐心等待..."
    $pnpmCmd = Get-PnpmCmd
    
    $result = Run-PnpmInstall -PnpmCmd $pnpmCmd -Label "安装 OpenClaw"
    if ($result.Success) {
        Write-UI "Success" "OpenClaw 核心安装完成"
        Ensure-ExecutionPolicy
        return $true
    }

    Show-Solution "OpenClawInstall" "Exit Code: $($result.ExitCode)`n$($result.Stderr)"
    return $false
}

function Step-Verify {
    Write-UI "Step" "步骤 5/6: 验证环境与可执行文件"

    Refresh-PathEnv
    $found = Find-OpenclawBinary
    if ($found) {
        Add-ToUserPath $found.Dir
        try { $ver = (& $found.Path -v 2>$null).Trim() } catch { $ver = $null }
        if ($ver) {
            Write-UI "Success" "OpenClaw $ver 验证通过！路径: $($found.Path)"
            return $true
        }
    }

    Write-UI "Error" "无法找到 openclaw 命令。请尝试重启当前 PowerShell 窗口。"
    return $false
}

function Step-Onboard {
    Write-UI "Step" "步骤 6/6: 初始化配置"

    Write-Host "`n  请选择要使用的 AI 模型供应商:" -ForegroundColor Cyan
    Write-UI "Menu" "1) OpenAI / Codex"
    Write-UI "Menu" "2) Anthropic (Claude 4.5/4.6)"
    Write-UI "Menu" "3) Google Gemini"
    Write-UI "Menu" "4) 智谱 AI (GLM-4.7/5)"
    Write-UI "Menu" "5) 自定义 (兼容接口)"
    Write-UI "Menu" "0) 跳过配置"
    
    $choice = (Read-Host "`n  请输入编号 [0-5]").Trim()
    if ($choice -eq "0") {
        Write-UI "Info" "已跳过配置。你可以随时运行 'openclaw onboard' 进行配置。"
        return $true
    }

    Write-Host ""
    $apiKey = (Read-Host "  🔑 请输入 API Key").Trim()
    if (-not $apiKey) {
        Write-UI "Error" "API Key 不能为空，跳过配置。"
        return $false
    }

    $providerMap = @{
        "1" = "--openai-api-key"; "2" = "--anthropic-api-key";
        "3" = "--gemini-api-key"; "4" = "--zai-api-key"; "5" = "--custom-api-key"
    }

    $found = Find-OpenclawBinary
    $openclawCmd = if ($found) { $found.Path } else { "openclaw" }

    Write-UI "Info" "正在将配置写入本地..."
    try {
        & $openclawCmd onboard --non-interactive --mode local --auth-choice ($providerMap[$choice].Substring(2)) $($providerMap[$choice]) $apiKey *>$null
        Write-UI "Success" "配置初始化成功！"
    } catch {
        Write-UI "Warn" "自动配置未能完全执行，请在终端中输入 'openclaw onboard' 手动完成配置。"
    }

    # 尝试启动后台 Gateway
    Write-UI "Info" "尝试启动 OpenClaw 后台服务..."
    try {
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$openclawCmd`" gateway" -WindowStyle Hidden
        Start-Sleep -Seconds 2
        Write-UI "Success" "服务已在后台运行 (端口: 18789)"
    } catch {
        Write-UI "Warn" "服务自启动失败，使用前请先运行 'openclaw gateway'"
    }

    return $true
}

# ── 6. 执行入口 ──

function Main {
    Write-UI "Title" "OpenClaw 环境初始化与安装引导"

    Refresh-PathEnv
    $existingVer = $null
    $found = Find-OpenclawBinary
    if ($found) { try { $existingVer = (& $found.Path -v 2>$null).Trim() } catch {} }
    
    if ($existingVer) {
        Ensure-ExecutionPolicy
        Write-UI "Success" "OpenClaw $existingVer 已安装在系统中。"
        $reconfig = (Read-Host "  是否要重新配置? [y/N]").Trim()
        if ($reconfig -match "^[Yy]") { Step-Onboard | Out-Null }
        return
    }

    if (-not (Step-CheckNode))       { return }
    if (-not (Step-CheckGit))        { return }
    if (-not (Step-InstallPnpm))     { return }
    if (-not (Step-InstallOpenClaw)) { return }
    if (-not (Step-Verify))          { return }
    Step-Onboard | Out-Null

    Write-Host "`n  🎉 所有步骤执行完毕！你的龙虾已准备就绪！`n" -ForegroundColor Green
}

Main

# 安装完成后刷新当前进程的 PATH
$machinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
$env:PATH = "$userPath;$machinePath"