#requires -Version 5.1
# Check startup ordering with an isolated installation and a synthetic Java probe.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$sandbox = Join-Path $tempRoot ('TEMP_comsol_menu_' + [guid]::NewGuid().ToString('N'))
$previousLocal = $env:LOCALAPPDATA
$previousModules = $env:PSModulePath
$previousEncoding = [Console]::OutputEncoding
try {
    $env:LOCALAPPDATA = $sandbox
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $models = Join-Path $sandbox '私有模型目录'
    $state = Join-Path $sandbox 'comsol-export/state'
    [IO.Directory]::CreateDirectory($models) | Out-Null
    [IO.Directory]::CreateDirectory($state) | Out-Null
    $modelName = 'TEMP_模型列表.mph'
    [IO.File]::WriteAllBytes((Join-Path $models $modelName), [byte[]]@())
    $errors = $null
    $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'cli.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw $errors[0] }
    foreach ($name in @('Assert-DriverRuntime', 'Get-DriverClassVersion')) {
        $definition = $ast.Find({param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $false)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $script:ExpectedDriverVersion = Get-DriverClassVersion (Join-Path $repo 'driver')
    if (-not $script:ExpectedDriverVersion) { throw 'Missing driver version for the probe fixture.' }
    $install = Join-Path $sandbox 'COMSOL test'
    $batch = Join-Path $install 'bin\win64\comsolbatch.exe'
    $exe = Join-Path $install 'java\win64\jre\bin\java.exe'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($batch)) | Out-Null
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($exe)) | Out-Null
    [IO.File]::WriteAllBytes($batch, [byte[]]@())
    $code = @"
using System;
using System.Threading;
public class Probe {
    public static int Main(string[] args) {
        if (args.Length != 4 || args[0] != "-cp" || args[2] != "ExportDriver" || args[3] != "--check-runtime") return 3;
        // Windows PowerShell may put an encoding preamble on the closed pipe.
        using (var input = new System.IO.StreamReader(Console.OpenStandardInput(), System.Text.Encoding.UTF8, true)) {
            if (input.Read() != -1) { Console.Error.WriteLine("probe received menu input"); return 4; }
        }
        if (args[1] == "timeout") Thread.Sleep(30000);
        if (args[1] == "failure") { Console.Error.WriteLine("test diagnostic"); return 9; }
        bool broken = System.IO.File.Exists(System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "TEMP_bad_driver"));
        Console.WriteLine(args[1] == "wrong-version" || broken ? "old-version" : "$script:ExpectedDriverVersion ready");
        return 0;
    }
}
"@
    Add-Type -TypeDefinition $code -OutputAssembly $exe -OutputType ConsoleApplication
    Assert-DriverRuntime $exe 'path with spaces;plugins\*'
    $expected = @{failure='退出码 9.*test diagnostic'; 'wrong-version'='old-version'; timeout='预检超时'}
    foreach ($case in @('failure', 'wrong-version', 'timeout')) {
        $timeout = if ($case -eq 'timeout') { 500 } else { 5000 }
        $message = ''
        try { Assert-DriverRuntime $exe $case $timeout } catch { $message = $_.Exception.Message }
        if ($message -notmatch $expected[$case]) { throw "Unexpected $case diagnostic [$message]" }
    }
    Write-Output 'PASS driver probe receives closed stdin, accepts matching versions, reports failures and times out'

    $config = "@{ Models = '" + $models.Replace("'", "''") + "'; ComsolBatch = '" + $batch.Replace("'", "''") + "' }"
    [IO.File]::WriteAllText((Join-Path $state 'config.psd1'), $config, [Text.Encoding]::UTF8)
    $launcher = Join-Path $repo 'run.bat'
    # A parent shell can pass a module path without the Windows PowerShell modules.
    $env:PSModulePath = $sandbox
    $output = ('2','1','1' | & $launcher -DryRun) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) { throw "Preview failed: $output" }
    $offset = 0
    foreach ($label in @('正在检查 COMSOL 安装', '正在检查 COMSOL 导出驱动', '选择模式', '选择模型', $modelName, '选择配方', '预览：共 1 个作业')) {
        $pos = $output.IndexOf($label, $offset, [StringComparison]::Ordinal)
        if ($pos -lt 0) { throw "Missing or out of order [$label] in launcher output: $output" }
        $offset = $pos + $label.Length
    }
    if ([regex]::Matches($output, '正在检查 COMSOL 导出驱动').Count -ne 1 -or $output -match '正在找 COMSOL') {
        throw "Saved installation was not used exactly once: $output"
    }
    Write-Output 'PASS saved installation and driver checked once before mode, model, and recipe menus'

    $missingBatch = Join-Path $sandbox 'missing-comsolbatch.exe'
    [IO.File]::WriteAllText((Join-Path ([IO.Path]::GetDirectoryName($exe)) 'TEMP_bad_driver'), '')
    foreach ($path in @($missingBatch, $batch)) {
        $output = ('' | & $launcher -DryRun -ComsolPath $path) -join [Environment]::NewLine
        $expectedError = if ($path -eq $missingBatch) { 'comsolbatch 不存在' } else { '驱动预检失败.*old-version' }
        if ($LASTEXITCODE -ne 1 -or $output -notmatch $expectedError -or $output -match '选择模式|选择模型|选择配方') {
            throw "Expected a startup failure before any job menu: $output"
        }
    }
    if ([IO.File]::Exists((Join-Path $state 'queue.json'))) { throw 'Startup checks enqueued a job.' }
    Write-Output 'PASS missing installation and incompatible driver both fail before the first job menu'
} finally {
    $env:PSModulePath = $previousModules
    $env:LOCALAPPDATA = $previousLocal
    [Console]::OutputEncoding = $previousEncoding
    $target = [IO.Path]::GetFullPath($sandbox)
    if ([IO.Path]::GetDirectoryName($target) -eq $tempRoot.TrimEnd('\') -and
        [IO.Path]::GetFileName($target) -like 'TEMP_comsol_menu_*' -and [IO.Directory]::Exists($target)) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}
