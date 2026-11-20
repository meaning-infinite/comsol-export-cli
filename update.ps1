# COMSOL 导出 CLI 更新脚本：从 GitHub 拉最新版，保留 logs / output / models 与机器配置
# 仓库是公开的，不需要 token；若哪天改回私有，脚本会在 401/403 时提示粘贴 token。
param(
    [string]$Repo = 'meaning-infinite/comsol-export-cli',
    [string]$Branch = 'master',
    [string]$Offline = '',        # 离线包：本地 zip 路径（U 盘/微信传过来的）
    [string]$Source = ''          # 指定一个 zip 直链（内网镜像）
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Fail([string]$msg, [int]$code) {
    Write-Host ''
    Write-Host ('[错误] ' + $msg) -ForegroundColor Red
    exit $code
}
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
Set-Location $ScriptDir

# 脚本文件必须是 UTF-8 带 BOM：PowerShell 5.1 会把无 BOM 的 UTF-8 当 GBK 解码，
# 中文串被引号/括号吃坏，整份脚本直接解析失败（Missing closing '}'）。
# 更新后统一扫一遍，缺 BOM 的补上。
function Repair-Bom {
    param([string]$Dir)
    $bom = [byte[]](0xEF, 0xBB, 0xBF)
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -Force -File -ErrorAction SilentlyContinue)) {
        if ($f.Extension -notin @('.ps1', '.psd1')) { continue }
        if ($f.FullName -match '\\_dist\\|\\_backup\\|\\\.git\\') { continue }
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { continue }
        $all = New-Object byte[] ($bytes.Length + 3)
        [Array]::Copy($bom, 0, $all, 0, 3)
        [Array]::Copy($bytes, 0, $all, 3, $bytes.Length)
        [System.IO.File]::WriteAllBytes($f.FullName, $all)
        Write-Host ('  补 UTF-8 BOM：' + $f.Name) -ForegroundColor Yellow
    }
}
$StateDir = Join-Path $env:LOCALAPPDATA 'comsol-export\state'
if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
$tokFile = Join-Path $StateDir 'gh_token.txt'

# driver 里的 .class 必须和 .java 对得上：只更新了脚本、漏掉 driver 目录时，
# 远程会继续跑旧 class，同一个 bug 反复出现却看不出来。这里比对两者的版本串，
# 不一致就用 COMSOL 自带的 javac 重新编一遍；编不了就明确警告。
function Get-DriverVer([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $txt = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($path))
        $m = [regex]::Match($txt, 'v\d+\.\d+\.\d+')
        if ($m.Success) { return $m.Value }
    } catch { }
    return ''
}

function Repair-Driver {
    param([string]$Dir)
    $drv = Join-Path $Dir 'driver'
    $want = Get-DriverVer (Join-Path $drv 'ExportDriver.java')
    $have = Get-DriverVer (Join-Path $drv 'ExportDriver.class')
    if (-not $want) { return }
    if ($have -eq $want) {
        Write-Host ('  driver 版本 ' + $have + '，与源码一致') -ForegroundColor DarkGray
        return
    }
    Write-Host ('  driver 版本不一致：class=' + $have + ' 源码=' + $want + '，尝试重新编译 ...') -ForegroundColor Yellow
    $root = ''
    try {
        $cfgFile = Join-Path $StateDir 'config.psd1'
        if (Test-Path -LiteralPath $cfgFile) {
            $cfg = Import-PowerShellDataFile -LiteralPath $cfgFile
            $cb = [string]$cfg.ComsolPath
            if ($cb) { $root = Split-Path (Split-Path (Split-Path $cb -Parent) -Parent) -Parent }
        }
    } catch { }
    if (-not $root) {
        foreach ($g in @('C:\Program Files\COMSOL', 'D:\COMSOL', 'D:\Program Files\COMSOL')) {
            if (-not (Test-Path -LiteralPath $g)) { continue }
            $hit = Get-ChildItem -LiteralPath $g -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'COMSOL*' } | Select-Object -First 1
            if ($hit -and (Test-Path -LiteralPath (Join-Path $hit.FullName 'Multiphysics'))) { $root = Join-Path $hit.FullName 'Multiphysics'; break }
        }
    }
    $javac = ''
    if ($root) { $javac = Join-Path $root 'java\win64\jre\bin\javac.exe' }
    if ($root -and (Test-Path -LiteralPath $javac)) {
        $cp = Join-Path $root 'plugins\*'
        & $javac -encoding UTF-8 -nowarn -cp $cp -d $drv (Join-Path $drv 'ExportDriver.java') 2>&1 |
            ForEach-Object { Write-Host ('    ' + $_) }
        $after = Get-DriverVer (Join-Path $drv 'ExportDriver.class')
        if ($after -eq $want) { Write-Host ('  已重新编译，driver 版本 ' + $after) -ForegroundColor Green }
        else { Write-Host ('  编译后版本仍是 ' + $after + '，请手工检查 driver 目录') -ForegroundColor Red }
    } else {
        Write-Host '  找不到 COMSOL 的 javac，driver 仍是旧版：请手工用最新包覆盖 script\driver' -ForegroundColor Red
    }
}


# ---------- 路线 A：已是 git 仓库 ----------
$git = Get-Command git -ErrorAction SilentlyContinue
$isGit = Test-Path -LiteralPath (Join-Path $ScriptDir '.git')
if ($isGit -and $git) {
    Write-Host '[1/2] 连接 GitHub 并拉取 ...' -ForegroundColor Cyan
    $ErrorActionPreference = 'Continue'
    & git -C $ScriptDir -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 fetch --depth 1 origin $Branch 2>&1 |
        ForEach-Object { Write-Host ('  ' + $_) }
    if ($LASTEXITCODE -ne 0) { Fail 'git fetch 失败：连不上 GitHub，或网络/代理有问题。' 4 }
    & git -C $ScriptDir reset --hard ('origin/' + $Branch) 2>&1 | ForEach-Object { Write-Host ('  ' + $_) }
    if ($LASTEXITCODE -ne 0) { Fail 'git reset 失败：本地文件与远端冲突，请人工检查。' 5 }
    $ver = (& git -C $ScriptDir log -1 --format='%h %ad' --date=short).Trim()
    Write-Host ''
    Repair-Bom $ScriptDir
    Repair-Driver $ScriptDir

    Write-Host ('[完成] 已更新到 ' + $ver) -ForegroundColor Green
    exit 0
}

# ---------- 路线 B：下载 zip 覆盖 ----------
$tok = $env:GITHUB_TOKEN
if (-not $tok -and (Test-Path -LiteralPath $tokFile)) { $tok = (Get-Content -LiteralPath $tokFile -Raw).Trim() }

function Get-Package([string]$token) {
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $zip = Join-Path $env:TEMP ('comsol-export-' + $stamp + '.zip')
    $direct = @(
        ('https://codeload.github.com/' + $Repo + '/zip/refs/heads/' + $Branch),
        ('https://api.github.com/repos/' + $Repo + '/zipball/' + $Branch),
        ('https://github.com/' + $Repo + '/archive/refs/heads/' + $Branch + '.zip')
    )
    # 公共电脑常连不上 github：依次尝试国内可用镜像
    $mirrors = @('https://ghfast.top/', 'https://ghproxy.net/', 'https://gh-proxy.com/', 'https://mirror.ghproxy.com/')
    $urls = @()
    if ($Source) { $urls += $Source }
    foreach ($m in $mirrors) { $urls += ($m + 'https://github.com/' + $Repo + '/archive/refs/heads/' + $Branch + '.zip') }
    $urls += $direct
    $hdr = @{ 'User-Agent' = 'comsol-export-update' }
    if ($token) { $hdr['Authorization'] = 'token ' + $token }
    $lastErr = ''
    foreach ($url in $urls) {
        try {
            Invoke-WebRequest -Uri $url -Headers $hdr -OutFile $zip -UseBasicParsing -TimeoutSec 30
            if ((Test-Path -LiteralPath $zip) -and (Get-Item -LiteralPath $zip).Length -gt 1000) { return $zip }
        } catch {
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            if ($code -eq 401 -or $code -eq 403) { return 'AUTH' }
            if ($code -eq 404) { $lastErr = '404 仓库不存在或无权访问'; continue }
            $lastErr = $_.Exception.Message
        }
    }
    return ('ERR:' + $lastErr)
}

if ($Offline) {
    if (-not (Test-Path -LiteralPath $Offline)) { Fail ('离线包不存在：' + $Offline) 11 }
    Write-Host ('[1/3] 使用离线包：' + $Offline) -ForegroundColor Cyan
    $res = (Resolve-Path -LiteralPath $Offline).Path
} else {
    Write-Host '[1/3] 下载最新版（先试镜像，再直连）...' -ForegroundColor Cyan
    $res = Get-Package $tok
}
if ($res -eq 'AUTH') {
    Write-Host '  仓库需要认证（401/403）。粘贴一个有 read 权限的 token：' -ForegroundColor Yellow
    $sec = Read-Host '  token' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $tok = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    if (-not $tok) { Fail '没有 token，无法下载私有仓库。' 6 }
    if ((Read-Host '  把 token 存到本机（Y/N）') -match '^[Yy]') {
        [System.IO.File]::WriteAllText($tokFile, $tok, (New-Object System.Text.UTF8Encoding($false)))
    }
    $res = Get-Package $tok
    if ($res -eq 'AUTH') { Fail 'token 无效或没有该仓库的权限（401/403）。' 6 }
}
if ($res -like 'ERR:*') { Fail ('下载失败（多半是连不上 GitHub）：' + $res.Substring(4)) 8 }
$zip = $res

Write-Host '[2/3] 解压并备份旧文件 ...' -ForegroundColor Cyan
$stamp = Get-Date -Format 'yyyyMMddHHmmss'
$tmp = Join-Path $env:TEMP ('comsol-export-unz-' + $stamp)
Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
$pkg = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
if (-not $pkg) { Fail '压缩包结构不对（没有顶层目录）。' 10 }
$verName = $pkg.Name

$bak = Join-Path $ScriptDir ('_backup\' + $stamp)
New-Item -ItemType Directory -Path $bak -Force | Out-Null
$files = @('cli.ps1','run.bat','update.bat','update.ps1','README.md')
$dirs  = @('driver','recipes','lib','docs')
foreach ($f in $files) { $p = Join-Path $ScriptDir $f; if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $bak -Force } }
foreach ($d in $dirs)  { $p = Join-Path $ScriptDir $d; if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $bak -Recurse -Force } }

Write-Host '[3/3] 覆盖程序文件（logs / output / models 不动）...' -ForegroundColor Cyan
# 注意：不能覆盖正在运行的 update.bat（cmd 会按字节偏移续读，导致执行乱码），改名为 .new
$newLauncher = $false
foreach ($f in $files) {
    $src = Join-Path $pkg.FullName $f
    if (-not (Test-Path -LiteralPath $src)) { continue }
    if ($f -eq 'update.bat') {
        $dst = Join-Path $ScriptDir 'update.bat'
        if (-not (Test-Path -LiteralPath $dst) -or ((Get-FileHash -LiteralPath $src).Hash -ne (Get-FileHash -LiteralPath $dst).Hash)) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $ScriptDir 'update.bat.new') -Force
            $newLauncher = $true
        }
        continue
    }
    Copy-Item -LiteralPath $src -Destination (Join-Path $ScriptDir $f) -Force
}
foreach ($d in $dirs) {
    $src = Join-Path $pkg.FullName $d
    if (-not (Test-Path -LiteralPath $src)) { continue }
    $dst = Join-Path $ScriptDir $d
    if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
}
Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

Repair-Bom $ScriptDir
Repair-Driver $ScriptDir

Write-Host ''
Write-Host ('[完成] 已更新（' + $verName + '）') -ForegroundColor Green
Write-Host ('        旧文件备份在 ' + $bak) -ForegroundColor DarkGray
if ($newLauncher) { Write-Host '        启动器有新版：update.bat.new（把老的 update.bat 删掉、把 .new 改名去掉后缀即可）' -ForegroundColor Yellow }
Write-Host '        机器配置、logs、output、models 都没有动。' -ForegroundColor DarkGray
exit 0
