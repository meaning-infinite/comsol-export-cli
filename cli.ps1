#requires -Version 5.1
<#
  COMSOL 远程自动导出 CLI  -  阶段 1：只预览，不启动任何计算

  用法:
    run.bat                     交互选择模型与配方
    run.bat -Setup              配置 COMSOL 路径 / 并发 / 模型目录
    run.bat -DryRun             只打印计划，不写队列
    run.bat -Models "D:\x\models" -Recipe ITO-LN-ITO -ModelIndex 1 -DryRun
    run.bat -Help

  配方 recipes\*.psd1 字段:
    Task         任务名，用于命名模板的 {task}
    Study        要跑的研究 tag
    Sweep        全局参数字典，值为数组，驱动按笛卡尔积逐组计算
    Lambda       波长生成规则 Param/From/Step/To，表达式可引用 Sweep 参数
    NameTemplate 产物命名模板，{字段} 由 Sweep 参数 + Lambda 端点 + {task}/{stamp} 回填
    Export       导出块数组，Type 为分派键: global / table / field / image
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Resume,
    [string]$Models,
    [string]$Recipe,
    [string]$ModelIndex = '',
    [string]$ComsolPath,
    [ValidateSet('solve','export','')]
    [string]$Mode = '',
    [int]$KillJob = 0,
    [switch]$Setup,
    [switch]$Help
)

trap {
    Write-Host ''
    Write-Host ('  错误: ' + $_.Exception.Message) -ForegroundColor Red
    if ($Host.Name -eq 'ConsoleHost') { Read-Host '  按回车关闭' | Out-Null }
    exit 1
}


$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------------- 界面：框线工具 ----------------
function Get-TextWidth([string]$s) {
    $w = 0
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
    }
    return $w
}
function Pad-Text([string]$s, [int]$w) {
    if ($null -eq $s) { $s = '' }
    $n = $w - (Get-TextWidth $s)
    if ($n -lt 0) { $n = 0 }
    return $s + (' ' * $n)
}
function Get-BoxLines([string]$title, [string[]]$lines) {
    $w = 0
    foreach ($l in $lines) { if ($null -ne $l) { $w = [math]::Max($w, (Get-TextWidth $l) + 2) } }
    $tw = Get-TextWidth (' ' + $title + ' ')
    $w = [math]::Max($w, $tw + 2)
    $out = @('┌' + '─ ' + $title + ' ' + ('─' * ($w - 1 - $tw)) + '┐')
    foreach ($l in $lines) { $out += ('│ ' + (Pad-Text $l ($w - 1)) + '│') }
    $out += ('└' + ('─' * $w) + '┘')
    return $out
}
function Write-Box([string]$title, [string[]]$lines, [string]$color = 'Cyan') {
    foreach ($l in (Get-BoxLines $title $lines)) { Write-Host ('  ' + $l) -ForegroundColor $color }
}
function Write-BoxRows([string]$title, $rows, [string]$border = 'Cyan') {
    $texts = @($rows | ForEach-Object { [string]$_.Text })
    $w = 0
    foreach ($l in $texts) { $w = [math]::Max($w, (Get-TextWidth $l) + 2) }
    $tw = Get-TextWidth (' ' + $title + ' ')
    $w = [math]::Max($w, $tw + 2)
    Write-Host ('  ┌─ ' + $title + ' ' + ('─' * ($w - 1 - $tw)) + '┐') -ForegroundColor $border
    foreach ($r in $rows) { Write-Host ('  │ ' + (Pad-Text ([string]$r.Text) ($w - 1)) + '│') -ForegroundColor $r.Color }
    Write-Host ('  └' + ('─' * $w) + '┘') -ForegroundColor $border
}

# 原地刷新的活动框：LiveTop=-1 表示还没画过
$script:LiveTop = -1
$script:LiveCount = 0
$script:LiveSig = ''
$script:IsRedirected = $false
try { $script:IsRedirected = [Console]::IsOutputRedirected } catch { }
function Show-LiveBox([string]$title, [string[]]$lines, [string]$color) {
    $all = @(Get-BoxLines $title $lines)
    if ($script:IsRedirected) {
        # 输出被重定向（无人值守/日志）：只在阶段或内容变化时打一行，不刷屏
        if ($title -ne $script:LiveSig) {
            $script:LiveSig = $title
            Write-Host ('  [' + $title + '] ' + ($lines -join '   '))
        }
        return
    }
    try {
        if ($script:LiveTop -lt 0) {
            Write-Host ''
            foreach ($l in $all) { Write-Host ('  ' + $l) -ForegroundColor $color }
            $script:LiveCount = $all.Count
            $script:LiveTop = [Console]::CursorTop - $all.Count
        } else {
            $bw = [math]::Max(20, [Console]::BufferWidth - 1)
            $safeTop = [math]::Min($script:LiveTop, [math]::Max(0, [Console]::BufferHeight - $all.Count - 1))
            [Console]::SetCursorPosition(0, $safeTop)
            foreach ($l in $all) { Write-Host (('  ' + $l).PadRight($bw)) -ForegroundColor $color }
            [Console]::SetCursorPosition(0, $safeTop + $all.Count)
            $script:LiveTop = $safeTop
        }
    } catch {
        if ($title -ne $script:LiveSig) {
            $script:LiveSig = $title
            Write-Host ('  [' + $title + '] ' + ($lines -join '   '))
        }
    }
}
function Show-StatusLine([string]$text, [string]$fg, [string]$bg) {
    if ($script:IsRedirected) {
        $sig = ($text -replace '[0-9]{2}:[0-9]{2}:[0-9]{2}', '')
        if ($sig -ne $script:LiveSig) { $script:LiveSig = $sig; Write-Host ('  ' + $text) }
        return
    }
    $bw = 98
    try { $bw = [math]::Max(40, [Console]::WindowWidth - 2) } catch { }
    $line = '▌ ' + $text + ' '
    for ($n = 0; $n -lt 200 -and (Get-TextWidth $line) -gt ($bw - 2) -and $line.Length -gt 2; $n++) {
        $line = $line.Substring(0, $line.Length - 1)
    }
    $padN = $bw - 1 - (Get-TextWidth $line)
    if ($padN -lt 0) { $padN = 0 }
    $out = $line + (' ' * $padN) + '▐'
    try { Write-Host ("`r" + $out) -NoNewline -ForegroundColor $fg -BackgroundColor $bg } catch { }
}

function Clear-LiveBox {
    try {
        if ($script:LiveTop -ge 0) {
            $bw = [math]::Max(20, [Console]::BufferWidth - 1)
            for ($y = 0; $y -lt $script:LiveCount; $y++) {
                [Console]::SetCursorPosition(0, $script:LiveTop + $y)
                Write-Host (''.PadRight($bw))
            }
            [Console]::SetCursorPosition(0, $script:LiveTop)
        }
    } catch { }
    $script:LiveTop = -1
}


$ScriptDir = $PSScriptRoot
$Root      = Split-Path -Parent $ScriptDir
$StoreDir  = Join-Path $env:LOCALAPPDATA 'comsol-export'
$StateDir  = Join-Path $StoreDir 'state'
$JobsDir = Join-Path $ScriptDir 'logs'
$RecipeDir = Join-Path $ScriptDir 'recipes'
$QueueFile = Join-Path $StateDir 'queue.json'
$ConfigFile = Join-Path $StateDir 'config.psd1'
# 首次运行时状态目录可能不存在，先建出来，否则写配置/队列会报
# Could not find a part of the path ...\state\config.psd1
try {
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
} catch { }
$Stamp     = Get-Date -Format 'yyyyMMddHHmm'

function Show-Help {
    Write-Host ''
    Write-Host '  COMSOL 远程自动导出 CLI (阶段 1: 预览)' -ForegroundColor Cyan
    Write-Host '  ------------------------------------------------------'
    Write-Host '  模型目录默认: <根目录>\model    配方目录: script\recipes'
    Write-Host ''
    Write-Host '  参数:'
    Write-Host '    -Models <dir>    模型目录'
    Write-Host '    -Recipe <name>   直接指定配方（不交互）'
    Write-Host '    -ModelIndex <n>  直接指定第 n 个模型（从 1 开始）'
    Write-Host '    -DryRun          只打印计划，不写队列、不启动计算'
    Write-Host '    -Help            显示本帮助'
    Write-Host ''
    Write-Host '  配方字段: Task / Study / NameTemplate / Export'
    Write-Host '  Export 块 Type: global | spectrum | image | eigenslice'
    Write-Host ''
}

function Get-ModelFiles {
    # 支持 .mph 与指向 .mph 的快捷方式（.lnk）；快捷方式只取目标路径，显示仍用 .lnk 的名字
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { throw "模型目录不存在: $Dir" }
    $items = @()
    foreach ($f in (Get-ChildItem -LiteralPath $Dir | Where-Object { -not $_.PSIsContainer } | Sort-Object Name)) {
        if ($f.Extension -eq '.mph') {
            $items += [pscustomobject]@{
                Name = $f.Name; FullName = $f.FullName
                BaseName = $f.BaseName; IsLink = $false
            }
        }
        elseif ($f.Extension -eq '.lnk') {
            $target = ''
            try {
                $ws = New-Object -ComObject WScript.Shell
                $target = $ws.CreateShortcut($f.FullName).TargetPath
            } catch { $target = '' }
            if ($target -and (Test-Path -LiteralPath $target) -and ([System.IO.Path]::GetExtension($target) -eq '.mph')) {
                $base = $f.BaseName -replace '\s*-\s*快捷方式$', ''
                $items += [pscustomobject]@{
                    Name = $f.Name; FullName = $target; BaseName = $base; IsLink = $true
                }
            }
        }
    }
    return @($items)
}

function Get-Recipes {
    if (-not (Test-Path -LiteralPath $RecipeDir)) { throw "配方目录不存在: $RecipeDir" }
    $out = @()
    foreach ($f in (Get-ChildItem -LiteralPath $RecipeDir -Filter *.psd1 | Where-Object { -not $_.PSIsContainer } | Sort-Object Name)) {
        try {
            $data = Import-PowerShellDataFile -LiteralPath $f.FullName
        } catch {
            throw ('配方无法解析: ' + $f.Name + '（多为编码问题，用记事本另存为 UTF-8 带 BOM）')
        }
        $out += [pscustomobject]@{
            Name = $f.BaseName
            Path = $f.FullName
            Data = $data
        }
    }
    if ($out.Count -eq 0) { throw "配方目录里没有 .psd1: $RecipeDir" }
    return $out
}

function Expand-Sweep {
    param($Sweep)
    if ($null -eq $Sweep -or $Sweep.Count -eq 0) { return @(@{}) }
    $result = @(@{})
    foreach ($k in @($Sweep.Keys)) {
        $next = @()
        foreach ($base in $result) {
            foreach ($v in @($Sweep[$k])) {
                $h = @{}
                foreach ($bk in $base.Keys) { $h[$bk] = $base[$bk] }
                $h[$k] = $v
                $next += $h
            }
        }
        $result = @($next)
    }
    return $result
}

function Invoke-Arith {
    param([string]$Expr, [hashtable]$Vars)
    if ([string]::IsNullOrWhiteSpace($Expr)) { throw 'Lambda 表达式为空' }
    $names = @($Vars.Keys)
    # 配方里写 1.735*sim_xy-6 即可，这里自动补 $ 前缀
    foreach ($n in $names) {
        $Expr = [regex]::Replace($Expr, '(?<![\$\w])' + [regex]::Escape($n) + '\b', '$' + $n)
    }
    $head  = 'param(' + (($names | ForEach-Object { '$' + $_ }) -join ',') + ') '
    $sb    = [scriptblock]::Create($head + $Expr)
    $vals  = @($names | ForEach-Object { $Vars[$_] })
    return (& $sb @vals)
}

function Get-LambdaList {
    param($Lambda, [hashtable]$Combo)
    if ($null -eq $Lambda) { return @() }
    $from = [double](Invoke-Arith $Lambda.From $Combo)
    $step = [double](Invoke-Arith $Lambda.Step $Combo)
    $to   = [double](Invoke-Arith $Lambda.To   $Combo)
    if ($step -le 0)   { throw 'Lambda.Step 必须为正数' }
    if ($to -lt $from) { throw 'Lambda.To 小于 Lambda.From' }
    $n = [int][math]::Floor(($to - $from) / $step + 1e-9) + 1
    return @(0..($n - 1) | ForEach-Object { [math]::Round($from + $_ * $step, 6) })
}

function Format-JobName {
    param([string]$Template, [hashtable]$Map)
    $name = [regex]::Replace($Template, '\{(\w+)\}', {
        param($m)
        $k = $m.Groups[1].Value
        if ($Map.ContainsKey($k)) { return [string]$Map[$k] }
        return $m.Value
    })
    if ($name -match '\{(\w+)\}') { throw ('命名模板含未知字段: ' + $Matches[0]) }
    return $name
}

function Read-Choice {
    param([string]$Prompt, [int]$Max)
    while ($true) {
        $s = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($s)) { return 1 }
        $n = 0
        if ([int]::TryParse($s, [ref]$n) -and $n -ge 1 -and $n -le $Max) { return $n }
        Write-Host ('  请输入 1-{0}' -f $Max) -ForegroundColor Yellow
    }
}

function Write-ScanLog([string]$msg) {
    if (-not $script:ScanLog) {
        try {
            $d = Join-Path $ScriptDir 'logs'
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            $script:ScanLog = Join-Path $d ('setup_scan_' + (Get-Date -Format 'yyyyMMdd') + '.log')
        } catch { return }
    }
    try { Add-Content -LiteralPath $script:ScanLog -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $msg) -Encoding UTF8 } catch { }
}

function Get-DesktopDirs {
    $d = @()
    try { $d += [Environment]::GetFolderPath('Desktop') } catch { }
    try { $d += [Environment]::GetFolderPath('DesktopDirectory') } catch { }
    if ($env:USERPROFILE) { $d += (Join-Path $env:USERPROFILE 'Desktop'); $d += (Join-Path $env:USERPROFILE 'OneDrive\Desktop') }
    if ($env:PUBLIC) { $d += (Join-Path $env:PUBLIC 'Desktop') }
    return @($d | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Get-ComsolFromShortcuts {
    $found = @{}
    $sh = $null
    try { $sh = New-Object -ComObject WScript.Shell } catch {
        Write-ScanLog 'COM(WScript.Shell) 不可用，跳过快捷方式'
        return @()
    }
    foreach ($dir in (Get-DesktopDirs)) {
        if (-not (Test-Path -LiteralPath $dir)) { Write-ScanLog ('跳过不存在的桌面: ' + $dir); continue }
        $lnks = @()
        try { $lnks = @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer }) } catch { }
        Write-ScanLog ('桌面 ' + $dir + ' : ' + $lnks.Count + ' 个快捷方式')
        foreach ($lnk in $lnks) {
            $target = ''
            try { $target = $sh.CreateShortcut($lnk.FullName).TargetPath } catch { continue }
            if ([string]::IsNullOrWhiteSpace($target)) { continue }
            if ($target -notmatch 'COMSOL') { continue }
            $parent = Split-Path -Parent $target
            foreach ($c in @((Join-Path $parent 'comsolbatch.exe'), (Join-Path (Split-Path -Parent $parent) 'comsolbatch.exe'))) {
                if (Test-Path -LiteralPath $c) { $found[$c] = $c; Write-ScanLog ('  快捷方式命中: ' + $lnk.Name + ' -> ' + $c); break }
            }
        }
    }
    return @($found.Values | Sort-Object)
}

function Read-Config {
    $cfg = @{ ComsolBatch = ''; MaxParallel = 1; Models = '' }
    if (Test-Path -LiteralPath $ConfigFile) {
        try {
            $c = Import-PowerShellDataFile -LiteralPath $ConfigFile
            foreach ($k in @('ComsolBatch', 'MaxParallel', 'Models')) {
                if ($null -ne $c[$k]) { $cfg[$k] = $c[$k] }
            }
        } catch { }
    }
    return $cfg
}

function Save-Config {
    param([hashtable]$Cfg)
    $cfgDir = Split-Path -Parent $ConfigFile
    if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
    $lines = @(
        '@{',
        ('    ComsolBatch  = ' + "'" + $Cfg.ComsolBatch + "'"),
        ('    MaxParallel = ' + $Cfg.MaxParallel),
        ('    Models      = ' + "'" + $Cfg.Models + "'"),
        '}'
    )
    try {
        Set-Content -LiteralPath $ConfigFile -Value $lines -Encoding UTF8
    } catch {
        throw ('写配置失败: ' + $ConfigFile + ' —— ' + $_.Exception.Message)
    }
}

function Start-Setup {
    while ($true) {
        $cfg = Read-Config
        $md = if ([string]::IsNullOrWhiteSpace($cfg.Models)) { '<默认: <根目录>\model>' } else { $cfg.Models }
        Write-Host ''
        Write-Host ('  配置: ' + $ConfigFile) -ForegroundColor Cyan
        Write-Host ('    [1] COMSOL   : ' + $cfg.ComsolBatch)
        Write-Host ('    [2] 并发数   : ' + $cfg.MaxParallel)
        Write-Host ('    [3] 模型目录 : ' + $md)
        Write-Host '    [4] 重新扫描 COMSOL 安装'
        Write-Host '    [5] 退出'
        $s = Read-Host '  选择'
        switch ($s) {
            '1' {
                $all = @(Find-Comsol)
                $all = @($all | Sort-Object -Unique)
                if ($all.Count -eq 0) { Write-Host '  没扫到，直接输入完整路径' -ForegroundColor Yellow; $cfg.ComsolBatch = Read-Host '  路径'; Save-Config $cfg; continue }
                for ($i = 0; $i -lt $all.Count; $i++) { Write-Host ('    [{0}] {1}' -f ($i + 1), $all[$i]) }
                $n = Read-Choice '  选择' $all.Count
                $cfg.ComsolBatch = $all[$n - 1]
                Save-Config $cfg
            }
            '2' {
                $v = Read-Host '  并发数 (1 = 排队串行)'
                $n = 0
                if ([int]::TryParse($v, [ref]$n) -and $n -ge 1) { $cfg.MaxParallel = $n; Save-Config $cfg }
            }
            '3' {
                $v = Read-Host '  模型目录（留空=根目录\model）'
                $cfg.Models = $v.Trim()
                Save-Config $cfg
            }
            '4' {
                $all = @(Find-Comsol)
                $all = @($all | Sort-Object -Unique)
                Write-Host ('  扫到 {0} 个:' -f $all.Count) -ForegroundColor Cyan
                foreach ($a in $all) { Write-Host ('    ' + $a) }
            }
            '5' { return }
        }
    }
}

function Get-ComsolFromRegistry {
    $found = @{}
    foreach ($k in @('HKLM:\SOFTWARE\COMSOL', 'HKLM:\SOFTWARE\WOW6432Node\COMSOL')) {
        if (-not (Test-Path $k)) { Write-ScanLog ('注册表无: ' + $k); continue }
        $vers = @()
        try { $vers = @(Get-ChildItem -Path $k -ErrorAction SilentlyContinue) } catch { }
        foreach ($ver in $vers) {
            $d = ''
            try { $d = (Get-ItemProperty -Path $ver.PSPath -Name InstallDir -ErrorAction SilentlyContinue).InstallDir } catch { }
            if ([string]::IsNullOrWhiteSpace($d)) { continue }
            foreach ($sub in @('bin\win64\comsolbatch.exe', 'Multiphysics\bin\win64\comsolbatch.exe')) {
                $exe = Join-Path $d $sub
                if (Test-Path -LiteralPath $exe) { $found[$exe] = $exe; Write-ScanLog ('  注册表命中: ' + $exe) }
            }
        }
    }
    return @($found.Values | Sort-Object)
}

function Get-ComsolFromDisk {
    $found = @{}
    $drives = @()
    try {
        foreach ($dv in [System.IO.DriveInfo]::GetDrives()) {
            if ($dv.IsReady -and $dv.DriveType -eq [System.IO.DriveType]::Fixed) { $drives += $dv.RootDirectory.FullName }
        }
    } catch { }
    if ($drives.Count -eq 0) { $drives = @('C:\', 'D:\', 'E:\') }
    $roots = @($drives) + @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)
    $roots = @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique)
    $subs = @('Multiphysics\bin\win64\comsolbatch.exe', 'bin\win64\comsolbatch.exe')
    foreach ($root in $roots) {
        $dirs = @()
        try { $dirs += @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^COMSOL' }) } catch { }
        foreach ($pf in @('Program Files', 'Program Files (x86)', 'Apps', 'Software')) {
            $pfp = Join-Path $root $pf
            if (-not (Test-Path -LiteralPath $pfp)) { continue }
            try { $dirs += @(Get-ChildItem -LiteralPath $pfp -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^COMSOL' }) } catch { }
        }
        foreach ($d in $dirs) {
            foreach ($s in $subs) { $exe = Join-Path $d.FullName $s; if (Test-Path -LiteralPath $exe) { $found[$exe] = $exe } }
            $vs = @()
            try { $vs = @(Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^COMSOL' }) } catch { }
            foreach ($v in $vs) {
                foreach ($s in $subs) { $exe = Join-Path $v.FullName $s; if (Test-Path -LiteralPath $exe) { $found[$exe] = $exe } }
            }
        }
    }
    return @($found.Values | Sort-Object)
}

function Find-Comsol {
    param([switch]$Quiet)
    $all = @{}
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $steps = @(
        @('桌面快捷方式', { Get-ComsolFromShortcuts }),
        @('注册表',       { Get-ComsolFromRegistry }),
        @('磁盘常见位置', { Get-ComsolFromDisk })
    )
    foreach ($st in $steps) {
        if (-not $Quiet) { Write-Host ('    扫描 ' + $st[0] + ' ...') -NoNewline }
        $t0 = [Diagnostics.Stopwatch]::StartNew()
        $r = @()
        try { $r = @(& $st[1]) } catch { Write-ScanLog ($st[0] + ' 异常: ' + $_.Exception.Message) }
        $t0.Stop()
        foreach ($x in $r) { $all[$x] = $x }
        if (-not $Quiet) { Write-Host (' ' + $r.Count + ' 个 / ' + [int]$t0.Elapsed.TotalMilliseconds + ' ms') }
        Write-ScanLog ($st[0] + ': ' + $r.Count + ' 个 / ' + [int]$t0.Elapsed.TotalMilliseconds + ' ms' + (@($r) -join '; '))
    }
    $sw.Stop()
    if (-not $Quiet) { Write-Host ('    共 ' + $all.Count + ' 个，用时 ' + [int]$sw.Elapsed.TotalSeconds + ' s') -ForegroundColor DarkGray }
    return @($all.Values | Sort-Object)
}

function Resolve-Comsol {
    param([string]$Override)
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        if (-not (Test-Path -LiteralPath $Override)) { throw ('comsolbatch 不存在: ' + $Override) }
        return $Override
    }
    if (Test-Path -LiteralPath $ConfigFile) {
        try {
            $c = Import-PowerShellDataFile -LiteralPath $ConfigFile
            if ($c.ComsolBatch -and (Test-Path -LiteralPath $c.ComsolBatch)) { return $c.ComsolBatch }
        } catch { }
    }
    Write-Host ''
    Write-Host '  第一次在这台机器上运行，正在找 COMSOL ...' -ForegroundColor Cyan
    $all = @(Find-Comsol)
    $pick = ''
    if ($all.Count -eq 0) {
        Write-Host ''
        Write-Host '  没找到 comsolbatch.exe。' -ForegroundColor Yellow
        Write-Host ('  扫描日志: ' + (Join-Path $ScriptDir ('logs\setup_scan_' + (Get-Date -Format 'yyyyMMdd') + '.log')))
        Write-Host '  常见原因: COMSOL 装在非常规目录、或桌面快捷方式指向的不是 COMSOL。'
        $p = Read-Host '  粘贴 comsolbatch.exe 完整路径（留空=退出）'
        if ([string]::IsNullOrWhiteSpace($p)) { throw '没找到 comsolbatch.exe' }
        $p = $p.Trim().Trim('"')
        if (-not (Test-Path -LiteralPath $p)) { throw ('路径不存在: ' + $p) }
        $pick = $p
    } elseif ($all.Count -eq 1) {
        $pick = $all[0]
        Write-Host ('  使用: ' + $pick) -ForegroundColor Green
    } else {
        Write-Host '  找到多个版本，选一个（记在本机配置里，不随 script 外传）:' -ForegroundColor Yellow
        for ($i = 0; $i -lt $all.Count; $i++) { Write-Host ('    [{0}] {1}' -f ($i + 1), $all[$i]) }
        $n = Read-Choice '  版本序号' $all.Count
        $pick = $all[$n - 1]
    }
    $cfg = Read-Config
    $cfg.ComsolBatch = $pick
    Save-Config $cfg
    return $pick
}

function Get-Queue {
    if (-not (Test-Path -LiteralPath $QueueFile)) { return @() }
    $raw = Get-Content -LiteralPath $QueueFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @($raw | ConvertFrom-Json | ForEach-Object { $_ })
}


# ---------------- 作业状态 ----------------

function Test-JobAlive($procId, $jobDir) {
    if (-not $procId) { return $false }
    $p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $procId) -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    if ($p.Name -ne 'java.exe') { return $false }
    if ($p.CommandLine -notlike '*ExportDriver*') { return $false }
    return ($p.CommandLine -like ('*' + $jobDir + '*'))
}

function Get-JobStates {
    $res = @()
    if (-not (Test-Path -LiteralPath $JobsDir)) { return $res }
    $q = @(Get-Queue)
    foreach ($d in (Get-ChildItem -LiteralPath $JobsDir | Where-Object { $_.PSIsContainer })) {
        $dir = $d.FullName
        $mExported  = Test-Path -LiteralPath (Join-Path $dir 'exported')
        $mSolved    = Test-Path -LiteralPath (Join-Path $dir 'solved')
        $mExporting = Test-Path -LiteralPath (Join-Path $dir 'exporting')
        if (-not ($mExported -or $mSolved -or $mExporting)) { continue }
        $entry = $q | Where-Object { $_.jobDir -eq $dir } | Select-Object -First 1
        $alive = $false
        if ($entry) { $alive = Test-JobAlive $entry.pid $dir }
        $mKilled = Test-Path -LiteralPath (Join-Path $dir 'killed')
        if ($mExported)      { $state = '已导出'; $color = 'Green' }
        elseif ($mKilled)    { $state = '已终止'; $color = 'Red' }
        elseif ($alive)      {
            $isExportMode = ($entry -and [string]$entry.mode -eq 'export')
            if ($mExporting -or $isExportMode) { $state = '导出中'; $color = 'Cyan' } else { $state = '求解中'; $color = 'Yellow' }
        }
        else                 { $state = '断开';   $color = 'Red' }
        $res += [pscustomobject]@{ Name = $d.Name; Dir = $dir; State = $state; Color = $color; Exported = $mExported; Entry = $entry }
    }
    return $res
}

function Start-JobDriver($dir) {
    $spec = Join-Path $dir 'job.properties'
    if (-not (Test-Path -LiteralPath $spec)) { throw ('作业缺少 job.properties: ' + $dir) }
    $csPath = Resolve-Comsol $ComsolPath
    $rootNow = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $csPath))
    $javaNow = Join-Path $rootNow 'java\win64\jre\bin\java.exe'
    $cpNow   = (Join-Path $rootNow 'plugins\*') + ';' + (Join-Path $ScriptDir 'driver')
    $logNow  = Join-Path $dir 'driver.log'
    $inner = '"' + $javaNow + '" -Xmx4g -cp "' + $cpNow + '" ExportDriver "' + $spec + '" > "' + $logNow + '" 2>&1'
    $proc = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ('cmd.exe /c "' + $inner + '"') }
    if ($proc.ReturnValue -ne 0) { throw ('启动失败, 返回码 ' + $proc.ReturnValue) }
    return $proc.ProcessId
}

# ---------------- 主流程 ----------------


if ($Help) { Show-Help; exit 0 }
if ($Setup) { Start-Setup; exit 0 }

if ([string]::IsNullOrWhiteSpace($Models)) {
    $cfgTmp = Read-Config
    if ([string]::IsNullOrWhiteSpace($cfgTmp.Models)) {
        $Models = Join-Path $Root 'models'
        if (-not (Test-Path -LiteralPath $Models)) { $Models = Join-Path $Root 'model' }
    }
    else { $Models = $cfgTmp.Models }
}
# 配置里存的是旧的单数 model 时，若同级已有 models 目录，以 models 为准
if ($Models -and ((Split-Path -Leaf $Models) -eq 'model')) {
    $sib = Join-Path (Split-Path -Parent $Models) 'models'
    if (Test-Path -LiteralPath $sib) { $Models = $sib }
}


$jobs = @(Get-JobStates)
if ($jobs.Count -gt 0) {
    Write-Host ''
    $rows = @()
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        $rows += [pscustomobject]@{ Text = ('[{0}] {1,-4}  {2}' -f ($i + 1), $jobs[$i].State, $jobs[$i].Name); Color = $jobs[$i].Color }
    }
    Write-BoxRows '已有作业（可重跑导出）' $rows
    $broken = @($jobs | Where-Object { -not $_.Exported })
    if ($broken.Count -gt 0) {
        $pick = Read-Host '  重跑某个作业的导出? 输入序号, 回车跳过'
        if ($pick -match '^\d+$') {
            $idx = [int]$pick
            if ($idx -ge 1 -and $idx -le $jobs.Count) {
                $pidNew = Start-JobDriver $jobs[$idx - 1].Dir
                Write-Host ('  已启动导出 (PID ' + $pidNew + ')：' + $jobs[$idx - 1].Name) -ForegroundColor Green
            }
        }
    }
    Write-Host ''
}
$head = @(
    ('模型目录 : ' + $Models),
    ('配方目录 : ' + $RecipeDir)
)
if ($DryRun) { $head += '模式     : 预览（不启动计算、不写队列）' }
Write-Box 'COMSOL 远程自动导出 CLI' $head 'Cyan'
$ModelList = $modelList

function Save-Queue($q) {
    $jsonText = ConvertTo-Json -InputObject @($q) -Depth 6
    $qDir = Split-Path -Parent $QueueFile
    if (-not (Test-Path -LiteralPath $qDir)) { New-Item -ItemType Directory -Path $qDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($QueueFile, $jsonText, (New-Object System.Text.UTF8Encoding($false)))
}

function Clear-JobLock($job) {
    # 四道闸：路径 → 活进程 → 时序 → 原子改名
    $modelPath = [string]$job.model
    if ([string]::IsNullOrWhiteSpace($modelPath)) { return '无模型路径' }
    $targets = @($modelPath, [System.IO.Path]::ChangeExtension($modelPath, $null))
    $lockPath = $modelPath + '.lock'
    if (-not (Test-Path -LiteralPath $lockPath)) { return '无锁' }
    # 闸 1：只处理本作业记录的模型（由 $lockPath 构造保证）
    # 闸 2：有活进程命令行含该模型就保留
    $alive = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($modelPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($alive.Count -gt 0) { return '有进程占用，保留' }
    # 闸 3：锁文件必须晚于本作业启动，否则不是自己写的
    $started = $null
    if ($job.started) { try { $started = [datetime]::Parse([string]$job.started) } catch { } }
    $lt = (Get-Item -LiteralPath $lockPath).LastWriteTime
    if ($started -and $lt -lt $started.AddMinutes(-1)) { return '锁早于作业启动，保留' }
    # 闸 4：先改名成功才删
    $stale = $lockPath + '.stale-' + [string]$job.pid
    try { Move-Item -LiteralPath $lockPath -Destination $stale -ErrorAction Stop }
    catch { return '改名失败，保留' }
    Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue
    return '已清除'
}

function Start-OneJob($job) {
    $logFile = Join-Path $job.jobDir 'driver.log'
    $errFile = Join-Path $job.jobDir 'driver.err'
    $cp = (Join-Path $comsolRoot 'plugins\*') + ';' + $driverDir
    $argStr = '-Xmx4g -Dfile.encoding=UTF-8 -Dsun.stdout.encoding=UTF-8 -Dsun.stderr.encoding=UTF-8 -cp "' + $cp + '" ExportDriver "' + (Join-Path $job.jobDir 'job.properties') + '"'
    # 启动前把实际用的路径写进 launch.txt，出问题能查
    $launchInfo = @(
        'time=' + (Get-Date).ToString('o'),
        'java=' + $javaExe,
        'java_exists=' + (Test-Path -LiteralPath $javaExe),
        'cp=' + $cp,
        'args=' + $argStr,
        'jobdir=' + $job.jobDir
    ) -join "`r`n"
    try {
        [System.IO.File]::WriteAllText((Join-Path $job.jobDir 'launch.txt'), $launchInfo, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    if (-not (Test-Path -LiteralPath $javaExe)) {
        $job.status = 'failed'
        Set-JobProp $job 'exitcode' 'no-java'
        return
    }
    try {
        $proc = Start-Process -FilePath $javaExe -ArgumentList $argStr `
                              -RedirectStandardOutput $logFile -RedirectStandardError $errFile `
                              -WindowStyle Hidden -WorkingDirectory $job.jobDir -PassThru
    } catch {
        try { Add-Content -LiteralPath (Join-Path $job.jobDir 'launch.txt') -Value ('start-error=' + $_.Exception.Message) -Encoding UTF8 } catch { }
        Set-JobProp $job 'exitcode' 'launch-error'
        $job.status = 'failed'
        return
    }
    $job.pid = $proc.Id
    $job.started = (Get-Date).ToString('o')
    $job.status = 'running'
}

function Stop-OneJob($job) {
    # 只终止本 CLI 启动、且命令行能对上作业目录的那一个进程（含子进程）
    if (-not (Test-JobAlive $job.pid $job.jobDir)) { return '进程已不在（可能已自行结束）' }
    $p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $job.pid) -ErrorAction SilentlyContinue
    if (-not $p) { return '进程已不在（可能已自行结束）' }
    $cmd = [string]$p.CommandLine
    if ($p.Name -ne 'java.exe' -or $cmd -notlike '*ExportDriver*' -or $cmd -notlike ('*' + $job.jobDir + '*')) {
        return '进程身份与本作业不符，已拒绝终止'
    }
    & taskkill.exe /PID $job.pid /T /F | Out-Null
    Start-Sleep -Milliseconds 400
    if (Test-JobAlive $job.pid $job.jobDir) { return '终止失败，进程仍在（可看任务管理器确认）' }
    $job.status = 'killed'
    $marker = Join-Path $job.jobDir 'killed'
    [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
    $note = Clear-JobLock $job
    return ('已终止；模型锁: ' + $note)
}

function Invoke-KillMenu {
    $q = @(Get-Queue)
    $run = @($q | Where-Object { $_.status -eq 'running' -and (Test-JobAlive $_.pid $_.jobDir) })
    Write-Host ''
    if ($run.Count -eq 0) {
        Write-Host '  当前没有”本 CLI 启动且仍在运行”的作业，无法终止。' -ForegroundColor Yellow
        return
    }
    Write-Host '  可终止的作业（只包含本 CLI 启动的）:' -ForegroundColor Cyan
    for ($j = 0; $j -lt $run.Count; $j++) {
        Write-Host ('    [{0}] {1}   PID {2}' -f ($j + 1), (Split-Path -Leaf $run[$j].jobDir), $run[$j].pid)
    }
    $pick = Read-Host '  终止哪个? 输入序号（直接回车取消）'
    if ([string]::IsNullOrWhiteSpace($pick)) { Write-Host '  已取消。'; return }
    $n = 0
    if (-not ([int]::TryParse($pick.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $run.Count)) {
        Write-Host '  序号无效，已取消。' -ForegroundColor Yellow
        return
    }
    $job = $run[$n - 1]
    $yn = Read-Host ('  确认终止 ' + (Split-Path -Leaf $job.jobDir) + ' ?（只终止这一个，Y/N）')
    if ($yn -notmatch '^(y|Y)') { Write-Host '  已取消。'; return }
    $msg = Stop-OneJob $job
    $qq = @(Get-Queue)
    foreach ($x in $qq) { if ($x.jobDir -eq $job.jobDir) { $x.status = $job.status } }
    Save-Queue $qq
    Write-Host ('  ' + $msg) -ForegroundColor Yellow
}

function Set-JobProp($job, $name, $value) {
    if ($job.PSObject.Properties[$name]) { $job.$name = $value }
    else { $job | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }
}

function Get-StatsPath { return (Join-Path $StateDir 'stats.json') }

function Read-Stats {
    $f = Get-StatsPath
    $o = @{ exported = 0 }
    if (Test-Path -LiteralPath $f) {
        try {
            $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $j.exported) { $o.exported = [int]$j.exported }
        } catch { }
    }
    return $o
}

function Add-Stat($key, $delta) {
    $f = Get-StatsPath
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $o = Read-Stats
    $o[$key] = [int]$o[$key] + [int]$delta
    $json = ConvertTo-Json -InputObject $o -Depth 3
    [System.IO.File]::WriteAllText($f, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-MedianSeconds($model) {
    # 用历史完成耗时估个“预计总时长”，只用于显示进度条，不参与任何判定
    $q = @(Get-Queue)
    $ds = @($q | Where-Object { $_.duration -and ([string]$_.model) -eq ([string]$model) } | ForEach-Object { [double]$_.duration })
    if ($ds.Count -lt 1) { $ds = @($q | Where-Object { $_.duration } | ForEach-Object { [double]$_.duration }) }
    if ($ds.Count -lt 1) { return 180.0 }
    $s = @($ds | Sort-Object)
    $m = [int][math]::Floor($s.Count / 2)
    if ($s.Count % 2 -eq 1) { return [double]$s[$m] }
    return (([double]$s[$m - 1] + [double]$s[$m]) / 2.0)
}

function Get-JobDisplay($job) {
    # 阶段 + 估算百分比（按历史耗时线性外推，仅提示用）
    if (Test-Path -LiteralPath (Join-Path $job.jobDir 'exported')) { return [pscustomobject]@{ Stage = '完成'; Pct = 100; Elapsed = 0; Left = 0 } }
    $stage = '求解中'
    if ([string]$job.mode -eq 'export') { $stage = '导出中' }
    if (Test-Path -LiteralPath (Join-Path $job.jobDir 'exporting')) { $stage = '导出中' }
    $started = $null
    if ($job.started) { try { $started = [datetime]::Parse([string]$job.started) } catch { } }
    if (-not $started) { return [pscustomobject]@{ Stage = $stage; Pct = 0; Elapsed = 0; Left = 0 } }
    $el = ((Get-Date) - $started).TotalSeconds
    $exp = Get-MedianSeconds $job.model
    $pct = [int][math]::Round(100.0 * $el / [math]::Max(1.0, $exp))
    if ($pct -gt 99) { $pct = 99 }
    if ($stage -eq '导出中') { $pct = 99 }
    $left = [math]::Max(0, $exp - $el)
    return [pscustomobject]@{ Stage = $stage; Pct = $pct; Elapsed = $el; Left = $left; Expected = $exp }
}

function Format-Elapsed($ts) {
    $t = [timespan]::FromSeconds([math]::Max(0, [double]$ts))
    return ('{0:00}:{1:00}:{2:00}' -f [int]$t.TotalHours, $t.Minutes, $t.Seconds)
}


function Invoke-Scheduler {
    $script:LiveSig = ''
    $script:LiveTop = -1
    $spin = '|/-\'
    $i = 0
    $t0 = Get-Date
    $sessionIds = @((Get-Queue) | Where-Object { $_.status -eq 'pending' -or $_.status -eq 'running' } | ForEach-Object { $_.jobDir })
    $total = $sessionIds.Count
    if ($total -eq 0) {
        $st0 = Read-Stats
        Write-Host ('  队列里没有未完成的作业。历史累计导出 ' + $st0.exported + ' 个。') -ForegroundColor DarkCyan
        return
    }
    while ($true) {
        $quitMonitor = $false
        while ($true) {
            $q = @(Get-Queue)
            foreach ($job in $q) {
                if ($job.status -eq 'running') {
                    if (Test-Path -LiteralPath (Join-Path $job.jobDir 'exported')) {
                        $job.status = 'done'
                        if (-not (Test-Path -LiteralPath (Join-Path $job.jobDir 'counted'))) {
                            [System.IO.File]::WriteAllText((Join-Path $job.jobDir 'counted'), '', (New-Object System.Text.UTF8Encoding($false)))
                            Add-Stat 'exported' 1
                        }
                        if ($job.started) {
                            try {
                                $dur = [int](((Get-Date) - [datetime]::Parse([string]$job.started)).TotalSeconds)
                                if ($dur -ge 1) { Set-JobProp $job 'duration' $dur }
                            } catch { }
                        }
                        $note = Clear-JobLock $job
                        if ($note -eq '已清除') { Write-Host ("`n  已释放锁: " + $job.model) -ForegroundColor DarkGray }
                    }
                    elseif (-not (Test-JobAlive $job.pid $job.jobDir)) {
                        # 进程刚退出时文件可能还在落盘，等一拍再判
                        Start-Sleep -Milliseconds 300
                        if (Test-Path -LiteralPath (Join-Path $job.jobDir 'exported')) {
                            # 留给下一拍走"已导出"分支
                        } elseif (Test-Path -LiteralPath (Join-Path $job.jobDir 'killed')) {
                            $job.status = 'killed'
                        } else {
                            $job.status = 'failed'
                            $code = '?'
                            $ef = Join-Path $job.jobDir 'exit'
                            if (Test-Path -LiteralPath $ef) {
                                try { $code = ([string](Get-Content -LiteralPath $ef -Raw)).Trim() } catch { }
                            } elseif (-not (Test-Path -LiteralPath (Join-Path $job.jobDir 'started'))) {
                                $code = 'no-start'
                            }
                            Set-JobProp $job 'exitcode' $code
                        }
                    }
                }
            }
            $running = @($q | Where-Object { $_.status -eq 'running' })
            $pending = @($q | Where-Object { $_.status -eq 'pending' })
            $slots = [int]$MaxParallel - $running.Count
            if ($slots -lt 1 -and $pending.Count -gt 0 -and $running.Count -eq 0) { $slots = 1 }
            while ($slots -gt 0 -and $pending.Count -gt 0) {
                Start-OneJob $pending[0]
                $pending = @($pending | Select-Object -Skip 1)
                $slots--
            }
            Save-Queue $q

            $running = @($q | Where-Object { $_.status -eq 'running' })
            $open = @($q | Where-Object { $_.status -eq 'pending' -or $_.status -eq 'running' })
            $mine = @($q | Where-Object { $sessionIds -contains $_.jobDir })
            $fin = @($mine | Where-Object { $_.status -eq 'done' -or $_.status -eq 'failed' -or $_.status -eq 'killed' })
            $el = (Get-Date) - $t0

            $cur = @($running | Where-Object { $sessionIds -contains $_.jobDir })
            if ($cur.Count -gt 0) {
                $job = $cur[0]
                $ord = [array]::IndexOf($sessionIds, $job.jobDir) + 1
                $d = Get-JobDisplay $job
                $nm = [string](Split-Path -Leaf $job.jobDir)
                if ($nm.Length -gt 24) { $nm = $nm.Substring(0, 24) }
                if ($d.Stage -eq '导出中') { $fg = 'Black'; $bg = 'DarkCyan' }
                elseif ($d.Stage -eq '求解中') { $fg = 'Black'; $bg = 'DarkYellow' }
                else { $fg = 'White'; $bg = 'DarkGray' }
                $body = ('【' + $d.Stage + '】作业 ' + $ord + '/' + [math]::Max(1, $total) + ' · ' + $nm + ' · 已用 ' + (Format-Elapsed $d.Elapsed) + ' · Q 退出监视  K 终止作业')
                Show-StatusLine $body $fg $bg
            } else {
                $body = ('【调度中】已完成 ' + $fin.Count + '/' + [math]::Max(1, $total) + ' · 已用 ' + (Format-Elapsed $el.TotalSeconds) + ' · Q 退出监视  K 终止作业')
                Show-StatusLine $body 'White' 'DarkGray'
            }

            if ($i % 10 -eq 0) {
                try {
                    if ($cur.Count -gt 0) {
                        $dT = Get-JobDisplay $cur[0]
                        $Host.UI.RawUI.WindowTitle = ('【' + $dT.Stage + '】' + (Split-Path -Leaf $cur[0].jobDir) + ' - COMSOL 导出')
                    } else {
                        $Host.UI.RawUI.WindowTitle = ('【调度中 ' + $fin.Count + '/' + [math]::Max(1, $total) + '】COMSOL 导出')
                    }
                } catch { }
            }

            if ($open.Count -eq 0) { break }

            try {
                if ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq 'Q') { $quitMonitor = $true; break }
                    if ($k.Key -eq 'K') { Write-Host ''; Invoke-KillMenu; Write-Host '' }
                }
            } catch { }
            Start-Sleep -Milliseconds 500
            $i++
        }
        Write-Host ''
        $q = @(Get-Queue)
        $mine = @($q | Where-Object { $sessionIds -contains $_.jobDir })
        foreach ($job in $mine) {
            $leaf = Split-Path -Leaf $job.jobDir
            if ($job.status -eq 'done') {
                $dur = ''
                if ($job.duration) { $dur = '  用时 ' + (Format-Elapsed $job.duration) }
                Write-Host ('  [完成] ' + $leaf + $dur) -ForegroundColor Green
            } elseif ($job.status -eq 'failed') {
                $code = [string]$job.exitcode
                $ev = @()
                foreach ($m in @('started','exit','exported','killed','launch.txt')) {
                    $mp = Join-Path $job.jobDir $m
                    if (Test-Path -LiteralPath $mp) { $ev += ($m + '=有') } else { $ev += ($m + '=无') }
                }
                foreach ($m in @('driver.log','driver.err')) {
                    $mp = Join-Path $job.jobDir $m
                    if (Test-Path -LiteralPath $mp) { $ev += ($m + '=' + (Get-Item -LiteralPath $mp).Length + 'B') } else { $ev += ($m + '=无') }
                }
                Write-Host ('      现场: ' + ($ev -join '  ')) -ForegroundColor DarkGray
                if ($code -eq 'no-start') {
                    Write-Host ('  [失败] ' + $leaf + '  Java 没起来（作业文件在，驱动没写过任何标记）') -ForegroundColor Red
                } elseif ($code -eq '0') {
                    Write-Host ('  [失败] ' + $leaf + '  退出码 0 但没有 exported 标记，导出未完成') -ForegroundColor Red
                } elseif ($code -eq 'no-java') {
                    Write-Host ('  [失败] ' + $leaf + '  找不到 Java：' + $javaExe) -ForegroundColor Red
                } elseif ($code -eq 'launch-error') {
                    Write-Host ('  [失败] ' + $leaf + '  启动进程失败（见 launch.txt 的 start-error）') -ForegroundColor Red
                } elseif ($code -eq '?') {
                    Write-Host ('  [失败] ' + $leaf + '  驱动启动了(started 有)但没有写 exit —— Java 崩溃或被外部杀掉') -ForegroundColor Red
                } else {
                    Write-Host ('  [失败] ' + $leaf + '  退出码 ' + $code) -ForegroundColor Red
                }
                foreach ($f in @('driver.err', 'driver.log')) {
                    $fp = Join-Path $job.jobDir $f
                    if (-not (Test-Path -LiteralPath $fp)) { continue }
                    $tail = @(Get-Content -LiteralPath $fp -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() -ne '' -and $_ -notmatch '^\s+at ' } | Select-Object -Last 3)
                    foreach ($ln in $tail) { Write-Host ('      ' + $f + ': ' + $ln.Trim()) -ForegroundColor DarkGray }
                }
            } elseif ($job.status -eq 'killed') {
                Write-Host ('  [已终止] ' + $leaf + '  由本 CLI 手动终止') -ForegroundColor Red
            } elseif ($job.status -eq 'running') {
                Write-Host ('  [仍在计算] ' + $leaf + '  背后进程未受影响，重开时加 -Resume 可继续监视') -ForegroundColor Yellow
            } elseif ($job.status -eq 'pending') {
                Write-Host ('  [等待中] ' + $leaf) -ForegroundColor Yellow
            }
        }
        $stats = Read-Stats
        $okN = @($mine | Where-Object { $_.status -eq 'done' }).Count
        Write-Box '本次汇总' @(
            ('本次作业 ' + $mine.Count + ' 个（完成 ' + $okN + ' 个）'),
            ('历史累计导出 ' + $stats.exported + ' 个')
        ) 'DarkCyan'
        Save-Queue $q
        try { $Host.UI.RawUI.WindowTitle = 'COMSOL 导出 CLI' } catch { }
        if (-not $quitMonitor) { break }
        Write-Host ''
        $again = Read-Host '  按 M 重新进入监视，直接回车退出（后台计算不受影响）'
        if ($again -notmatch '^[mM]$') { break }
        Write-Host ''
    }
}

$MaxParallel = [int](Read-Config).MaxParallel
if ($MaxParallel -lt 1) { $MaxParallel = 1 }
$comsolBatch = Resolve-Comsol $ComsolPath
Write-Host ('  COMSOL   : ' + $comsolBatch)
Write-Host ''

# ---- 单实例守卫：两个 CLI 同时调度会抢同一个队列（-KillJob 除外，它是显式急停） ----
$instFile = Join-Path $StateDir 'cli.lock'
if ($KillJob -le 0) {
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    if (Test-Path -LiteralPath $instFile) {
        $oldPid = 0
        try { $oldPid = [int]((Get-Content -LiteralPath $instFile -Raw).Trim()) } catch { }
        if ($oldPid -gt 0 -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
            Write-Host ('  另一个 CLI 正在运行（PID ' + $oldPid + '），为避免两个调度器抢同一个队列，本窗口退出。') -ForegroundColor Yellow
            Write-Host '  要看进度请回到那个窗口；确认它已关闭后再启动本程序。'
            exit 0
        }
    }
    [System.IO.File]::WriteAllText($instFile, [string]$PID, (New-Object System.Text.UTF8Encoding($false)))
}

$comsolRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $comsolBatch))
$javaExe    = Join-Path $comsolRoot 'java\win64\jre\bin\java.exe'
if (-not (Test-Path -LiteralPath $javaExe)) { throw ('找不到 Java: ' + $javaExe) }
$driverDir  = Join-Path $ScriptDir 'driver'
if (-not (Test-Path -LiteralPath (Join-Path $driverDir 'ExportDriver.class'))) {
    throw ('驱动未编译，先运行: comsolcompile ' + (Join-Path $driverDir 'ExportDriver.java'))
}

if ($KillJob -gt 0) {
    $q = @(Get-Queue)
    if ($KillJob -gt $q.Count) { throw ('队列里只有 ' + $q.Count + ' 个作业，没有第 ' + $KillJob + ' 个') }
    $target = $q[$KillJob - 1]
    Write-Host ('  目标: ' + (Split-Path -Leaf $target.jobDir) + '   PID ' + $target.pid) -ForegroundColor Yellow
    $msg = Stop-OneJob $target
    foreach ($x in $q) { if ($x.jobDir -eq $target.jobDir) { $x.status = $target.status } }
    Save-Queue $q
    Write-Host ('  ' + $msg)
    exit 0
}

if ($Resume) {
    Write-Host ''
    Write-Host '  接着跑队列里未完成的作业（已关掉的计算不会被杀）' -ForegroundColor Cyan
    Invoke-Scheduler
    Remove-Item -LiteralPath $instFile -Force -ErrorAction SilentlyContinue
    exit 0
}


# 模式：先决定这次是“求解+导出”还是“只导出已有解的模型”
$doSolve = $true
if ($Mode -eq 'export') { $doSolve = $false }
elseif ($Mode -eq 'solve') { $doSolve = $true }
elseif ([string]::IsNullOrWhiteSpace($ModelIndex)) {
    Write-Host ''
    $rows = @(
        [pscustomobject]@{ Text = '[1] 求解并导出（模型还没算过）'; Color = 'Gray' },
        [pscustomobject]@{ Text = '[2] 只导出（模型里已经有解，不重新求解）'; Color = 'Gray' }
    )
    Write-BoxRows '选择模式' $rows
    $mv = Read-Host '  模式序号（直接回车=1）'
    if ($mv -match '^\s*2\s*$') { $doSolve = $false }
}

$modelFiles = @(Get-ModelFiles $Models)
if ($modelFiles.Count -eq 0) { throw "目录里没有 .mph 或指向 .mph 的快捷方式: $Models" }

$miRaw = [string]$ModelIndex
$shown = $false
$idxs = @()
while ($true) {
    if (-not $shown) {
        $rows = @()
        for ($i = 0; $i -lt $modelFiles.Count; $i++) {
            $label = $modelFiles[$i].Name
            if ($modelFiles[$i].IsLink) { $label = $label + '  →  ' + [System.IO.Path]::GetFileName($modelFiles[$i].FullName) }
            $rows += [pscustomobject]@{ Text = ('[{0}] {1}' -f ($i + 1), $label); Color = 'Gray' }
        }
        Write-BoxRows '选择模型' $rows
        $shown = $true
    }
    if ([string]::IsNullOrWhiteSpace($miRaw)) {
        $miRaw = Read-Host '  选择模型序号（直接回车=1，多个用逗号，a=全部）'
        if ([string]::IsNullOrWhiteSpace($miRaw)) { $miRaw = '1' }
    }
    $idxs = @()
    if ($miRaw -match '^\s*a\s*$') { $idxs = @(1..$modelFiles.Count) }
    else {
        foreach ($piece in ($miRaw -split ',')) {
            $n = 0
            if ([int]::TryParse($piece.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $modelFiles.Count) { $idxs += $n }
        }
    }
    if ($idxs.Count -gt 0) { break }
    if (-not [string]::IsNullOrWhiteSpace($ModelIndex)) { throw ('模型序号无效: ' + $ModelIndex) }
    Write-Host ('  序号无效：“' + $miRaw + '”，请输入 1-' + $modelFiles.Count + '，多个用逗号，a=全部') -ForegroundColor Yellow
    $miRaw = ''
}
$modelList = @($idxs | ForEach-Object { $modelFiles[$_-1] })
$model = $modelList[0]

$recipes = @(Get-Recipes)
if (-not [string]::IsNullOrWhiteSpace($Recipe)) {
    $hit = @($recipes | Where-Object { $_.Name -eq $Recipe })
    if ($hit.Count -eq 0) {
        throw ('找不到配方: ' + $Recipe + '（可选: ' + (($recipes | ForEach-Object { $_.Name }) -join ', ') + '）')
    }
    $r = $hit[0]
} else {
    Write-Host ''
    $rows = @()
    for ($i = 0; $i -lt $recipes.Count; $i++) {
        $rows += [pscustomobject]@{ Text = ('[{0}] {1}' -f ($i + 1), $recipes[$i].Name); Color = 'Gray' }
    }
    Write-BoxRows '选择配方' $rows
    $ri = Read-Choice '  选择配方序号' $recipes.Count
    $r = $recipes[$ri - 1]
}

$cfg = $r.Data
if (-not $cfg.NameTemplate) { throw ('配方缺少 NameTemplate: ' + $r.Name) }

$jobs = @()
foreach ($m in $ModelList) {
    $n = Format-JobName $cfg.NameTemplate @{ task = [string]$cfg.Task; model = $m.BaseName; stamp = $Stamp }
    New-Item -ItemType Directory -Path $JobsDir -Force | Out-Null
    $jobDir = Join-Path $JobsDir ($Stamp + '_' + $m.BaseName)
    New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
    $outDir = Join-Path $Root 'output'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    $spec = New-Object System.Collections.Generic.List[string]
    $spec.Add('model='    + $m.FullName)
    $spec.Add('study='    + $cfg.Study)
    $spec.Add('outdir='   + $outDir)
    $spec.Add('modelsdir=' + $Models)
    $spec.Add('outname='  + $n)
    $spec.Add('blocks='   + $cfg.Export.Count)
    $spec.Add('solve='    + $(if ($doSolve) { '1' } else { '0' }))
    for ($i = 0; $i -lt $cfg.Export.Count; $i++) {
        $b = $cfg.Export[$i]
        $k = $i + 1
        # 通用：任何额外字段都原样写入 job.properties（小写键），
        # 这样新增导出类型不需要再改这里
        foreach ($key in $b.Keys) {
            $val = $b[$key]
            if ($null -eq $val) { continue }
            if ($val -is [array]) { $val = ($val -join '|') }
            $name = ([string]$key).ToLowerInvariant()
            if ($name -eq 'type' -or $name -eq 'name') { $val = [string]$val }
            $spec.Add('block.' + $k + '.' + $name + '=' + [string]$val)
        }
    }
    [System.IO.File]::WriteAllLines((Join-Path $jobDir 'job.properties'), $spec,
                                    (New-Object System.Text.UTF8Encoding($false)))

    $tag = ''
    if (-not $doSolve) { $tag = '（只导出）' }
    Write-Host ('  [入队]' + $tag + ' ' + $m.Name + '  →  ' + $n + '.csv')
    $jobs += [pscustomobject]@{
        id = $n; model = $m.FullName; recipe = $r.Name
        pid = 0; jobDir = $jobDir; outDir = $outDir
        created = (Get-Date).ToString('o'); started = ''
        status = 'pending'; mode = $(if ($doSolve) { 'solve' } else { 'export' })
    }
}

Write-Host ''
if ($DryRun) {
    # 预览模式：只报计划，绝不写队列、绝不启动计算
    foreach ($cfgBlock in $cfg.Export) { Write-Host ('  导出块: ' + $cfgBlock.Type + ' / ' + $cfgBlock.Name) }
    Write-Host ('  预览：共 ' + $jobs.Count + ' 个作业，未写入队列、未启动计算。')
    foreach ($j in $jobs) { Remove-Item -LiteralPath $j.jobDir -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $instFile -Force -ErrorAction SilentlyContinue
    exit 0
}

$ans = Read-Host ('  开始导出? 共 ' + $jobs.Count + ' 个作业 (Y/N)')
if ($ans -notmatch '^(y|Y)') {
    foreach ($j in $jobs) { Remove-Item -LiteralPath $j.jobDir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host '  已取消。' -ForegroundColor Yellow
    Remove-Item -LiteralPath $instFile -Force -ErrorAction SilentlyContinue
    exit 0
}

$queue = @(Get-Queue)
Save-Queue (@($queue) + @($jobs))
Write-Host ''
Write-Host '  【计算中】关掉本窗口不影响计算；重开 CLI 加 -Resume 可接着监视' -ForegroundColor Yellow
Write-Host ('  日志 : ' + $JobsDir)
Write-Host ('  输出 : ' + (Join-Path $Root 'output'))
Write-Host ''
Invoke-Scheduler

Remove-Item -LiteralPath $instFile -Force -ErrorAction SilentlyContinue
