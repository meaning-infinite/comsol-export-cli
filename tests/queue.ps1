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
    $ConfigFile = Join-Path $StateDir 'config.psd1'
    [IO.File]::WriteAllText($ConfigFile,"@{ ProgressStyle='3' }",[Text.Encoding]::UTF8)
    Save-Config 'Models' "D:\User's Models"
    Save-Config 'ComsolBatch' 'D:\bin\comsolbatch.exe'
    $saved = Read-Config
    Assert ($saved.Models -eq "D:\User's Models" -and $saved.ComsolBatch -eq 'D:\bin\comsolbatch.exe' -and
            $saved.ProgressStyle -eq '3') 'a setup update retains other settings and literal quotes in paths'
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

    $clock = [datetime]'2026-01-02 10:00:00'
    $script:ProgState=@{}
    $seconds = Get-RecentEta $job 'solve' 4 100 $clock.AddMinutes(20) $clock
    Assert ([math]::Abs($seconds-28800) -lt 1) 'reopening a slow sweep at 4% uses its measured phase elapsed time'
    $seconds = Get-RecentEta $job 'solve' 4 100 $clock.AddMinutes(23) $clock
    Assert ([math]::Abs($seconds-33120) -lt 1) 'a plateau longer than two minutes keeps a finite elapsed-based estimate'
    Assert ((Get-RecentEta $job 'solve' 2 100 $clock.AddMinutes(24) $clock) -lt 0) 'regressing progress resets the measurement baseline'
    Assert ((Get-RecentEta $job 'solve' 3 100 $clock.AddMinutes(27) $clock) -eq 17460) 'slow progress after a reset uses only the new baseline'
    Assert ((Get-RecentEta $job 'export' 0 1 $clock.AddMinutes(30) $clock.AddMinutes(30)) -lt 0) 'new phase starts without a guessed estimate'
    $null=Get-RecentEta $job 'export' 0.001 1 $clock.AddMinutes(31) $clock.AddMinutes(30)
    $seconds=Get-RecentEta $job 'export' 0.002 1 $clock.AddMinutes(32) $clock.AddMinutes(30)
    Assert ($seconds -gt 0) 'sub-percent export progress produces an estimate'
    Assert ((Get-RecentEta $job 'export' 1 1 $clock.AddMinutes(33) $clock.AddMinutes(30)) -eq 0) 'completion reports zero remaining'

    $script:ProgState=@{}
    $null=Get-RecentEta $job 'solve' 4 100 $clock.AddSeconds(1200) $clock
    $null=Get-RecentEta $job 'solve' 5 100 $clock.AddSeconds(1210) $clock
    $seconds=Get-RecentEta $job 'solve' 6 100 $clock.AddSeconds(1220) $clock
    Assert ($seconds -eq 940) 'three recent distinct observations prefer the local rate'
    $eigenJob = [pscustomobject]@{jobDir=$jobDir; phase='solve'; mode='solve'; solveKind='eigen'; started=$clock.ToString('o')}
    [IO.File]::WriteAllText((Join-Path $jobDir 'solve.log'),'Current progress: 4 % - active')
    $script:SolveKinds=@{}
    $eigenInfo=Get-ProgressInfo $eigenJob
    Assert ($eigenInfo.StageOnly -and $eigenInfo.Eta -lt 0) 'eigen stages do not generate an artificial ETA'

    $sweep = [pscustomobject]@{jobDir=$jobDir; phase='solve'; mode='solve'; solveKind='sweep'; started=''}
    $script:SolveMessages=@{}
    $log = Join-Path $jobDir 'solve.log'
    $solved = Join-Path $jobDir 'result.txt'
    $spec = Join-Path $jobDir 'job.properties'
    [IO.File]::WriteAllText($spec,('solvedfile='+$solved))
    [IO.File]::WriteAllLines($log,@('           当前进度:   9 % - 矩阵分解','-          当前进度:  10 % - 矩阵分解'))
    Assert ((Get-SolveLogState $sweep).Pct -eq 10) 'first COMSOL progress-bar dash at ten percent'
    [IO.File]::AppendAllLines($log,[string[]]@('参数 lambda0 = 8.19e-07。','----       当前进度:  48 % - 约束处理'))
    $info = Get-SolveLogState $sweep
    Assert ($info.Pct -eq 48 -and $info.Stage -eq '约束处理' -and $info.Param -eq 'lambda0=8.19e-07') 'public wavelength log reaches 48 percent at 819 nm'
    [IO.File]::AppendAllLines($log,[string[]]@(('x'*135168),'---------- Current progress: 100 % - Saving model','---------- Current progress: 100 % - '))
    $info = Get-SolveLogState $sweep
    Assert ($info.Pct -eq 100 -and $info.Stage -eq 'Saving model') 'English bar-only tail preserves last non-empty stage'

    $fatal = @('/***************/','/*****错误********/','/***************/','未知解。',' - 标记: all','正在保存模型: partial.mph')
    [IO.File]::WriteAllLines($log,$fatal)
    $script:SolveKinds=@{}
    $live = Get-ProgressInfo $sweep
    Assert ($live.SolveError -match '未知解。 - 标记: all' -and $live.Detail -match '求解报错' -and $live.Eta -lt 0) 'live fatal diagnostic takes precedence over ETA'
    [IO.File]::AppendAllLines($log,[string[]]@(('x'*135168),'总时间: 49 s.'))
    Assert ((Get-SolveLogState $sweep).Error -match '未知解' -and (Test-SolveOk $sweep) -eq 'solve-error' -and $sweep.solveError -match '未知解') 'long trailer and missing output preserve a legacy solve error'
    [IO.File]::WriteAllText($solved,'fixture')
    [IO.File]::WriteAllText(($solved+'.status'),'Done')
    [IO.File]::WriteAllLines($log,@('Opening file: D:\错误模型.mph','Warning: Error estimate is high','LinErr LinRes','Total time: 2 s.'))
    Assert ((Test-SolveOk $sweep) -eq '') 'old completed job accepts benign error metrics and filenames'
    [IO.File]::WriteAllText(($solved+'.status'),'Failed')
    Assert ((Test-SolveOk $sweep) -eq 'solve-error') 'failed status overrides total time and partial output'
    [IO.File]::WriteAllText(($solved+'.status'),'Done')
    $sweep | Add-Member NoteProperty solveExitExpected $true
    $exitFile=Join-Path $jobDir 'solve.exit'
    Assert ((Test-SolveOk $sweep) -eq 'solve-error' -and $sweep.solveError -match '退出码') 'new solve requires durable exit evidence'
    [IO.File]::WriteAllText($exitFile,'invalid')
    Assert ((Test-SolveOk $sweep) -eq 'solve-error') 'malformed exit evidence is rejected'
    [IO.File]::WriteAllText($exitFile,'0')
    [IO.File]::WriteAllLines((Join-Path $jobDir 'solve.err'),@('/*****Error*****/','Failed to find a solution.'))
    Assert ((Test-SolveOk $sweep) -eq 'solve-error' -and $sweep.solveError -match 'Failed to find a solution') 'explicit stderr diagnostic overrides even native exit zero and Done'
    $longException = 'java.io.FileNotFoundException: ' + ('x'*540) + ' (系统找不到指定的文件。)'
    [IO.File]::WriteAllText((Join-Path $jobDir 'solve.err'),$longException)
    Assert ((Test-SolveOk $sweep) -eq 'solve-error' -and $sweep.solveError -match '^java.io.FileNotFoundException.*系统找不到指定的文件。') 'long Java exception retains its type and trailing OS explanation'
    [IO.File]::Delete((Join-Path $jobDir 'solve.err'))
    Assert ((Test-SolveOk $sweep) -eq '') 'native success and a complete output may enter export'
    [IO.File]::WriteAllText($solved,'')
    Assert ((Test-SolveOk $sweep) -eq 'solve-no-output') 'zero-byte output never enters export'

    $start = [datetime]::UtcNow
    $job.pid=4242
    $job | Add-Member NoteProperty workerStartUtc $start.ToString('o')
    $script:worker = [pscustomobject]@{Name='java.exe';ProcessId=4242;CreationDate=$start;CommandLine=('java ExportDriver "'+(Join-Path $jobDir 'job.properties')+'"')}
    $script:testFreeKB = 16777216
    function Get-CimInstance { param($ClassName,$Filter,$ErrorAction)
        if ($ClassName -eq 'Win32_OperatingSystem') { return @{FreePhysicalMemory=$script:testFreeKB} }
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

    & {
        $handoff = [pscustomobject]@{jobDir=$jobDir; status='running'; pid=4242; phase='solve'; started=$start.ToString('o')}
        [IO.File]::WriteAllText((Join-Path $jobDir 'phase'),'export')
        function Get-JobProcIds { [pscustomobject]@{ProcessId=7474; CreationDate=$start} }
        Restore-JobWorker $handoff -OnlyTransition
        Assert ($handoff.status -eq 'running' -and $handoff.phase -eq 'export' -and $handoff.pid -eq 7474 -and
                $handoff.exportStarted) 'a second window recovers the export PID if the phase change was not committed'
    }

    $Cores=1; $Heap='5g'
    $budget=Get-ResourceBudget 9
    Assert ($budget.slots -le 2 -and $budget.slots*$budget.heapMB -le $budget.pool -and
            $budget.slots*$budget.cores -le $budget.cpu) 'shared CPU and RAM ceiling'
    $Heap=''; $Cores=0
    $single = Get-ResourceBudget 1
    if ($single.cpu -ge 2 -and $single.pool -ge 8192) {
        Assert ($single.slots -eq 1 -and $single.cores*2 -le $single.cpu -and $single.heapMB*2 -le $single.pool) 'single automatic job leaves room for another window'
    }
    $script:testFreeKB = 8388608
    $active = [pscustomobject]@{ status='running'; memoryPoolMB=$single.pool }
    $second = Get-ResourceBudget 1 @($active)
    Assert ($second.pool -lt $single.pool -and $second.cores -eq $single.cores -and
            $second.heapMB -eq $single.heapMB) 'a second window sizes automatic shares against the original pool'
    $Heap='8g'
    $queued = Get-ResourceBudget 1 @($active)
    Assert ($queued.heapMB -gt $queued.pool) 'an explicit request within the shared pool can wait for memory'
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
