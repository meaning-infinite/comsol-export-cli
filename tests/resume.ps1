#requires -Version 5.1
param([Parameter(Mandatory)][string]$ComsolBatch, [Parameter(Mandatory)][string]$SolvedModel)
$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path -LiteralPath $ComsolBatch).Path
$model = (Resolve-Path -LiteralPath $SolvedModel).Path
$repo = Split-Path -Parent $PSScriptRoot
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$box = Join-Path $tempRoot ('TEMP_comsol_resume_' + [guid]::NewGuid().ToString('N'))
$scriptDir = Join-Path $box 'script'
$models = Join-Path $box 'models'
$oldLocal = $env:LOCALAPPDATA
$controllers = @()
function Read-Jobs {
    if (-not [IO.File]::Exists($queuePath)) { return }
    $stream = [IO.File]::Open($queuePath,'Open','Read',[IO.FileShare]'ReadWrite, Delete')
    $reader = [IO.StreamReader]::new($stream)
    try { $reader.ReadToEnd() | ConvertFrom-Json | ForEach-Object { $_ } } finally { $reader.Dispose() }
}
function Start-Controller($arguments) {
    $si=[Diagnostics.ProcessStartInfo]::new()
    $si.FileName='powershell.exe'
    $si.Arguments='-NoProfile -ExecutionPolicy Bypass -File "' + $cli + '" -ComsolPath "' + $exe + '" ' + $arguments
    $si.UseShellExecute=$false
    $si.CreateNoWindow=$true
    $si.RedirectStandardInput=$true
    # The redirected log is short because CLI renders only status changes.
    $si.RedirectStandardOutput=$true
    $p=[Diagnostics.Process]::Start($si)
    $p.StandardInput.WriteLine('1')
    $p.StandardInput.Close()
    return $p
}
function Wait-JobState($index,$state,$process) {
    $limit=[datetime]::UtcNow.AddMinutes(3)
    do {
        $q=@(Read-Jobs)
        if ($q.Count -gt $index -and $q[$index].status -eq $state) { return $q[$index] }
        if ($process.HasExited) { throw ('CLI exited before '+$state+' '+$process.StandardOutput.ReadToEnd()) }
        Start-Sleep -Milliseconds 200
    } while ([datetime]::UtcNow -lt $limit)
    throw "timeout waiting for $index / $state"
}
try {
    $env:LOCALAPPDATA=Join-Path $box 'local'
    $queuePath=Join-Path $env:LOCALAPPDATA 'comsol-export/state/queue.json'
    [IO.Directory]::CreateDirectory($scriptDir) | Out-Null
    [IO.Directory]::CreateDirectory($models) | Out-Null
    foreach ($name in @('cli.ps1','driver','modules')) { Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $scriptDir -Recurse }
    $recipes=Join-Path $scriptDir 'recipes'
    [IO.Directory]::CreateDirectory($recipes) | Out-Null
    $cfg="@{Task='test'; NameTemplate='{model}'; Export=@(@{Type='global'; Name='identity'; Expr=@('1'); Cols=@('value')})}"
    [IO.File]::WriteAllText((Join-Path $recipes 'test.psd1'),$cfg,[Text.Encoding]::UTF8)
    foreach ($id in @('A','B','C')) { [IO.File]::WriteAllText((Join-Path $models ($id+'.link')),$model) }
    $cli=Join-Path $scriptDir 'cli.ps1'
    $cores=[Environment]::ProcessorCount
    $first=Start-Controller ('-Mode export -Models "'+$models+'" -ModelIndex a -Recipe test -Heap 768m -Cores '+$cores)
    $controllers += $first
    $active=Wait-JobState 0 'running' $first
    $submitted=@(Read-Jobs)
    if ($submitted.Count -ne 3 -or $submitted[1].status -ne 'pending') { throw 'resource admission failed' }
    $launch=Join-Path $active.jobDir 'launch.txt'
    $launchHash=(Get-FileHash -LiteralPath $launch).Hash
    # Only the test-owned scheduler is closed. Its COMSOL worker remains alive.
    $first.Kill()
    $first.WaitForExit()
    $resumed=Start-Controller '-Resume'
    $controllers += $resumed
    $second=Wait-JobState 1 'running' $resumed
    $message=& powershell -NoProfile -ExecutionPolicy Bypass -File $cli -KillJob (Split-Path -Leaf $second.jobDir)
    if ($LASTEXITCODE -ne 0) { throw ('cancel failed '+($message -join ' ')) }
    if (-not $resumed.WaitForExit(180000)) { throw 'resume timeout' }
    $trace=$resumed.StandardOutput.ReadToEnd()
    $q=@(Read-Jobs)
    if (($q.status -join ',') -ne 'done,killed,done' -or $resumed.ExitCode -ne 4) { throw ('unexpected terminal states '+($q.status -join ',')+' '+$trace) }
    if ((Get-FileHash -LiteralPath $launch).Hash -ne $launchHash) { throw 'resumed worker launched twice' }
    foreach ($j in $q) { if (-not [IO.File]::Exists((Join-Path $j.resultDir 'EXPORT_MANIFEST.md'))) { throw 'job manifest missing' } }
    $manifest=[IO.File]::ReadAllText((Join-Path $active.batchDir 'EXPORT_MANIFEST.md'))
    if ($manifest -notmatch 'killed' -or ($manifest -split '\| done \|').Count -ne 3) { throw 'batch manifest stale' }
    Write-Output 'PASS budget queues 3 jobs, closing scheduler leaves worker intact, resume reattaches once, stable ID kills only B, independent C finishes, all handoffs published'
} finally {
    foreach ($p in $controllers) { if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }; $p.Dispose() }
    # On a failed assertion keep the evidence and terminate only workers owned by this test queue.
    if ($queuePath -and [IO.File]::Exists($queuePath)) {
        foreach ($j in @(Read-Jobs)) {
            if ($j.status -eq 'running') { & powershell -NoProfile -ExecutionPolicy Bypass -File $cli -KillJob (Split-Path -Leaf $j.jobDir) | Out-Null }
        }
    }
    $env:LOCALAPPDATA=$oldLocal
    $target=[IO.Path]::GetFullPath($box)
    if ($manifest -and [IO.Path]::GetDirectoryName($target) -eq $tempRoot.TrimEnd('\') -and
        [IO.Path]::GetFileName($target) -like 'TEMP_comsol_resume_*') { Remove-Item -LiteralPath $target -Recurse -Force }
}
