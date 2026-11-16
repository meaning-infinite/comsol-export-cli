# COMSOL 导出 CLI 更新脚本：从 GitHub 拉最新版，保留 logs / output / models 与机器配置
# 仓库是公开的，不需要 token；若哪天改回私有，脚本会在 401/403 时提示粘贴 token。
param(
    [string]$Repo = 'meaning-infinite/comsol-export-cli',
    [string]$Branch = 'master'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Fail([string]$msg, [int]$code) {
    Write-Host ''
    Write-Host ('[错误] ' + $msg) -ForegroundColor Red
    exit $code
}
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir
$StateDir = Join-Path $env:LOCALAPPDATA 'comsol-export\state'
if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
$tokFile = Join-Path $StateDir 'gh_token.txt'

# ---------- 路线 A：已是 git 仓库 ----------
$git = Get-Command git -ErrorAction SilentlyContinue
$isGit = Test-Path -LiteralPath (Join-Path $ScriptDir '.git')
if ($isGit -and $git) {
    Write-Host '[1/2] 连接 GitHub 并拉取 ...' -ForegroundColor Cyan
    $ErrorActionPreference = 'Continue'
    & git -C $ScriptDir -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 fetch --depth 1 origin $Branch 2>&1 |
        ForEach-Object { Write-Host ('  ' + $_) }
    if ($LASTEXITCODE -ne 0) {
        Fail 'git fetch 失败：连不上 GitHub，或网络/代理有问题。' 4
    }
    & git -C $ScriptDir reset --hard ('origin/' + $Branch) 2>&1 | ForEach-Object { Write-Host ('  ' + $_) }
    if ($LASTEXITCODE -ne 0) { Fail 'git reset 失败：本地文件与远端冲突，请人工检查。' 5 }
    $ver = (& git -C $ScriptDir log -1 --format='%h %ad' --date=short).Trim()
    Write-Host ''
    Write-Host ('[完成] 已更新到 ' + $ver) -ForegroundColor Green
    exit 0
}

# ---------- 路线 B：下载 zip 覆盖 ----------
$tok = $env:GITHUB_TOKEN
if (-not $tok -and (Test-Path -LiteralPath $tokFile)) { $tok = (Get-Content -LiteralPath $tokFile -Raw).Trim() }

function Get-Package([string]$token) {
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $zip = Join-Path $env:TEMP ('comsol-export-' + $stamp + '.zip')
    $urls = @(
        ('https://codeload.github.com/' + $Repo + '/zip/refs/heads/' + $Branch),
        ('https://api.github.com/repos/' + $Repo + '/zipball/' + $Branch),
        ('https://github.com/' + $Repo + '/archive/refs/heads/' + $Branch + '.zip')
    )
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

Write-Host '[1/3] 下载最新版 ...' -ForegroundColor Cyan
$res = Get-Package $tok
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
foreach ($f in $files) {
    $src = Join-Path $pkg.FullName $f
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $ScriptDir $f) -Force }
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

Write-Host ''
Write-Host ('[完成] 已更新（' + $verName + '）') -ForegroundColor Green
Write-Host ('        旧文件备份在 ' + $bak) -ForegroundColor DarkGray
Write-Host '        机器配置、logs、output、models 都没有动。' -ForegroundColor DarkGray
exit 0
