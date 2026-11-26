#requires -Version 5.1
param([Parameter(Mandatory)][string]$LaunchFile)

# Keep the native exit code available to a controller that attaches after COMSOL exits.
$ErrorActionPreference = 'Stop'
$dir = [IO.Path]::GetDirectoryName($LaunchFile)
$proc = $stdout = $stderr = $null
try {
    $info = [Diagnostics.ProcessStartInfo]::new()
    foreach ($line in [IO.File]::ReadAllLines($LaunchFile)) {
        if ($line.StartsWith('comsolbatch=')) { $info.FileName = $line.Substring(12) }
        if ($line.StartsWith('args=')) { $info.Arguments = $line.Substring(5) }
    }
    $info.WorkingDirectory = $dir
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $share = [IO.FileShare]'Read, Delete'
    $stdout = [IO.FileStream]::new((Join-Path $dir 'solve.out'),'Create','Write',$share,1)
    $stderr = [IO.FileStream]::new((Join-Path $dir 'solve.err'),'Create','Write',$share,1)
    if ([IO.File]::Exists((Join-Path $dir 'killed'))) { return }
    $proc = [Diagnostics.Process]::Start($info)
    $proc.StandardInput.Close()
    $outCopy = $proc.StandardOutput.BaseStream.CopyToAsync($stdout)
    $errCopy = $proc.StandardError.BaseStream.CopyToAsync($stderr)
    $proc.WaitForExit()
    [Threading.Tasks.Task]::WaitAll(@($outCopy,$errCopy))
    $stdout.Flush()
    $stderr.Flush()
    $marker = Join-Path $dir 'solve.exit'
    [IO.File]::WriteAllText(($marker + '.tmp'),[string]$proc.ExitCode)
    [IO.File]::Move(($marker + '.tmp'),$marker)
} catch {
    [IO.File]::WriteAllText((Join-Path $dir 'solve.monitor-error'),$_.Exception.GetBaseException().Message)
    exit 1
} finally {
    foreach ($resource in @($proc,$stdout,$stderr)) { if ($resource) { $resource.Dispose() } }
}
