# 打包：把当前 script 目录做成一个离线包，供连不上 GitHub 的机器更新
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File pack.ps1
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir
$dist = Join-Path $ScriptDir '_dist'
if (-not (Test-Path -LiteralPath $dist)) { New-Item -ItemType Directory -Path $dist -Force | Out-Null }

$stamp = Get-Date -Format 'yyyyMMddHHmm'
$zip = Join-Path $dist ('comsol-export-' + $stamp + '.zip')
$stage = Join-Path $env:TEMP ('comsol-export-stage-' + $stamp)
$root = Join-Path $stage 'comsol-export-cli-master'
New-Item -ItemType Directory -Path $root -Force | Out-Null

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
