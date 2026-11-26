#requires -Version 5.1
# Separate real CLI processes share a private queue. Both COMSOL executables are fixtures.
$ErrorActionPreference = 'Stop'
if ([Environment]::ProcessorCount -lt 2) { Write-Output 'SKIP concurrent workers require at least two cores'; return }
$repo = Split-Path -Parent $PSScriptRoot
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$box = Join-Path $tempRoot ('TEMP_comsol_windows_' + [guid]::NewGuid().ToString('N'))
$scriptDir = Join-Path $box 'script'
$models = Join-Path $box 'models'
$local = Join-Path $box 'local'
$queueFile = Join-Path $local 'comsol-export/state/queue.json'
$controllers = @()
$success = $false

function Read-Jobs {
    if (-not [IO.File]::Exists($queueFile)) { return }
    $f = [IO.File]::Open($queueFile,'Open','Read',[IO.FileShare]'ReadWrite, Delete')
    $r = [IO.StreamReader]::new($f)
    try { $r.ReadToEnd() | ConvertFrom-Json | ForEach-Object { $_ } } finally { $r.Dispose() }
}
function Start-Controller([string]$options, [switch]$Direct) {
    $si = [Diagnostics.ProcessStartInfo]::new()
    $si.WorkingDirectory = $scriptDir
    if ($Direct) {
        $si.FileName = 'powershell.exe'
        $si.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "cli.ps1" ' + $options
    } else {
        $si.FileName = $env:ComSpec
        $si.Arguments = '/d /c run.bat ' + $options
    }
    $si.UseShellExecute = $false
    $si.CreateNoWindow = $true
    $si.EnvironmentVariables['LOCALAPPDATA'] = $local
    $si.EnvironmentVariables.Remove('COMSOL_EXPORT_XMX')
    $si.RedirectStandardInput = $si.RedirectStandardOutput = $si.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($si)
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.WriteLine('1')
    $proc.StandardInput.Close()
    return @{Proc=$proc; Out=$stdout; Err=$stderr}
}
function Wait-ExitCode($ctl, [int]$code) {
    if (-not $ctl.Proc.WaitForExit(45000)) { throw 'Controller did not exit' }
    if ($ctl.Proc.ExitCode -ne $code) { throw ("Exit $($ctl.Proc.ExitCode), expected $code " + $ctl.Out.Result + $ctl.Err.Result) }
}
function Wait-State([string]$id, [string]$status, $ctl) {
    $limit = [datetime]::UtcNow.AddSeconds(45)
    do {
        $hit = @(Read-Jobs | Where-Object { $_.id -eq $id -and $_.status -eq $status })
        if ($hit.Count -eq 1) { return $hit[0] }
        if ($ctl.Proc.HasExited) { throw ("Controller exited while waiting for $id $status " + $ctl.Out.Result + $ctl.Err.Result) }
        Start-Sleep -Milliseconds 100
    } while ([datetime]::UtcNow -lt $limit)
    throw "Timed out waiting for $id $status"
}
try {
    foreach ($dir in @($scriptDir,$models,(Join-Path $scriptDir 'recipes'))) { [void][IO.Directory]::CreateDirectory($dir) }
    foreach ($rel in 'cli.ps1','run.bat','modules','driver') {
        Copy-Item -LiteralPath (Join-Path $repo $rel) -Destination $scriptDir -Recurse
    }
    $recipe = "@{ Task='test'; Study='std1'; NameTemplate='{model}'; Export=@(@{Type='global'; Name='identity'; Expr=@('1'); Cols=@('value')}) }"
    [IO.File]::WriteAllText((Join-Path $scriptDir 'recipes/test.psd1'),$recipe,[Text.Encoding]::UTF8)
    foreach ($id in 'A','B','C','D','E','F') { [IO.File]::WriteAllText((Join-Path $models ($id + '.mph')),'fixture') }

    $batch = Join-Path $box 'installation/bin/win64/comsolbatch.exe'
    $java = Join-Path $box 'installation/java/win64/jre/bin/java.exe'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($batch))
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($java))
    $source = [IO.File]::ReadAllText((Join-Path $repo 'driver/ExportDriver.java'))
    $version = [regex]::Match($source,'DRIVER_VERSION\s*=\s*"([^"]+)"').Groups[1].Value
    $worker = @"
using System;
using System.IO;
using System.Linq;
using System.Threading;
class Worker {
    static int Main(string[] a) {
        if (a.Contains("--check-runtime")) { Console.WriteLine("$version ready"); return 0; }
        bool solve = a.Contains("-inputfile");
        File.AppendAllText(solve ? "TEMP_solve_count" : "TEMP_export_count", "1");
        if (solve) {
            File.WriteAllText(a[Array.IndexOf(a,"-batchlog")+1],"Current progress: 4 % - active");
            DateTime limit = DateTime.UtcNow.AddSeconds(90);
            while (!File.Exists("TEMP_finish_solve") && DateTime.UtcNow < limit) Thread.Sleep(70);
            if (!File.Exists("TEMP_finish_solve")) return 8;
            string dest = a[Array.IndexOf(a,"-outputfile")+1];
            File.WriteAllText(dest,"fixture"); File.WriteAllText(dest+".status","Done");
            if (Path.GetFileName(a[Array.IndexOf(a,"-inputfile")+1]) == "D.mph") return 17;
        } else {
            File.WriteAllText("started","test");
            string dir = File.ReadAllLines("job.properties").First(x => x.StartsWith("resultdir=")).Substring(10);
            Directory.CreateDirectory(dir);
            string name = File.ReadAllLines("job.properties").First(x => x.StartsWith("outname=")).Substring(8);
            File.WriteAllText(Path.Combine(dir,name + ".csv"),"fixture");
            File.WriteAllText(Path.Combine(dir,"EXPORT_MANIFEST.md"),"fixture");
            File.WriteAllText("exported","ok");
        }
        return 0;
    }
}
"@
    Add-Type -TypeDefinition $worker -OutputAssembly $java -OutputType ConsoleApplication
    [IO.File]::Copy($java,$batch)
    $common = '-ComsolPath "'+$batch+'" -Models "..\models" -Recipe test -Mode solve -ModelIndex '
    $share = ' -Cores 1 -Heap 64m'

    $a = Start-Controller ($common + '1' + $share) -Direct
    $controllers += $a
    $b = Start-Controller ($common + '2' + $share)
    $controllers += $b
    $ja = Wait-State 'A' 'running' $a
    $jb = Wait-State 'B' 'running' $b
    if ($ja.pid -eq $jb.pid -or $ja.cores+$jb.cores -gt [Environment]::ProcessorCount -or
        $ja.heapMB+$jb.heapMB -gt $ja.memoryPoolMB) { throw 'Concurrent workers exceed their pool or share a PID' }

    $c = Start-Controller ($common + '3 -Heap 64m -Cores ' + [Environment]::ProcessorCount)
    $controllers += $c
    $jc = Wait-State 'C' 'pending' $c
    $duplicate = Start-Controller ($common + '1')
    $controllers += $duplicate
    Wait-ExitCode $duplicate 1
    if (@(Read-Jobs).Count -ne 3) { throw 'Concurrent submissions were lost or duplicated' }
    Write-Output 'PASS two windows run different solve workers concurrently and a full-CPU request remains queued'

    $a.Proc.Kill(); $a.Proc.WaitForExit()
    $resume = Start-Controller ('-ComsolPath "' + $batch + '" -Resume')
    $controllers += $resume
    $stop = Start-Controller ('-KillJob "' + (Split-Path -Leaf $jb.jobDir) + '"')
    $controllers += $stop
    Wait-ExitCode $stop 0
    Wait-ExitCode $b 4
    if ((Wait-State 'A' 'running' $resume).pid -ne $ja.pid) { throw 'Resuming replaced the first worker' }
    [IO.File]::WriteAllText((Join-Path $ja.jobDir 'TEMP_finish_solve'),'ok')
    [IO.File]::WriteAllText((Join-Path $jc.jobDir 'TEMP_finish_solve'),'ok')
    Wait-ExitCode $c 0
    if (-not $resume.Proc.WaitForExit(45000)) { throw 'Resume timed out' }
    if ($resume.Proc.ExitCode -notin @(0,4)) { throw ('Resume failed ' + $resume.Out.Result + $resume.Err.Result) }
    $jobs = @(Read-Jobs | Sort-Object id)
    if (($jobs.status -join ',') -ne 'done,killed,done') { throw ('Unexpected terminal queue ' + ($jobs.status -join ',')) }
    foreach ($j in $jobs) {
        if ([IO.File]::ReadAllText((Join-Path $j.jobDir 'TEMP_solve_count')) -ne '1') { throw 'Solve launched more than once' }
        if ($j.status -eq 'done' -and [IO.File]::ReadAllText((Join-Path $j.jobDir 'TEMP_export_count')) -ne '1') { throw 'Export launched more than once' }
    }
    $stats = [IO.File]::ReadAllText((Join-Path $local 'comsol-export/state/stats.json')) | ConvertFrom-Json
    if ($stats.exported -ne 2) { throw 'Concurrent completions miscounted' }
    Write-Output 'PASS closing one window, overlapping resume, targeted cancel, once-only exports and persistent final states'
    $d = Start-Controller ($common + '4 -Heap 64m -Cores 1') -Direct
    $controllers += $d
    $jd = Wait-State 'D' 'running' $d
    $d.Proc.Kill(); $d.Proc.WaitForExit()
    [IO.File]::WriteAllText((Join-Path $jd.jobDir 'TEMP_finish_solve'),'ok')
    $exitFile = Join-Path $jd.jobDir 'solve.exit'
    $limit = [datetime]::UtcNow.AddSeconds(20)
    while (-not [IO.File]::Exists($exitFile) -and [datetime]::UtcNow -lt $limit) { Start-Sleep -Milliseconds 80 }
    if ([IO.File]::ReadAllText($exitFile) -ne '17') { throw 'Native failure was lost after closing the controller' }
    $resumeD = Start-Controller ('-ComsolPath "' + $batch + '" -Resume')
    $controllers += $resumeD
    Wait-ExitCode $resumeD 3
    $failed = @(Read-Jobs | Where-Object id -eq 'D')[0]
    $manifest = [IO.File]::ReadAllText((Join-Path $failed.resultDir 'EXPORT_MANIFEST.md'))
    if ($failed.status -ne 'failed' -or $failed.exitcode -ne 'solve-error' -or $failed.solveExitCode -ne 17 -or
        $manifest -notmatch 'comsolbatch 退出码 17' -or [IO.File]::Exists((Join-Path $jd.jobDir 'TEMP_export_count'))) {
        throw 'Nonzero solver exit was accepted as a completed job'
    }
    Write-Output 'PASS native exit 17 persists with no controller and blocks export despite a saved partial result and Done'
    $plain = Start-Controller ($common + '5,6')
    $controllers += $plain
    $je = Wait-State 'E' 'running' $plain
    $jf = Wait-State 'F' 'running' $plain
    $output = Join-Path $box 'output'
    foreach ($j in $je,$jf) {
        if ($j.resultDir -ne (Join-Path $output $j.id) -or $j.solvedFile -ne (Join-Path $models ('solved\'+$j.id+'.mph'))) {
            throw 'Unexpected result or solved model name'
        }
        if ([IO.File]::ReadAllText((Join-Path $j.jobDir 'launch-solve.txt')) -match '(?:^|\s)-np\s') { throw 'Default solver cores overridden' }
        [IO.File]::WriteAllText((Join-Path $j.jobDir 'TEMP_finish_solve'),'ok')
    }
    Wait-ExitCode $plain 0
    foreach ($j in $je,$jf) {
        if ([IO.File]::ReadAllText((Join-Path $j.jobDir 'launch.txt')) -match '-Xmx|-XX:ActiveProcessorCount' -or
            -not [IO.File]::Exists((Join-Path $j.resultDir 'EXPORT_MANIFEST.md'))) { throw 'Default export limits or handoff incorrect' }
    }
    Write-Output 'PASS two default solve/export workers overlap, keep plain names and inherit CPU/heap defaults'
    $legacyModels=Join-Path $box 'legacy\solved'
    [void][IO.Directory]::CreateDirectory($legacyModels)
    $friendly='模型_202611251125'
    foreach ($tail in '20261126081530_12abcd88','20261126082530_face11aa') {
        [IO.File]::WriteAllText((Join-Path $legacyModels ($friendly+'_'+$tail+'.mph')),'fixture')
    }
    $legacy=Start-Controller ('-ComsolPath "'+$batch+'" -Models "'+$legacyModels+'" -Recipe test -Mode export -ModelIndex a')
    $controllers+=$legacy
    Wait-ExitCode $legacy 0
    $exports=@(Read-Jobs | Where-Object { $_.model.StartsWith($legacyModels) })
    if ($exports.Count -ne 2) { throw 'Expected two saved models' }
    foreach ($folder in $friendly,($friendly+' (2)')) {
        $dest=Join-Path $output $folder
        if (-not [IO.File]::Exists((Join-Path $dest ($friendly+'.csv'))) -or
            @(Get-ChildItem -LiteralPath $dest -Directory).Count) { throw 'Legacy IDs or nesting in new output' }
    }
    Write-Output 'PASS two legacy solved inputs with the same readable name export without IDs or overwriting each other'
    $success = $true
} finally {
    # Release any fixture worker on assertion failure without touching other processes.
    foreach ($j in @(Read-Jobs)) {
        if ([IO.Directory]::Exists($j.jobDir)) { [IO.File]::WriteAllText((Join-Path $j.jobDir 'TEMP_finish_solve'),'cleanup') }
    }
    foreach ($ctl in $controllers) {
        if (-not $ctl.Proc.HasExited) { [void]$ctl.Proc.WaitForExit(8000) }
        $ctl.Proc.Dispose()
    }
    $target = [IO.Path]::GetFullPath($box)
    if ([IO.Path]::GetDirectoryName($target) -eq $tempRoot.TrimEnd('\') -and [IO.Path]::GetFileName($target) -like 'TEMP_comsol_windows_*') {
        if ($success) { Remove-Item -LiteralPath $target -Recurse -Force } else { Write-Warning "Test evidence: $target" }
    }
}
