#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$sandbox = Join-Path $tempRoot ('TEMP_comsol_package_' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $sandbox 'source'
$deploy = Join-Path $sandbox 'deploy'
$previousLocal = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = Join-Path $sandbox 'local'
    [IO.Directory]::CreateDirectory($source) | Out-Null
    [IO.Directory]::CreateDirectory($deploy) | Out-Null
    $layout = Import-PowerShellDataFile -LiteralPath (Join-Path $repo 'release.psd1')
    foreach ($rel in @($layout.Files) + @($layout.Directories)) {
        Copy-Item -LiteralPath (Join-Path $repo $rel) -Destination $source -Recurse
    }
    & (Join-Path $source 'pack.ps1')
    $zip = (Get-ChildItem -LiteralPath (Join-Path $source '_dist') -Filter '*.zip').FullName
    $hash = (Get-FileHash $zip).Hash
    [IO.File]::WriteAllText((Join-Path $deploy 'update.ps1'), 'throw "legacy updater called"')
    [IO.File]::WriteAllText((Join-Path $deploy 'README.md'),'prior version')
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $source 'update.ps1') -Offline $zip -InstallDir $deploy
    if ($LASTEXITCODE -ne 0 -or (Get-FileHash $zip).Hash -ne $hash) { throw 'offline installation or archive retention failed' }
    foreach ($f in @($layout.Required) + @($layout.Files | Where-Object { $_ -ne 'update.bat' })) {
        if ((Get-FileHash -LiteralPath (Join-Path $deploy $f)).Hash -ne (Get-FileHash -LiteralPath (Join-Path $source $f)).Hash) { throw "not installed $f" }
    }
    $launcher = Join-Path $deploy 'update.bat'
    if (-not [IO.File]::Exists($launcher)) { $launcher += '.new' }
    if ((Get-FileHash $launcher).Hash -ne (Get-FileHash (Join-Path $source 'update.bat')).Hash) { throw 'launcher missing' }
    Write-Output 'PASS all required modules, assets, classes, documents and launcher installed; input ZIP is intact'
    $bad = Join-Path $sandbox 'incomplete.zip'
    Copy-Item -LiteralPath $zip -Destination $bad
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $pkg = [IO.Compression.ZipFile]::Open($bad,'Update')
    try {
        $entry = @($pkg.Entries | Where-Object { $_.FullName.Replace('\','/') -like '*/modules/image.psd1' })[0]
        $entry.Delete()
    } finally { $pkg.Dispose() }
    $readme=Join-Path $deploy 'README.md'
    [IO.File]::WriteAllText($readme,'sentinel')
    $ErrorActionPreference = 'Continue'
    $discard = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $deploy 'update.ps1') -Offline $bad 2>&1
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -eq 0 -or [IO.File]::ReadAllText($readme) -ne 'sentinel' -or -not [IO.File]::Exists($bad)) {
        throw 'incomplete package was applied'
    }
    Write-Output 'PASS incomplete package rejected before changing installation'
} finally {
    $env:LOCALAPPDATA = $previousLocal
    $target = [IO.Path]::GetFullPath($sandbox)
    if ([IO.Path]::GetDirectoryName($target) -eq $tempRoot.TrimEnd('\') -and
        [IO.Path]::GetFileName($target) -like 'TEMP_comsol_package_*' -and [IO.Directory]::Exists($target)) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}
