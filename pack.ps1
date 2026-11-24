# 生成离线安装包和包内逐文件校验清单。
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$layout = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'release.psd1')
$dist = Join-Path $PSScriptRoot '_dist'
[IO.Directory]::CreateDirectory($dist) | Out-Null
$key = (Get-Date -Format 'yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$zip = Join-Path $dist ("comsol-export-$key.zip")
$stage = Join-Path ([IO.Path]::GetTempPath()) ("TEMP_comsol_pack_$key")
$root = Join-Path $stage 'comsol-export-cli'
try {
    [IO.Directory]::CreateDirectory($root) | Out-Null
    foreach ($rel in @($layout.Files) + @($layout.Required)) {
        if (-not [IO.File]::Exists((Join-Path $PSScriptRoot $rel))) { throw "发布文件缺失 $rel" }
    }
    foreach ($rel in @($layout.Files) + @($layout.Directories)) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $rel) -Destination $root -Recurse
    }
    $entries = @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName | ForEach-Object {
        @{ path=$_.FullName.Substring($root.Length+1).Replace('\','/'); sha256=(Get-FileHash -LiteralPath $_.FullName).Hash }
    })
    [IO.File]::WriteAllText((Join-Path $root 'PACKAGE_FILES.json'), (ConvertTo-Json -InputObject $entries))
    Compress-Archive -LiteralPath $root -DestinationPath $zip -CompressionLevel Optimal
    Write-Host ('离线包 ' + $zip)
} finally {
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($stage)) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and
        [IO.Path]::GetFileName($stage) -eq "TEMP_comsol_pack_$key" -and [IO.Directory]::Exists($stage)) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
