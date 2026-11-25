#requires -Version 5.1
# The launcher must show the menu even when COMSOL cannot start.
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
    $config = "@{ Models = '" + $models.Replace("'", "''") + "' }"
    [IO.File]::WriteAllText((Join-Path $state 'config.psd1'), $config, [Text.Encoding]::UTF8)
    $missingBatch = Join-Path $sandbox 'missing-comsolbatch.exe'
    $launcher = Join-Path $repo 'run.bat'
    # A parent shell can pass a module path without the Windows PowerShell modules.
    $env:PSModulePath = $sandbox
    $output = '2','1','1' | & $launcher -DryRun -ComsolPath $missingBatch
    $code = $LASTEXITCODE
    $env:PSModulePath = $previousModules
    $output = $output -join [Environment]::NewLine
    $offset = 0
    foreach ($label in @('选择模式','选择模型',$modelName,'选择配方','comsolbatch 不存在')) {
        $pos = $output.IndexOf($label, $offset, [StringComparison]::Ordinal)
        if ($pos -lt 0) { throw "Missing or out of order [$label] in launcher output: $output" }
        $offset = $pos + $label.Length
    }
    if ($code -ne 1 -or [IO.File]::Exists((Join-Path $state 'queue.json'))) {
        throw 'An unusable installation must fail before enqueueing a job.'
    }
    Write-Output 'PASS redirected launcher reads the saved model path and shows both menus before checking COMSOL'

    $errors = $null
    $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'cli.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw $errors[0] }
    $probe = $ast.Find({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-DriverRuntime'
    }, $false)
    . ([scriptblock]::Create($probe.Extent.Text))
    $script:ExpectedDriverVersion = 'probe-test'
    $exe = Join-Path $sandbox 'TEMP_probe.exe'
    $code = @"
using System;
using System.Threading;
public class Probe {
    public static int Main(string[] args) {
        if (args.Length != 4 || args[0] != "-cp" || args[2] != "ExportDriver" || args[3] != "--check-runtime") return 3;
        if (Console.Read() != -1) return 4;
        if (args[1] == "timeout") Thread.Sleep(30000);
        if (args[1] == "failure") { Console.Error.WriteLine("test diagnostic"); return 9; }
        Console.WriteLine(args[1] == "wrong-version" ? "old-version" : "probe-test ready");
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
