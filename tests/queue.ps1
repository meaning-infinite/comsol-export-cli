#requires -Version 5.1
# Tests run against a private queue and synthetic process records.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $repo 'cli.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($cli,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw $errors[0] }
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] },$false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Assert($ok, $message) { if (-not $ok) { throw $message }; Write-Output "PASS $message" }
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$sandbox = Join-Path $tempRoot ('TEMP_comsol_queue_' + [guid]::NewGuid().ToString('N'))
$previousLocal = $env:LOCALAPPDATA
$oldXmx = $env:COMSOL_EXPORT_XMX
try {
    $env:LOCALAPPDATA = $sandbox
    $StateDir = Join-Path $sandbox 'comsol-export/state'
    $JobsDir = Join-Path $sandbox 'jobs'
    $QueueFile = Join-Path $StateDir 'queue.json'
    $jobDir = Join-Path $JobsDir 'stable_id'
    [IO.Directory]::CreateDirectory($jobDir) | Out-Null
    $job = [pscustomobject]@{id='model';status='pending';jobDir=$jobDir;pid=0;mode='export';phase='export';started=''}
    $script:HandoffStates = @{}
    Save-Queue @()
    Assert (@(Get-Queue).Count -eq 0) 'empty queue round-trip'
    Save-Queue @($job)
    $job.status='running'
    Save-Queue @($job)
    [IO.File]::WriteAllText($QueueFile,'[')
    $restored = @(Get-Queue)
    Assert ($restored.Count -eq 1 -and $restored[0].status -eq 'pending') 'recover latest complete backup'
    Save-Queue $restored
    Assert ((@(Read-QueueFile ($QueueFile+'.bak')))[0].status -eq 'pending') 'keep valid backup during repair'
    $hash = (Get-FileHash $QueueFile).Hash
    $time = [IO.File]::GetLastWriteTimeUtc($QueueFile)
    $watch = & powershell -NoProfile -ExecutionPolicy Bypass -File $cli -Mode watch
    Assert ($LASTEXITCODE -eq 0 -and ($watch -join ' ') -match 'stable_id') 'watch uses stable job ID'
    Assert ((Get-FileHash $QueueFile).Hash -eq $hash -and [IO.File]::GetLastWriteTimeUtc($QueueFile) -eq $time -and
            -not [IO.File]::Exists((Join-Path $StateDir 'cli.lock'))) 'watch acquires no writer lock and writes no queue'
    $discard = '' | & powershell -NoProfile -ExecutionPolicy Bypass -File $cli -DryRun -Resume
    Assert ($LASTEXITCODE -ne 0 -and (Get-FileHash $QueueFile).Hash -eq $hash) 'DryRun with Resume rejected'
    $noop = & powershell -NoProfile -ExecutionPolicy Bypass -File $cli -KillJob stable_id
    Assert ($LASTEXITCODE -eq 0 -and -not [IO.File]::Exists((Join-Path $jobDir 'killed'))) 'pending job cannot kill a process'
    Assert ((Format-Elapsed 2100) -eq '00:35:00' -and (Format-Elapsed 90061) -eq '25:01:01') '35-minute and multi-day elapsed time'
    $script:ProgState=@{}
    [IO.File]::WriteAllLines((Join-Path $jobDir 'progress.txt'),@('done=2','total=4','block=2','blocks=3','label=second'))
    Assert ((Get-ProgressInfo $job).Pct -eq 50) 'multi-block progress, halfway through block 2 of 3'

    $start = [datetime]::UtcNow
    $job.pid=4242
    $job | Add-Member NoteProperty workerStartUtc $start.ToString('o')
    $script:worker = [pscustomobject]@{Name='java.exe';ProcessId=4242;CreationDate=$start;CommandLine=('java ExportDriver "'+(Join-Path $jobDir 'job.properties')+'"')}
    function Get-CimInstance { param($ClassName,$Filter,$ErrorAction)
        if ($ClassName -eq 'Win32_OperatingSystem') { return @{FreePhysicalMemory=16777216} }
        if ($script:worker) { $script:worker }
    }
    function Test-JobAlive { return $false }
    function Clear-JobLock { return 'test' }
    function taskkill.exe { $script:stopCount++; $script:worker=$null }
    $script:stopCount=0
    $script:worker.CreationDate=$start.AddMinutes(5)
    $null = Stop-OneJob $job
    Assert ($script:stopCount -eq 0) 'PID reuse is excluded'
    $job.pid=4242; $job.status='running'
    $script:worker.CreationDate=$start
    $script:worker.CommandLine = 'java ExportDriver "' + (Join-Path ($jobDir+'2') 'job.properties') + '"'
    $null = Stop-OneJob $job
    Assert ($script:stopCount -eq 0) 'similar job directory is excluded'
    $job.pid=4242; $job.status='running'
    $script:worker.CommandLine = 'java ExportDriver "' + (Join-Path $jobDir 'job.properties') + '"'
    $null = Stop-OneJob $job
    Assert ($script:stopCount -eq 1 -and $job.status -eq 'killed') 'only verified worker terminated'

    $Cores=1; $Heap='5g'
    $budget=Get-ResourceBudget 9
    Assert ($budget.slots -le 2 -and $budget.slots*$budget.heapMB -le $budget.pool -and
            $budget.slots*$budget.cores -le $budget.cpu) 'shared CPU and RAM ceiling'
    $Heap='32g'; $caught=$false
    try { $null=Get-ResourceBudget 2 } catch { $caught=$true }
    Assert $caught 'oversized per-job heap rejected'

    $ModuleDir=Join-Path $repo 'modules'
    $map=Get-ModuleDefs
    foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $repo 'recipes') -Filter '*.psd1')) {
        $cfg=Import-PowerShellDataFile -LiteralPath $f.FullName
        $blocks=@(Expand-Blocks $cfg $map)
        Assert ($blocks.Count -gt 0) ('recipe ' + $f.BaseName)
    }
    foreach ($bad in @(@{Type='global';Expr=@('1','2');Cols=@('one')},@{Type='modes';MaxModes=0},@{Type='unsupported'})) {
        $caught=$false
        try { $null=Expand-Blocks @{Export=@($bad)} $map } catch { $caught=$true }
        Assert $caught ('invalid recipe rejected: '+$bad.Type)
    }
} finally {
    $env:LOCALAPPDATA=$previousLocal
    $env:COMSOL_EXPORT_XMX=$oldXmx
    $target=[IO.Path]::GetFullPath($sandbox)
    if ([IO.Path]::GetDirectoryName($target) -eq $tempRoot.TrimEnd('\') -and
        [IO.Path]::GetFileName($target) -like 'TEMP_comsol_queue_*' -and [IO.Directory]::Exists($target)) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}
