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
    function Get-CimInstance { param($ClassName,$Filter,$ErrorAction)
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

    $env:COMSOL_EXPORT_XMX = $null
    $Heap = ''
    Assert ((Get-RequestedHeapMB) -eq 0 -and -not (Get-HeapArg ([pscustomobject]@{heapMB=0}))) 'default leaves Java heap to the JVM'
    $env:COMSOL_EXPORT_XMX='2g'
    Assert ((Get-HeapArg) -eq '-Xmx2048m') 'environment heap is explicit'
    $Heap='768m'
    Assert ((Get-HeapArg) -eq '-Xmx768m' -and (Get-HeapArg ([pscustomobject]@{heapMB=512})) -eq '-Xmx512m') 'CLI and saved job heap overrides'
    $Heap='invalid'; $caught=$false
    try { $null=Get-RequestedHeapMB } catch { $caught=$true }
    Assert $caught 'invalid explicit heap rejected'
    Assert ((Get-MemoryPool @([pscustomobject]@{status='running';memoryPoolMB=9000}) 4000) -eq 9000) 'running reservation retains its pool across windows'

    $reserve=@{}
    $a=Join-Path $sandbox '模型 A'
    [void][IO.Directory]::CreateDirectory($a)
    Assert ((Get-UnusedJobPath $sandbox '模型 A' '' $reserve -ReuseEmpty) -eq $a) 'empty model folder may be reused'
    Assert ((Get-UnusedJobPath $sandbox '模型 A' '' $reserve -ReuseEmpty) -eq ($a+' (2)')) 'in-flight path prevents a second writer'
    [IO.File]::WriteAllText((Join-Path $a 'sentinel'),'original')
    Assert ((Get-UnusedJobPath $sandbox '模型 A' '' @{} -ReuseEmpty) -eq ($a+' (2)')) 'repeat export preserves the existing model folder'
    [IO.File]::WriteAllText(($a+'.mph'),'existing')
    Assert ((Get-UnusedJobPath $sandbox '模型 A' '.mph' @{}) -eq ($a+' (2).mph')) 'existing solved model is protected'
    $orphan=Join-Path $sandbox 'orphan.mph'
    [IO.File]::WriteAllText(($orphan+'.recovery'),'recover me')
    Assert ((Get-UnusedJobPath $sandbox 'orphan' '.mph' @{}) -ne $orphan) 'a missing MPH with a recovery pointer cannot be reused'

    $oldDir=Join-Path $sandbox 'old job'
    [void][IO.Directory]::CreateDirectory($oldDir)
    $oldModel=Join-Path $sandbox '模型 [old].mph'
    [IO.File]::WriteAllText((Join-Path $oldDir 'job.properties'),('solvedfile='+$oldModel))
    [IO.File]::WriteAllText($oldModel,'stored model')
    [IO.File]::WriteAllText(($oldModel+'.status'),'Done')
    [IO.File]::WriteAllText(($oldModel+'.recovery'),'original')
    $old=[pscustomobject]@{mode='solve';jobDir=$oldDir;status='failed';resultDir=''}
    $mark=Join-Path $oldDir 'solved'
    [IO.File]::WriteAllText($mark,'')
    $end=[datetime]::UtcNow.AddSeconds(3)
    [IO.File]::SetLastWriteTimeUtc($mark,$end)
    [IO.File]::SetLastWriteTimeUtc(($oldModel+'.recovery'),$end.AddSeconds(5))
    Initialize-HandoffStates @($old) -Recover
    Assert ([IO.File]::Exists($oldModel+'.status') -and [IO.File]::Exists($oldModel+'.recovery')) 'historical recovery never claims a newer run'
    [IO.File]::SetLastWriteTimeUtc(($oldModel+'.recovery'),$end.AddSeconds(-1))
    [IO.File]::WriteAllText(($oldModel+'.status'),'Running')
    Initialize-HandoffStates @($old) -Recover
    Assert ([IO.File]::Exists($oldModel+'.recovery')) 'historical recovery keeps native interrupted recovery in place'
    [IO.File]::WriteAllText(($oldModel+'.status'),'Done')
    Initialize-HandoffStates @($old) -Recover
    Initialize-HandoffStates @($old) -Recover
    Assert (-not [IO.File]::Exists($oldModel+'.status') -and -not [IO.File]::Exists($oldModel+'.recovery') -and
        [IO.File]::ReadAllText((Join-Path $oldDir 'solve.recovery')) -ceq 'original' -and
        (Test-SolveOk $old) -eq '') 'resume archives a proven successful legacy solve once and can read its archived status'

    $base='模型_202611251125'
    $legacyName=$base+'_20261126235500_12ab34cd'
    $m=[pscustomobject]@{BaseName=$legacyName;FullName=(Join-Path $sandbox ('solved\'+$legacyName+'.mph'))}
    Assert ((Get-ResultModelName $m) -eq $base) 'known legacy solved suffix is removed from deliverable names'
    $m.BaseName='alias'
    Assert ((Get-ResultModelName $m) -eq 'alias') 'explicit shortcut alias is preserved'
    $m.BaseName=$legacyName; $m.FullName=Join-Path $sandbox ($legacyName+'.mph')
    Assert ((Get-ResultModelName $m) -eq $legacyName) 'original model name outside solved is preserved'

    $legacyBatch=Join-Path $sandbox 'output\batch_old'
    $legacyDir=Join-Path $legacyBatch 'old_job'
    $legacyJob=[pscustomobject]@{status='killed';jobDir=$jobDir;resultDir=$legacyDir;batchDir=$legacyBatch;mode='export'}
    $script:HandoffStates=@{}
    Write-Handoff @($legacyJob)
    Assert (([IO.File]::ReadAllText((Join-Path $legacyBatch 'EXPORT_MANIFEST.md'))) -match 'old_job/EXPORT_MANIFEST.md' -and
            [IO.File]::Exists((Join-Path $legacyDir 'EXPORT_MANIFEST.md'))) 'legacy queue still publishes its recorded batch and model manifests'

    & {
        function Get-BoxWidth { 76 }
        function Get-ProgressInfo($job) { $job.info }
        $script:BatchPage = 0
        $script:PStyle = '2'
        $a = @{model='A.mph'; status='running'; info=@{Phase='solve';PhaseLabel='求解';Pct=34;Eta=600;TotalElapsed=180;Detail='矩阵分解';Bg='DarkYellow';StageIdx=5}}
        $b = @{model='B.mph'; status='running'; info=@{Phase='export';PhaseLabel='导出';Pct=75;Eta=120;TotalElapsed=96;Detail='已取 3/4 个解';Bg='DarkCyan'}}
        $keys = 'Q 退出监视   K 终止作业'
        $single = New-ProgressPage @($a) 32 $keys
        $both = New-ProgressPage @($a,$b) 32 $keys
        Assert ($single.Count -eq 7 -and $both.Count -eq 14 -and
            (($both[0..6].Text -join "|").Replace('1/2','1/1') -ceq ($single.Text -join "|"))) 'two full panels use the same rows as an individual job'
        $rows = $both[7..13].Text -join '|'
        foreach ($label in '2/2   B','进度','75%','导出','已取 3/4','00:01:36','约 2 min','按键') {
            if (-not $rows.Contains($label)) { throw ("Missing panel detail " + $label + " in " + $rows) }
        }
        $script:BatchPage = 1
        $page = New-ProgressPage @($a,$b) 10 'Q 退出只读监视'
        Assert ($page.Count -eq 7 -and $page[1].Text.Contains('2/2   B') -and
                $page[5].Text.Contains('2/2') -and $page[5].Text.Contains('只读') -and $page[5].Text -notmatch '终止') 'short read-only console pages whole panels with the correct controls'
        $script:PStyle = '3'
        $both = New-ProgressPage @($a,$b) 32 $keys
        Assert (($both.Text -join '|') -match '▸分解') 'parallel solve retains the selected stage-chain style'
        $a.info.StageOnly = $true
        $both = New-ProgressPage @($a,$b) 32 $keys
        Assert ($both[2].Text -match '阶段监视' -and $both[2].Text -notmatch '%|█' -and $both[4].Text -match '剩余时间不可估') 'stage-only job keeps full panel without a guessed percentage'
    }

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
