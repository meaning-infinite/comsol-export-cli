# 打包：把当前 script 目录做成一个离线包，供连不上 GitHub 的机器更新
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File pack.ps1
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# 脚本文件必须是 UTF-8 带 BOM：PowerShell 5.1 会把无 BOM 的 UTF-8 按 GBK 解码，
# 中文串里的引号/括号被吃坏，整份脚本直接解析失败（Missing closing '}'）。
# 更新后统一扫描一遍，缺 BOM 的补上。
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
$dist = Join-Path $ScriptDir '_dist'
if (-not (Test-Path -LiteralPath $dist)) { New-Item -ItemType Directory -Path $dist -Force | Out-Null }

$stamp = Get-Date -Format 'yyyyMMddHHmm'
$zip = Join-Path $dist ('comsol-export-' + $stamp + '.zip')
$stage = Join-Path $env:TEMP ('comsol-export-stage-' + $stamp)
$root = Join-Path $stage 'comsol-export-cli-master'
New-Item -ItemType Directory -Path $root -Force | Out-Null

Repair-Bom $ScriptDir

$skipDirs = @('logs','_backup','_dist','.git','test','output','models')
$skipExt  = @('.mph','.lock','.log')
foreach ($item in Get-ChildItem -LiteralPath $ScriptDir -Recurse -Force) {
    $rel = $item.FullName.Substring($ScriptDir.Length).TrimStart('\')
    $top = ($rel -split '\\')[0]
    if ($skipDirs -contains $top) { continue }
    if ($skipExt -contains $item.Extension.ToLower()) { continue }
    $dst = Join-Path $root $rel
    if ($item.PSIsContainer) {
        if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    } else {
        $parent = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $item.FullName -Destination $dst -Force
    }
}
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path $root -DestinationPath $zip -CompressionLevel Optimal
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('离线包已生成：' + $zip) -ForegroundColor Green
Write-Host ('大小：' + [math]::Round((Get-Item -LiteralPath $zip).Length / 1KB, 1) + ' KB') -ForegroundColor DarkGray
Write-Host '拷到目标机后运行：update.bat -Offline <这个文件>' -ForegroundColor DarkGray
