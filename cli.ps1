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
    [switch]$Diag,
    [string]$Models,
    [string]$Recipe,
    [string]$ModelIndex = '',
    [string]$ComsolPath,
    [ValidateSet('solve','export','')]
    [string]$Mode = '',
    [int]$KillJob = 0,
    [string]$Heap,
    [ValidateSet('','1','2','3')]
    [string]$ProgressStyle = '',
    [int]$Cores = 0,
    [int]$WinWidth = 0,
    [switch]$WinDebug,
    [switch]$Setup,
    [switch]$Modules,
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
# 刷新策略：逐行比对，只重写"内容变了"的那一行（差量），绝不整框重画
$script:LiveTop = -1
$script:LiveCount = 0
$script:LiveText = @()
$script:LiveSig = ''
$script:IsRedirected = $false
try { $script:IsRedirected = [Console]::IsOutputRedirected } catch { }

# 行 = 若干 {Text,Color} 段；整行同色时就是一段
function Join-RowText($row) {
    $sb = ''
    foreach ($s in $row) { $sb = $sb + [string]$s.Text }
    return $sb
}
function Pad-Row($row, [int]$w) {
    $out = @()
    foreach ($s in $row) { $out += @{ Text = [string]$s.Text; Color = $s.Color } }
    if ($out.Count -eq 0) { $out += @{ Text = ''; Color = 'Gray' } }
    $n = $w - (Get-TextWidth (Join-RowText $out))
    if ($n -lt 0) { $n = 0 }
    $last = $out.Count - 1
    $out[$last].Text = [string]$out[$last].Text + (' ' * $n)
    return , $out
}
function Get-RowsWidth($rows) {
    $w = 0
    foreach ($r in $rows) { $w = [math]::Max($w, (Get-TextWidth (Join-RowText $r)) + 2) }
    return $w
}

# 把标题+行组装成"显示行"：每项 @{ Text = 纯文本（用于比对）; Segs = 段数组（用于着色写屏） }
function New-BoxDisplay([string]$title, $rows, [string]$border) {
    $w = Get-RowsWidth $rows
    $tw = Get-TextWidth (' ' + $title + ' ')
    $w = [math]::Max($w, $tw + 2)
    if ($w -lt 10) { $w = 10 }
    $disp = New-Object System.Collections.ArrayList
    $topLine = '  ┌─ ' + $title + ' ' + ('─' * ($w - 1 - $tw)) + '┐'
    [void]$disp.Add(@{ Text = $topLine; Segs = @(@{ Text = $topLine; Color = $border }) })
    foreach ($r in $rows) {
        $padded = Pad-Row $r ($w - 1)
        $segs = New-Object System.Collections.ArrayList
        [void]$segs.Add(@{ Text = '  │ '; Color = $border })
        foreach ($s in $padded) { [void]$segs.Add(@{ Text = [string]$s.Text; Color = $s.Color }) }
        [void]$segs.Add(@{ Text = '│'; Color = $border })
        $arr = @($segs.ToArray())
        [void]$disp.Add(@{ Text = (Join-RowText $arr); Segs = $arr })
    }
    $botLine = '  └' + ('─' * $w) + '┘'
    [void]$disp.Add(@{ Text = $botLine; Segs = @(@{ Text = $botLine; Color = $border }) })
    return , @($disp.ToArray())
}

# 写一行（段着色），右侧补空格到 $padTo 列，用于擦掉上一帧的残留
function Write-LineSegs($segs, [int]$padTo) {
    $used = 0
    foreach ($s in $segs) {
        $tx = [string]$s.Text
        if ($tx) {
            Write-Host $tx -NoNewline -ForegroundColor $s.Color
            $used = $used + (Get-TextWidth $tx)
        }
    }
    if ($padTo -gt $used) { Write-Host (' ' * ($padTo - $used)) -NoNewline }
}

function Get-LiveWidth {
    $bw = 80
    try { $bw = [math]::Max(40, [Console]::BufferWidth - 1) } catch { }
    return $bw
}

function Show-LiveBox([string]$title, $rows, [string]$color) {
    $norm = @()
    foreach ($r in $rows) {
        if ($r -is [string]) { $norm += , @(@{ Text = $r; Color = $color }) }
        else { $norm += , @($r) }
    }
    $flat = @($norm | ForEach-Object { Join-RowText $_ })
    if ($script:IsRedirected) {
        # 输出被重定向（无人值守/日志）：只在阶段或内容变化时打一行，不刷屏
        if ($title -ne $script:LiveSig) {
            $script:LiveSig = $title
            Write-Host ('  [' + $title + '] ' + ($flat -join '   '))
        }
        return
    }
    try {
        $disp = New-BoxDisplay $title $norm $color
        $count = @($disp).Count
        $bw = Get-LiveWidth
        if ($script:LiveTop -lt 0) {
            # 首帧：一次画完，光标停在框下方
            Write-Host ''
            for ($i = 0; $i -lt $count; $i++) {
                Write-LineSegs $disp[$i].Segs $bw
                Write-Host ''
            }
            $script:LiveCount = $count
            $script:LiveText = @($disp | ForEach-Object { [string]$_.Text })
            $script:LiveTop = [math]::Max(0, [Console]::CursorTop - $count)
            return
        }
        $top = $script:LiveTop
        $maxTop = [math]::Max(0, [Console]::BufferHeight - $count - 1)
        if ($top -gt $maxTop) { $top = $maxTop }
        $texts = @($script:LiveText)
        for ($i = 0; $i -lt $count; $i++) {
            $txt = [string]$disp[$i].Text
            # 差量：这一行没变就不碰它（不变的光标不动 = 不闪、不滚屏）
            if ($i -lt $texts.Count -and $texts[$i] -eq $txt) { continue }
            [Console]::SetCursorPosition(0, $top + $i)
            Write-LineSegs $disp[$i].Segs $bw
            if ($i -lt $texts.Count) { $texts[$i] = $txt } else { $texts += $txt }
        }
        $script:LiveText = $texts
        $script:LiveCount = $count
        $script:LiveTop = $top
        $afterRow = $top + $count
        $maxRow = [math]::Max(0, [Console]::BufferHeight - 1)
        if ($afterRow -gt $maxRow) { $afterRow = $maxRow }
        [Console]::SetCursorPosition(0, $afterRow)
    } catch {
        if ($title -ne $script:LiveSig) {
            $script:LiveSig = $title
            Write-Host ('  [' + $title + '] ' + ($flat -join '   '))
        }
    }
}

function Show-StatusLine([string]$text, [string]$fg, [string]$bg) {
    if ($script:IsRedirected) {
        $sig = ($text -replace '[0-9]{2}:[0-9]{2}:[0-9]{2}', '')
        if ($sig -ne $script:LiveSig) { $script:LiveSig = $sig; Write-Host ('  ' + $text) }
        return
    }
    $hw = 80
    try { $hw = [Console]::WindowWidth } catch { }
    if ($hw -lt 62) { $hw = 80 }
    if (-not $script:StatusW -or $script:StatusW -gt ($hw - 1)) { $script:StatusW = $hw - 2 }
    $bw = $script:StatusW
    $line = '▌ ' + $text + ' '
    for ($n = 0; $n -lt 300 -and (Get-TextWidth $line) -gt ($bw - 2) -and $line.Length -gt 2; $n++) {
        $line = $line.Substring(0, $line.Length - 1)
    }
    $padN = $bw - 1 - (Get-TextWidth $line)
    if ($padN -lt 0) { $padN = 0 }
    $out = $line + (' ' * $padN) + '▐'
    try {
        $topBefore = [Console]::CursorTop
        Write-Host ("`r" + $out) -NoNewline -ForegroundColor $fg -BackgroundColor $bg
        if ([Console]::CursorTop -gt $topBefore) {
            $script:StatusW = [math]::Max(60, $script:StatusW - 4)
            try { [Console]::SetCursorPosition(0, $topBefore) } catch { }
        }
    } catch {
        try { Write-Host ("`r" + $out) -NoNewline -ForegroundColor $fg -BackgroundColor $bg } catch { }
    }
}

function Clear-LiveBox {
    try {
        if ($script:LiveTop -ge 0) {
            $bw = Get-LiveWidth
            $blank = ' ' * $bw
            for ($y = 0; $y -lt $script:LiveCount; $y++) {
                [Console]::SetCursorPosition(0, $script:LiveTop + $y)
                Write-Host $blank -NoNewline
            }
            [Console]::SetCursorPosition(0, $script:LiveTop)
        }
    } catch { }
    $script:LiveTop = -1
    $script:LiveCount = 0
    $script:LiveText = @()
}

# 开窗即设好尺寸：宽度按列数算（默认 88 列，够放 74 字方框），高度占满屏幕可用高度。
# 覆盖方式：-WinWidth <n> / 环境变量 COMSOL_EXPORT_COLS / 配置 WindowCols；COMSOL_EXPORT_NORESIZE=1 关掉。
#
# 做法（实测出来的，别改回 SetWindowSize）：conhost 下 [Console]::SetWindowSize 只改「逻辑行列」，
# 窗口像素大小不一定跟着变；可靠的办法是量出每行/每列像素，再用 SetWindowPos 按像素定尺寸。
# 另外 GetWindowRect 对 GetConsoleWindow() 返回的客户区句柄无效（全 0），必须先 GetParent 拿顶层窗口。
# 字体按 DPI 缩放后磅值不可信（本机报 16px，实际每行 20.5px），所以 cellW/cellH 一律现场量。
function Initialize-ConsoleWindow {
    $script:WinInfo = @{ tried = $false; cols = 0; rows = 0; got = ''; how = ''; cellW = 0; cellH = 0; workH = 0 }
    if ($script:IsRedirected) { return }
    if ($env:COMSOL_EXPORT_NORESIZE -eq '1') { return }
    $cols = 88
    if ($script:WinCols -gt 0) { $cols = [int]$script:WinCols }
    elseif ($env:COMSOL_EXPORT_COLS -and $env:COMSOL_EXPORT_COLS -match '^\d+$') { $cols = [int]$env:COMSOL_EXPORT_COLS }
    if ($cols -lt 72) { $cols = 72 }
    if ($cols -gt 300) { $cols = 300 }
    try {
        if (-not ('ComsolCli.Win2' -as [type])) {
            Add-Type -Namespace ComsolCli -Name Win2 -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, out RECT r, uint c);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
'@
        }
    } catch { }
    $script:WinInfo.tried = $true
    $script:WinInfo.cols = $cols

    $top = [IntPtr]::Zero
    try {
        $top = [ComsolCli.Win2]::GetConsoleWindow()
        $par = [ComsolCli.Win2]::GetParent($top)
        if ($par -ne [IntPtr]::Zero) { $top = $par }
    } catch { }
    if ($top -eq [IntPtr]::Zero) { return }

    $workH = 0; $workTop = 0
    try {
        $wa = New-Object 'ComsolCli.Win2+RECT'
        if ([ComsolCli.Win2]::SystemParametersInfo(48, 0, [ref]$wa, 0)) {
            $workH = [int]($wa.Bottom - $wa.Top)
            $workTop = [int]$wa.Top
        }
    } catch { }
    if ($workH -lt 200) {
        $workH = 800; $workTop = 0
        try { $workH = [int][Console]::LargestWindowHeight * 20 } catch { }
    }
    $script:WinInfo.workH = $workH

    # 取消最大化，否则 SetWindowPos 改不动尺寸
    try { [void][ComsolCli.Win2]::ShowWindow($top, 9); Start-Sleep -Milliseconds 250 } catch { }

    # 量像素几何：cellW / cellH
    $cellW = 0.0; $cellH = 0.0
    $rect = New-Object 'ComsolCli.Win2+RECT'
    $haveRect = $false
    try { $haveRect = [ComsolCli.Win2]::GetWindowRect($top, [ref]$rect) } catch { }
    $w0 = 0; $h0 = 0
    try { $w0 = [int][Console]::WindowWidth; $h0 = [int][Console]::WindowHeight } catch { }
    if ($haveRect -and $w0 -gt 10 -and $h0 -gt 5) {
        $pixW0 = $rect.Right - $rect.Left
        $pixH0 = $rect.Bottom - $rect.Top
        if ($pixW0 -gt 200 -and $pixH0 -gt 100) {
            $cellW = $pixW0 / [double]$w0
            $cellH = $pixH0 / [double]$h0
        }
    }
    if ($cellW -lt 4 -or $cellW -gt 40) { $cellW = 10.0 }
    if ($cellH -lt 8 -or $cellH -gt 80) { $cellH = 20.0 }
    $script:WinInfo.cellW = [double][math]::Round($cellW, 2)
    $script:WinInfo.cellH = [double][math]::Round($cellH, 2)

    try { [Console]::SetBufferSize($cols, 4000) } catch { }
    # 用像素定尺寸，最多校两轮（滚动条会吃掉十几像素，所以按实测列数补差）
    $gotW = 0; $gotH = 0
    for ($i = 0; $i -lt 2; $i++) {
        $curW = 0; $curH = 0
        try { $curW = [int][Console]::WindowWidth; $curH = [int][Console]::WindowHeight } catch { }
        $pixW = 0; $pixH = 0
        try {
            $r2 = New-Object 'ComsolCli.Win2+RECT'
            if ([ComsolCli.Win2]::GetWindowRect($top, [ref]$r2)) {
                $pixW = $r2.Right - $r2.Left; $pixH = $r2.Bottom - $r2.Top
            }
        } catch { }
        if ($pixW -le 100) { $pixW = [int][math]::Round($cols * $cellW) }
        $dw = 0
        if ($curW -gt 0) { $dw = [int][math]::Round(($cols - $curW) * $cellW) }
        $newW = [int][math]::Max(320, $pixW + $dw)
        [void][ComsolCli.Win2]::SetWindowPos($top, [IntPtr]::Zero, 0, $workTop, $newW, $workH, 0)
        Start-Sleep -Milliseconds 350
        try { $gotW = [int][Console]::WindowWidth; $gotH = [int][Console]::WindowHeight } catch { }
        if ($gotW -eq $cols) { $script:WinInfo.how = 'px'; break }
        $script:WinInfo.how = 'px'
    }
    if ($gotW -ne $cols) {
        # 兜底：mode con（Windows Terminal 之类对像素 API 不感冒时用）
        try { $null = & cmd.exe /c ("mode con cols={0} lines={1}" -f $cols, 46) ; $script:WinInfo.how = 'mode' } catch { }
        Start-Sleep -Milliseconds 250
        try { $gotW = [int][Console]::WindowWidth; $gotH = [int][Console]::WindowHeight } catch { }
    }
    if ($gotW -ne $cols) {
        try { [void][ComsolCli.Win2]::ShowWindow($top, 3); $script:WinInfo.how = 'maximize' } catch { }
        Start-Sleep -Milliseconds 250
    }
    $script:WinInfo.got = ('{0}x{1}' -f $gotW, $gotH)
    $script:WinInfo.rows = $gotH
    # 缓冲区留够（滚屏不丢历史），窗口保持在左上
    try {
        $hn = 0
        try { $hn = [int][Console]::WindowHeight } catch { }
        [Console]::SetBufferSize([Console]::BufferWidth, [math]::Max($hn + 2000, 3000))
    } catch { }
    try { [void][ComsolCli.Win2]::SetWindowPos($top, [IntPtr]::Zero, 0, $workTop, 0, 0, 0x0001) } catch { }
    if ($script:WinDebug -or $env:COMSOL_EXPORT_WINDEBUG -eq '1') {
        Write-Host ('  [窗口] 目标 {0} 列，实得 {1}（{2}）· 每列 {3}px，每行 {4}px，可用高 {5}px' -f `
            $cols, $script:WinInfo.got, $script:WinInfo.how, $script:WinInfo.cellW, $script:WinInfo.cellH, $workH) -ForegroundColor DarkGray
    }
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
    Write-Host '    -ModelIndex <n>  直接指定第 n 个模型（从 1 开始；列表最后一项是 solved\ 目录）'
    Write-Host '    -DryRun          只打印计划，不写队列、不启动计算'
    Write-Host '    -Mode <solve|export>  求解并导出 / 只导出已有解的模型'
    Write-Host '    -ProgressStyle 1|2|3  进度样式：1 单行 / 2 方框仪表 / 3 阶段链'
    Write-Host '    -Cores <n>       求解用几个核（默认交给 COMSOL 自己定）'
    Write-Host '    -Heap <6g>       Java 堆（默认按物理内存 70%）'
    Write-Host '    -WinWidth <n>    控制台宽度（列），默认 88；高度自动占满'
    Write-Host '    -WinDebug        打印窗口实际尺寸（排查“窗口没铺满”）'
    Write-Host '    -Resume          接着监视队列里未完成的作业'
    Write-Host '    -Help            显示本帮助'
    Write-Host ''
    Write-Host '  配方字段: Task / Study / NameTemplate / Export'
    Write-Host '  Export 块 Type: global | spectrum | image | eigenslice | slice2d | integral | modes | bigtable'
    Write-Host ''
}

function Get-ShortcutTarget {
    # 解快捷方式指向的路径：WScript（.lnk/.link/.url 都能读）→ Arguments 兜底 → 读文本内容里的绝对路径
    param([string]$Path)
    $cand = @()
    try {
        $ws = New-Object -ComObject WScript.Shell
        $s = $ws.CreateShortcut($Path)
        foreach ($v in @($s.TargetPath, $s.Arguments)) {
            if (-not [string]::IsNullOrWhiteSpace($v)) { $cand += $v.Trim().Trim('"') }
        }
    } catch { }
    if ($cand.Count -eq 0) {
        try {
            $len = (Get-Item -LiteralPath $Path).Length
            if ($len -gt 0 -and $len -lt 8192) {
                $txt = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
                foreach ($m in [regex]::Matches($txt, '[A-Za-z]:\\[^"''<>\r\n|*?]*\.mph')) { $cand += $m.Value }
            }
        } catch { }
    }
    foreach ($c in $cand) { if ($c -match '\.mph$') { return $c } }
    if ($cand.Count -gt 0) { return $cand[0] }
    return ''
}

function Get-ModelFiles {
    # 支持 .mph，以及指向 .mph 的快捷方式（.lnk / .link / .url）；
    # 快捷方式的显示名用链接自己的名字，实际路径用目标。
    # 目标不存在也照样列出来并标 Missing——静默丢弃会看起来像“模型列表少了文件”。
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { throw "模型目录不存在: $Dir" }
    $items = @()
    foreach ($f in (Get-ChildItem -LiteralPath $Dir | Where-Object { -not $_.PSIsContainer } | Sort-Object Name)) {
        $ext = $f.Extension.ToLowerInvariant()
        if ($ext -eq '.mph') {
            $items += [pscustomobject]@{
                Name = $f.Name; FullName = $f.FullName
                BaseName = $f.BaseName; IsLink = $false; Missing = $false
            }
        }
        elseif ($ext -eq '.lnk' -or $ext -eq '.link' -or $ext -eq '.url') {
            $target = Get-ShortcutTarget $f.FullName
            if (-not $target) { continue }
            if ([System.IO.Path]::GetExtension($target).ToLowerInvariant() -ne '.mph') { continue }
            $base = $f.BaseName -replace '\s*-\s*快捷方式$', ''
            $items += [pscustomobject]@{
                Name = $f.Name; FullName = $target; BaseName = $base; IsLink = $true
                Missing = -not (Test-Path -LiteralPath $target)
            }
        }
    }
    return @($items)
}

$ModuleDir = Join-Path $ScriptDir 'modules'

function Get-ModuleDefs {
    # 读 modules\*.psd1，返回 @{ 模块名(小写) = 定义 }
    $map = @{}
    if (-not (Test-Path -LiteralPath $ModuleDir)) { return $map }
    foreach ($f in (Get-ChildItem -LiteralPath $ModuleDir | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.psd1' })) {
        try {
            $d = Import-PowerShellDataFile -LiteralPath $f.FullName
        } catch {
            throw ('模块文件解析失败（需 UTF-8 带 BOM）: ' + $f.Name + ' — ' + $_.Exception.Message)
        }
        if (-not $d.Id -or -not $d.Kind) { throw ('模块缺少 Id 或 Kind: ' + $f.Name) }
        $map[[string]$d.Id] = $d
    }
    return $map
}

function Expand-Blocks {
    # 把配方的 Use(模块调用) 与 Export(直接写块) 统一展开成导出块数组
    param($Cfg, [hashtable]$ModuleMap)
    $blocks = @()
    if ($Cfg.ContainsKey('Export') -and $Cfg.Export) { $blocks += @($Cfg.Export) }
    if ($Cfg.ContainsKey('Use') -and $Cfg.Use) {
        foreach ($u in @($Cfg.Use)) {
            $id = [string]$u['Module']
            if ([string]::IsNullOrWhiteSpace($id)) { throw '配方 Use 里有一项缺少 Module' }
            $key = $id.ToLowerInvariant()
            if (-not $ModuleMap.ContainsKey($key)) {
                throw ('没有这个模块: ' + $id + '（可用: ' + (($ModuleMap.Keys | Sort-Object) -join ', ') + '）')
            }
            $m = $ModuleMap[$key]
            $blk = @{}
            if ($m.Defaults) { foreach ($k in $m.Defaults.Keys) { $blk[$k] = $m.Defaults[$k] } }
            foreach ($k in $u.Keys) {
                if ($k -eq 'Module') { continue }
                if ($k -eq 'Name') { $blk['Name'] = $u['Name']; continue }
                if ($m.Keys -and ($m.Keys -notcontains $k)) {
                    throw ('模块 ' + $id + ' 不支持参数 ' + $k + '（可用: ' + ($m.Keys -join ', ') + '）')
                }
                $blk[$k] = $u[$k]
            }
            $blk['Type'] = [string]$m.Kind
            if (-not $blk.ContainsKey('Name')) { $blk['Name'] = $id }
            $blocks += $blk
        }
    }
    return $blocks
}

function Show-Modules {
    $map = Get-ModuleDefs
    if ($map.Count -eq 0) { Write-Host ('  模块目录为空: ' + $ModuleDir); return }
    $rows = @()
    foreach ($k in ($map.Keys | Sort-Object)) {
        $m = $map[$k]
        $keys = ''
        if ($m.Keys) { $keys = ($m.Keys | Where-Object { $_ -ne 'Name' }) -join ', ' }
        $rows += [pscustomobject]@{ Text = ('[{0}] {1}（{2}）  可覆盖: {3}' -f $m.Id, $m.Title, $m.Kind, $keys); Color = 'Gray' }
    }
    Write-BoxRows '预制模块' $rows
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
    # 先按 pid 判活（最可靠）；再尽量核对命令行身份
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    $leaf = Split-Path -Leaf $jobDir
    $p = $null
    try { $p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $procId) -ErrorAction SilentlyContinue } catch { }
    if (-not $p) { return $true }   # 拿不到命令行时只认 pid，宁可当它在跑
    $cl = [string]$p.CommandLine
    if (-not $cl) { return $true }
    if ($p.Name -like 'comsol*') {
        # 求解阶段跑的是 comsolbatch.exe（命令行里带作业目录或模型路径）
        if ($cl -like ('*' + $jobDir + '*')) { return $true }
        if ($leaf -and $cl -like ('*' + $leaf + '*')) { return $true }
        return $false
    }
    if ($p.Name -notlike 'java*') { return $false }
    if ($cl -notlike '*ExportDriver*') { return $false }
    # 网络盘/映射盘的命令行可能与作业目录写法不同，用目录名兜底
    if ($cl -like ('*' + $jobDir + '*')) { return $true }
    if ($leaf -and $cl -like ('*' + $leaf + '*')) { return $true }
    return $false
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

# Java 堆大小：解数据大的模型（如 651 个波长解 ≈ 5.4GB）用 4GB 堆取不全，
# 会静默少给解。这里按物理内存自动给（默认 70%，不少于 4GB），
# 可用参数 -Heap 8g 或环境变量 COMSOL_EXPORT_XMX 覆盖。
# 驱动 class 里的版本串（DRIVER_VERSION 常量），用来发现「只更新了脚本、没更新 driver」的情况：
# 远程出现过 cli.ps1 是新的、driver 还是旧 class，于是同样的 bug 反复报。
$script:ExpectedDriverVersion = 'v1.7.12'

function Get-DriverClassVersion([string]$dir) {
    $p = Join-Path $dir 'ExportDriver.class'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $txt = [System.Text.Encoding]::ASCII.GetString($bytes)
        $m = [regex]::Match($txt, 'v\d+\.\d+\.\d+')
        if ($m.Success) { return $m.Value }
    } catch { }
    return ''
}

function Get-HeapArg {
    if ($Heap) { return ('-Xmx' + $Heap) }
    if ($env:COMSOL_EXPORT_XMX) { return ('-Xmx' + $env:COMSOL_EXPORT_XMX) }
    $mb = 4096
    try {
        $total = [int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
        $want = [int]($total * 0.7)
        # 上限 64GB：公共电脑动辄几百 GB 内存，按 70% 会给到 300GB+，
        # 几十万个解的模型也用不到那么多，堆太大反而可能起不来
        if ($want -gt 65536) { $want = 65536 }
        if ($want -gt $mb) {
            $mb = [int]([math]::Floor($want / 1024) * 1024)
        }
    } catch { }
    return ('-Xmx' + $mb + 'm')
}

# ---------------- 两阶段：comsolbatch 求解 -> 驱动导出 ----------------
# 求解为什么交给 comsolbatch.exe：驱动在 java 里跑 study 时命令行拿不到任何百分比，
# 而 comsolbatch 是 COMSOL 官方批处理程序（无窗口、不弹 GUI），日志里有逐级
# “当前进度: NN % - 矩阵分解”这样的行；导出仍由驱动按解编号分块做，进度写 progress.txt。

function Read-JobSpec([string]$jobDir) {
    $o = @{}
    $sp = Join-Path $jobDir 'job.properties'
    if (-not (Test-Path -LiteralPath $sp)) { return $o }
    foreach ($ln in [System.IO.File]::ReadAllLines($sp)) {
        $k = $ln.IndexOf('=')
        if ($k -gt 0) { $o[$ln.Substring(0, $k)] = $ln.Substring($k + 1) }
    }
    return $o
}

function Get-JobSolvedPath($job) {
    # 与驱动同一口径：<modelsdir>/solved/<outname>.mph
    $spec = Read-JobSpec $job.jobDir
    $outname = [string]$spec['outname']
    $md = [string]$spec['modelsdir']
    if ([string]::IsNullOrWhiteSpace($outname)) { return '' }
    if ([string]::IsNullOrWhiteSpace($md)) { $md = Join-Path $Root 'models' }
    return (Join-Path (Join-Path $md 'solved') ($outname + '.mph'))
}

function Set-JobPhase($job, [string]$phase) {
    Set-JobProp $job 'phase' $phase
    try {
        [System.IO.File]::WriteAllText((Join-Path $job.jobDir 'phase'), $phase, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Get-JobPhase($job) {
    if ($job.PSObject.Properties['phase'] -and $job.phase) { return [string]$job.phase }
    $f = Join-Path $job.jobDir 'phase'
    if (Test-Path -LiteralPath $f) {
        try { $v = ([System.IO.File]::ReadAllText($f)).Trim(); if ($v) { return $v } } catch { }
    }
    if ([string]$job.mode -eq 'export') { return 'export' }
    return 'solve'
}

function Read-FileTailText([string]$path, [int]$maxBytes = 65536) {
    # 读正在增长的文件末尾：必须用 FileShare.ReadWrite，否则会撞上写锁
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            if ($len -le 0) { return '' }
            $room = [math]::Min([int64]$maxBytes, $len)
            $fs.Seek(($len - $room), [System.IO.SeekOrigin]::Begin) | Out-Null
            $buf = New-Object byte[] ([int]$room)
            $got = $fs.Read($buf, 0, [int]$room)
            return [System.Text.Encoding]::UTF8.GetString($buf, 0, $got)
        } finally { $fs.Close() }
    } catch { return '' }
}

# 求解阶段：只认 comsolbatch 写出来的 solve.log（UTF-8）。它的百分比是整项研究的进度，
# 不会在每个扫参点归零（实测 2 个 sim_xy 点：先 0→50，再从 50→100）。
function Get-SolveLogState($job) {
    $o = @{ Pct = -1; Stage = ''; Param = ''; Opened = $false; Running = $false }
    $txt = Read-FileTailText (Join-Path $job.jobDir 'solve.log') 131072
    if ([string]::IsNullOrWhiteSpace($txt)) { return $o }
    if ($txt -match '正在打开文件') { $o.Opened = $true }
    if ($txt -match '正在运行|研究\d|参数化扫描') { $o.Running = $true }
    $ms = [regex]::Matches($txt, '当前进度:\s*(\d+)\s*%[^\S\r\n]*-[^\S\r\n]*([^\r\n]*)')
    if ($ms.Count -gt 0) {
        $last = $ms[$ms.Count - 1]
        $o.Pct = [int]$last.Groups[1].Value
        $o.Stage = $last.Groups[2].Value.Trim()
        # 阶段名为空的行（组装扫参点时常见）沿用上一次非空阶段
        if ($o.Stage -eq '') {
            for ($k = $ms.Count - 1; $k -ge 0; $k--) {
                $sv = $ms[$k].Groups[2].Value.Trim()
                if ($sv -ne '') { $o.Stage = $sv; break }
            }
        }
        $o.Running = $true
    }
    $mp = [regex]::Matches($txt, '参数\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^\r\n。]{1,40})')
    if ($mp.Count -gt 0) {
        $x = $mp[$mp.Count - 1]
        $o.Param = ($x.Groups[1].Value + '=' + $x.Groups[2].Value.Trim())
    }
    return $o
}

function Get-StageLabel([string]$stage) {
    if ([string]::IsNullOrWhiteSpace($stage)) { return '准备' }
    $s = $stage.Trim()
    if ($s -match '矩阵分解') { return '矩阵分解' }
    if ($s -match '组装') { return '组装矩阵' }
    if ($s -match '线性方程组|解方程') { return '解方程' }
    if ($s -match '编译') { return '编译方程' }
    if ($s -match '稳态求解器|求解器') { return '建立求解器' }
    if ($s -match '因变量|初始化') { return '初始化' }
    if ($s -match '完成|正在保存|保存模型') { return '收尾' }
    # 0-1% 的建模/网格段：材料名、形成联合体、布尔操作、各种网格操作
    if ($s -match '网格|联合体|布尔|选择|方程|边|单元|点') { return '网格与建模' }
    if ($s -match '^[\x20-\x7E]+$') { return '网格与建模' }
    return $s
}

function Get-StageIndex([string]$stage) {
    $s = Get-StageLabel $stage
    switch -Regex ($s) {
        '准备'     { return 0 }
        '网格'     { return 1 }
        '编译'     { return 2 }
        '建立求解' { return 3 }
        '组装'     { return 4 }
        '分解'     { return 5 }
        '解方程'   { return 6 }
        '收尾'     { return 7 }
        default    { return 4 }
    }
}

# 导出阶段：读驱动写的 progress.txt（done/total/label）
function Get-ExportState($job) {
    $o = @{ Done = -1; Total = -1; Label = '' }
    $txt = Read-FileTailText (Join-Path $job.jobDir 'progress.txt') 4096
    if ([string]::IsNullOrWhiteSpace($txt)) { return $o }
    foreach ($ln in ($txt -split "`r?`n")) {
        if ($ln -match '^done=(\d+)') { $o.Done = [int]$Matches[1] }
        elseif ($ln -match '^total=(\d+)') { $o.Total = [int]$Matches[1] }
        elseif ($ln -match '^label=(.*)$') { $o.Label = $Matches[1] }
    }
    return $o
}

$script:ProgState = @{}
function Get-ProgState($job) {
    $key = [string]$job.jobDir
    if (-not $script:ProgState.ContainsKey($key)) {
        $script:ProgState[$key] = @{ Phase = ''; Pct = -1; Eta = -1.0 }
    }
    return $script:ProgState[$key]
}

function Parse-DateOrNull($s) {
    if (-not $s) { return $null }
    try { return [datetime]::Parse([string]$s) } catch { return $null }
}

# 进度总口径：全部用“本次作业自己”的量算，不看历史耗时
#   求解：百分比来自 solve.log；剩余 = 已用 ×(100-p)/p
#   导出：百分比来自 progress.txt 的 done/total；剩余按本阶段已解个数外推
function Get-ProgressInfo($job) {
    $st = Get-ProgState $job
    $phase = Get-JobPhase $job
    if ($st.Phase -ne $phase) { $st.Phase = $phase; $st.Pct = -1; $st.Eta = -1.0 }
    $now = Get-Date

    $phaseStart = $null
    if ($phase -eq 'solve') { $phaseStart = Parse-DateOrNull (Get-JobProp $job 'solveStarted') }
    else { $phaseStart = Parse-DateOrNull (Get-JobProp $job 'exportStarted') }
    if (-not $phaseStart) { $phaseStart = Parse-DateOrNull $job.started }
    $totStart = Parse-DateOrNull $job.started

    $elapsed = 0.0
    if ($phaseStart) { $elapsed = [math]::Max(0, ($now - $phaseStart).TotalSeconds) }
    $totalElapsed = $elapsed
    if ($totStart) { $totalElapsed = [math]::Max(0, ($now - $totStart).TotalSeconds) }

    $pct = -1
    $detail = ''
    $stageIdx = -1
    $stageName = ''
    $solDone = -1; $solTotal = -1
    if ($phase -eq 'solve') {
        $s = Get-SolveLogState $job
        $stageIdx = Get-StageIndex $s.Stage
        $stageName = Get-StageLabel $s.Stage
        if ($s.Pct -ge 0) { $pct = $s.Pct }
        if ($s.Running) { $detail = $stageName } elseif ($s.Opened) { $detail = '打开模型（大模型要几分钟）' } else { $detail = '启动 comsolbatch' }
        if ($s.Param) { $detail = $detail + ' · ' + $s.Param }
    } else {
        $e = Get-ExportState $job
        $solDone = $e.Done; $solTotal = $e.Total
        if ($e.Total -gt 0 -and $e.Done -ge 0) {
            $pct = [int][math]::Min(100, [math]::Round(100.0 * $e.Done / $e.Total))
        }
        if ($e.Total -gt 0) { $detail = ('已取 ' + $e.Done + '/' + $e.Total + ' 个解') }
        else { $detail = '打开模型（大模型要几分钟）' }
        if ($e.Label) { $detail = $detail + ' · ' + $e.Label }
        $stageName = '导出'
    }

    # 剩余时间：本阶段实测速率外推（p<3% 时噪声太大，先不给）
    $eta = -1.0
    $exact = ($phase -ne 'solve' -and $solTotal -gt 0 -and $solDone -ge 0)
    if ($pct -ge 100) { $eta = 0.0 }
    elseif ($exact -and $solDone -gt 0 -and $elapsed -ge 5) { $eta = $elapsed * ($solTotal - $solDone) / $solDone }
    elseif ($pct -ge 3 -and $elapsed -ge 8) { $eta = $elapsed * (100.0 - $pct) / $pct }
    if ($eta -ge 0) {
        if (-not $exact -and $pct -lt 100 -and $st.Eta -ge 0 -and $pct -gt $st.Pct) {
            $eta = 0.6 * $st.Eta + 0.4 * $eta
        }
        $st.Eta = $eta
    }
    $st.Pct = $pct
    $finish = $null
    if ($eta -ge 0) { $finish = $now.AddSeconds($eta) }

    $phaseNo = 1; $phaseAll = 1
    if ([string]$job.mode -ne 'export') { $phaseAll = 2; if ($phase -eq 'export') { $phaseNo = 2 } }

    $fg = 'Black'; $bg = 'DarkYellow'
    if ($phase -eq 'export') { $bg = 'DarkCyan' }

    return [pscustomobject]@{
        Phase = $phase
        PhaseLabel = $(if ($phase -eq 'solve') { '求解' } else { '导出' })
        PhaseNo = $phaseNo
        PhaseAll = $phaseAll
        Pct = $pct
        StageName = $stageName
        StageIdx = $stageIdx
        Detail = $detail
        Elapsed = $elapsed
        TotalElapsed = $totalElapsed
        Eta = $eta
        HasEta = ($eta -ge 0)
        Finish = $finish
        SolDone = $solDone
        SolTotal = $solTotal
        Fg = $fg
        Bg = $bg
    }
}

function Format-TimeLine($info, [string]$sep = ' · ') {
    $s = '剩 ' + (Format-Eta $info.Eta)
    if ($info.HasEta -and $info.Eta -ge 30) {
        $s = $s + $sep + '预计 ' + (Format-Finish $info.Finish) + ' 完成'
    }
    return $s
}

function Get-BarSeg([int]$pct, [int]$width) {
    # 两段同字形（█），靠颜色区分已完成/未完成——░ 的墨迹贴顶、█ 满格，同一行看着会错位
    if ($width -lt 4) { $width = 4 }
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    $fill = [int][math]::Round($width * $pct / 100.0)
    return @(
        @{ Text = ('█' * $fill); Color = 'Yellow' },
        @{ Text = ('█' * ($width - $fill)); Color = 'DarkGray' }
    )
}
function Get-Bar([int]$pct, [int]$width) {
    # 单色场景（样式 1 的行内条）：未完成留空格，避免半格阴影带来的高低不齐
    if ($width -lt 4) { $width = 4 }
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    $fill = [int][math]::Round($width * $pct / 100.0)
    return (('█' * $fill) + (' ' * ($width - $fill)))
}

function Format-Eta($sec) {
    if ($sec -lt 0) { return '未知' }
    if ($sec -lt 30) { return '即将完成' }
    $m = [int][math]::Round($sec / 60.0)
    if ($m -lt 1) { return '不到 1 min' }
    if ($m -lt 60) { return ('约 ' + $m + ' min') }
    $h = [int][math]::Floor($m / 60)
    return ('约 ' + $h + ' 小时 ' + ($m % 60) + ' min')
}

function Format-Finish($t) {
    if ($null -eq $t) { return '——' }
    return $t.ToString('HH:mm')
}

function Get-PhaseTag($info) {
    if ($info.PhaseAll -gt 1) { return ($info.PhaseLabel + ' ' + $info.PhaseNo + '/' + $info.PhaseAll) }
    return $info.PhaseLabel
}

function Get-PctText($info) {
    if ($info.Pct -lt 0) { return '  ?%' }
    return ((('{0,3}' -f $info.Pct)) + '%')
}

# 样式 1：单行（窄窗口/最省屏）
function Render-Progress1($info, [string]$jobName, $ord, $total) {
    $bar = '[' + (Get-Bar $info.Pct 18) + ']'
    $etaTxt = '剩 ' + (Format-Eta $info.Eta)
    if ($info.HasEta -and $info.Eta -ge 30) { $etaTxt = $etaTxt + ' → ' + (Format-Finish $info.Finish) }
    $tail = 'Q退出 K终止'
    if ([int]$total -gt 1) { $tail = ('作业 ' + $ord + '/' + $total + ' · ' + $tail) }
    $txt = '▌【' + (Get-PhaseTag $info) + '】' + $bar + ' ' + (Get-PctText $info) + ' 已用 ' + (Format-Elapsed $info.Elapsed) + ' · ' + $etaTxt + ' · ' + $info.Detail + ' · ' + $tail
    Show-StatusLine $txt $info.Fg $info.Bg
}

# 样式 2：方框仪表（与 CLI 其它框一致）
function Render-Progress2($info, [string]$jobName, $ord, $total) {
    $seg = (Get-BarSeg $info.Pct 30)
    # 固定宽度 74：避免每秒刷新时框线抖动；进度条两段同字形，靠颜色区分
    $rows = @(
        (Pad-Row @(@{ Text = ('作业   ' + $ord + '/' + [math]::Max(1, $total) + '   ' + $jobName); Color = $info.Bg }) 74),
        (Pad-Row @(
                @{ Text = '进度   '; Color = $info.Bg },
                $seg[0], $seg[1],
                @{ Text = ('   ' + (Get-PctText $info)); Color = $info.Bg }
            ) 74),
        (Pad-Row @(@{ Text = ('阶段   ' + (Get-PhaseTag $info) + ' · ' + $info.Detail); Color = $info.Bg }) 74),
        (Pad-Row @(@{ Text = ('时间   已用 ' + (Format-Elapsed $info.Elapsed) + '（合计 ' + (Format-Elapsed $info.TotalElapsed) + '） · ' + (Format-TimeLine $info)); Color = $info.Bg }) 74),
        (Pad-Row @(@{ Text = '按键   Q 退出监视（计算不受影响）   K 终止作业'; Color = $info.Bg }) 74)
    )
    Show-LiveBox 'COMSOL 计算进度' $rows $info.Bg
}

# 样式 3：阶段链（看得出走到哪一步了）
function Render-Progress3($info, [string]$jobName, $ord, $total) {
    $seg = (Get-BarSeg $info.Pct 34)
    $chain = ''
    if ($info.Phase -eq 'solve') {
        $names = @('准备', '网格', '编译', '求解器', '组装', '分解', '解方程', '收尾')
        for ($q = 0; $q -lt $names.Count; $q++) {
            $mark = '·'
            if ($q -lt $info.StageIdx) { $mark = '√' }
            elseif ($q -eq $info.StageIdx) { $mark = '▸' }
            $chain = $chain + $mark + $names[$q] + '  '
        }
    } else {
        $chain = ('第 ' + $ord + '/' + [math]::Max(1, $total) + ' 个作业   ' + $jobName)
    }
    $rows = @(
        (Pad-Row @(
                @{ Text = ((Get-PhaseTag $info) + '  '); Color = $info.Bg },
                $seg[0], $seg[1],
                @{ Text = ('  ' + (Get-PctText $info)); Color = $info.Bg }
            ) 74),
        (Pad-Row @(@{ Text = $chain; Color = $info.Bg }) 74),
        (Pad-Row @(@{ Text = $info.Detail; Color = $info.Bg }) 74),
        (Pad-Row @(@{ Text = ('已用 ' + (Format-Elapsed $info.Elapsed) + ' · ' + (Format-TimeLine $info) + ' · Q 退出监视  K 终止'); Color = $info.Bg }) 74)
    )
    Show-LiveBox $jobName $rows $info.Bg
}

function Show-ProgressJob($job, $ord, $total) {
    $info = Get-ProgressInfo $job
    $leaf = [string](Split-Path -Leaf $job.jobDir)
    $nm = $leaf -replace '^\d{12}_', ''
    if ($nm.Length -gt 40) { $nm = $nm.Substring(0, 40) }
    $style = '2'
    if ($script:PStyle) { $style = [string]$script:PStyle }
    if ($script:IsRedirected) {
        $sig = Get-PhaseTag $info
        $dec = ''
        if ($info.Pct -ge 0) { $dec = [string][math]::Floor($info.Pct / 10) }
        $full = ($sig + '|' + $dec)
        if ($script:LiveSig -ne $full) {
            $script:LiveSig = $full
            $line = '  [' + $sig + '] ' + $info.Detail
            if ($info.HasEta) { $line = $line + ' · 剩 ' + (Format-Eta $info.Eta) }
            Write-Host $line
        }
        return
    }
    if ($style -eq '1') { Render-Progress1 $info $nm $ord $total }
    elseif ($style -eq '3') { Render-Progress3 $info $nm $ord $total }
    else { Render-Progress2 $info $nm $ord $total }
}

function Get-SolveErrorLine($job) {
    # 从 solve.log 里抠出 comsolbatch 的报错正文。它的格式是方框 + 后续行：
    #   /***************/  /*****错误********/  /***************/
    #   未知解。
    #    - 标记: all
    $p = Join-Path $job.jobDir 'solve.log'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    $lines = @((Read-FileTailText $p 32768) -split "`r?`n")
    $start = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match '错误') { $start = $i; break }
    }
    if ($start -lt 0) { return '' }
    $msg = @()
    for ($j = $start + 1; $j -lt $lines.Count; $j++) {
        $s = ([string]$lines[$j]).Trim()
        if ($s -eq '') { if ($msg.Count -gt 0) { break } else { continue } }
        if ($s -match '^/+\*+/+$') { continue }
        if ($s -match '^(正在|保存时间|总时间)') { break }
        $msg += $s
        if ($msg.Count -ge 3) { break }
    }
    if ($msg.Count -eq 0) {
        $s = ([string]$lines[$start]).Trim()
        $k = $s.LastIndexOf('/')
        if ($k -ge 0 -and $k -lt ($s.Length - 1)) { $s = $s.Substring($k + 1).Trim() }
        $msg = @($s)
    }
    $out = ($msg -join ' ')
    if ($out.Length -gt 160) { $out = $out.Substring(0, 160) }
    return $out
}

function Test-SolveOk($job) {
    # 求解阶段结束的判据：comsolbatch 写出 <outname>.mph 且状态文件写到 Done（或日志里有总时间）
    $solved = Get-JobSolvedPath $job
    if (-not $solved) { return 'solve-no-spec' }
    if (-not (Test-Path -LiteralPath $solved)) { return 'solve-no-output' }
    $logTail = Read-FileTailText (Join-Path $job.jobDir 'solve.log') 8192
    if ($logTail -match '错误|\*\*\*\*\*错误') { return 'solve-error' }
    $stF = $solved + '.status'
    if (Test-Path -LiteralPath $stF) {
        $st = Read-FileTailText $stF 256
        if ($st -match 'Done') { return '' }
    }
    if ($logTail -match '总时间:') { return '' }
    return 'solve-incomplete'
}

function Start-SolvePhase($job) {
    Set-JobPhase $job 'solve'
    $spec = Read-JobSpec $job.jobDir
    $solved = Get-JobSolvedPath $job
    $model = [string]$spec['model']
    $study = [string]$spec['study']
    $solvedDir = Split-Path -Parent $solved
    if (-not (Test-Path -LiteralPath $solvedDir)) { New-Item -ItemType Directory -Path $solvedDir -Force | Out-Null }
    foreach ($f in @($solved, ($solved + '.status'), ($solved + '.recovery'),
                     (Join-Path $job.jobDir 'solve.log'), (Join-Path $job.jobDir 'solve.out'), (Join-Path $job.jobDir 'solve.err'))) {
        try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { }
    }
    $logF = Join-Path $job.jobDir 'solve.log'
    $outF = Join-Path $job.jobDir 'solve.out'
    $errF = Join-Path $job.jobDir 'solve.err'
    $argList = @('-inputfile', ('"' + $model + '"'), '-outputfile', ('"' + $solved + '"'),
                 '-batchlog', ('"' + $logF + '"'), '-batchlogout', '-alivetime', '5')
    if (-not [string]::IsNullOrWhiteSpace($study)) { $argList += @('-study', ('"' + $study + '"')) }
    if ($Cores -gt 0) { $argList += @('-np', [string]$Cores) }
    $launchInfo = @(
        'time=' + (Get-Date).ToString('o'),
        'comsolbatch=' + $comsolBatch,
        'args=' + ($argList -join ' '),
        'driver_version=' + $drvVer,
        'jobdir=' + $job.jobDir
    ) -join "`r`n"
    try { [System.IO.File]::WriteAllText((Join-Path $job.jobDir 'launch-solve.txt'), $launchInfo, (New-Object System.Text.UTF8Encoding($false))) } catch { }
    if (-not (Test-Path -LiteralPath $comsolBatch)) {
        $job.status = 'failed'
        Set-JobProp $job 'exitcode' 'no-comsolbatch'
        return
    }
    try {
        $proc = Start-Process -FilePath $comsolBatch -ArgumentList $argList `
                              -RedirectStandardOutput $outF -RedirectStandardError $errF `
                              -WindowStyle Hidden -WorkingDirectory $job.jobDir -PassThru
    } catch {
        try { Add-Content -LiteralPath (Join-Path $job.jobDir 'launch-solve.txt') -Value ('start-error=' + $_.Exception.Message) -Encoding UTF8 } catch { }
        Set-JobProp $job 'exitcode' 'launch-error'
        $job.status = 'failed'
        return
    }
    $job.pid = $proc.Id
    if (-not $job.started) { Set-JobProp $job 'started' (Get-Date).ToString('o') }
    Set-JobProp $job 'solveStarted' ([string]$job.started)
    Set-JobProp $job 'exportStarted' ''
    $job.status = 'running'
}

function Start-OneJob($job) {
    # 分派：需要求解且还没有解 -> 先 comsolbatch；否则直接进导出
    $hasSolvedMarker = Test-Path -LiteralPath (Join-Path $job.jobDir 'solved')
    $solvedPath = Get-JobSolvedPath $job
    $hasSolvedFile = $false
    if ($solvedPath) { $hasSolvedFile = Test-Path -LiteralPath $solvedPath }
    if ([string]$job.mode -eq 'export') {
        Set-JobPhase $job 'export'
        Start-ExportPhase $job
        return
    }
    if ($hasSolvedMarker -and $hasSolvedFile) {
        # 上一轮已经算完（例如导出阶段失败过）：直接重跑导出
        Set-JobPhase $job 'export'
        Start-ExportPhase $job
        return
    }
    Start-SolvePhase $job
}

function Start-JobDriver($dir) {
    $spec = Join-Path $dir 'job.properties'
    if (-not (Test-Path -LiteralPath $spec)) { throw ('作业缺少 job.properties: ' + $dir) }
    $csPath = Resolve-Comsol $ComsolPath
    $rootNow = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $csPath))
    $javaNow = Join-Path $rootNow 'java\win64\jre\bin\java.exe'
    $cpNow   = (Join-Path $rootNow 'plugins\*') + ';' + (Join-Path $ScriptDir 'driver')
    $logNow  = Join-Path $dir 'driver.log'
    $inner = '"' + $javaNow + '" ' + (Get-HeapArg) + ' -cp "' + $cpNow + '" ExportDriver "' + $spec + '" > "' + $logNow + '" 2>&1'
    $proc = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ('cmd.exe /c "' + $inner + '"') }
    if ($proc.ReturnValue -ne 0) { throw ('启动失败, 返回码 ' + $proc.ReturnValue) }
    return $proc.ProcessId
}

# ---------------- 主流程 ----------------


if ($Help) { Show-Help; exit 0 }

if ($Modules) { Show-Modules; exit 0 }
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

function Start-ExportPhase($job) {
    Set-JobPhase $job 'export'
    $logFile = Join-Path $job.jobDir 'driver.log'
    $errFile = Join-Path $job.jobDir 'driver.err'
    $cp = (Join-Path $comsolRoot 'plugins\*') + ';' + $driverDir
    # 更新没覆盖到 driver 时这里会看出来：class 里的版本串和脚本期望的不一致
    $drvVer = Get-DriverClassVersion $driverDir
    if ($drvVer -ne $script:ExpectedDriverVersion) {
        Write-Host ''
        $drvMsg = '  [警告] driver 目录不是最新：class 版本 ' + $drvVer + '，期望 ' + $script:ExpectedDriverVersion + '。请重跑 update.bat（或手动覆盖 script\driver）'
        Write-Host $drvMsg -ForegroundColor Yellow
    }
    $argStr = (Get-HeapArg) + ' -Dfile.encoding=UTF-8 -Dsun.stdout.encoding=UTF-8 -Dsun.stderr.encoding=UTF-8 -Dstdout.encoding=UTF-8 -Dstderr.encoding=UTF-8 -cp "' + $cp + '" ExportDriver "' + (Join-Path $job.jobDir 'job.properties') + '"'
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
    if (-not $job.started) { Set-JobProp $job 'started' (Get-Date).ToString('o') }
    Set-JobProp $job 'exportStarted' (Get-Date).ToString('o')
    $job.pid = $proc.Id
    $job.status = 'running'
}

# 找出属于某作业的进程：java/comsol，且命令行里带作业目录 / 目录名 / 模型路径。
# 为什么按这些标记而不是只按 pid：comsolbatch 会派生子进程，且求解/导出两个阶段
# 的 pid 不同（求解记的是 comsolbatch，导出记的是 java），挨个阶段都要能抓到。
function Get-JobProcIds($job) {
    $ids = @()
    $jobDir = [string](Get-JobProp $job 'jobDir')
    $leaf = ''
    if ($jobDir) { $leaf = Split-Path -Leaf $jobDir }
    $model = [string](Get-JobProp $job 'model')
    $marks = @()
    if ($jobDir) { $marks += $jobDir }
    if ($leaf) { $marks += $leaf }
    if ($model) { $marks += $model }
    try {
        foreach ($pp in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                          Where-Object { $_.Name -like 'java*' -or $_.Name -like 'comsol*' })) {
            $cl = [string]$pp.CommandLine
            if (-not $cl) { continue }
            foreach ($m in $marks) {
                if ($m -and $cl -like ('*' + $m + '*')) { $ids += [int]$pp.ProcessId; break }
            }
        }
    } catch { }
    return @($ids | Sort-Object -Unique)
}

function Stop-OneJob($job) {
    # 先落 killed 标记：哪怕下面杀不干净，调度器也不会把这一步当成"正常结束"再接手
    $marker = Join-Path $job.jobDir 'killed'
    try { [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch { }

    $killed = @()
    $msg = ''
    # 反复扫 + 杀：每轮重新枚举（新冒出来的子进程也一起收），最多 12 轮 × 0.5 s
    for ($round = 0; $round -lt 12; $round++) {
        $targets = @(Get-JobProcIds $job)
        $recPid = [int](Get-JobProp $job 'pid')
        if ($recPid -gt 0) { $targets += $recPid }
        $targets = @($targets | Sort-Object -Unique)
        $live = @()
        foreach ($tpid in $targets) {
            $pp = Get-Process -Id $tpid -ErrorAction SilentlyContinue
            if (-not $pp) { continue }
            # 只杀 java / comsol，别误伤本 CLI 的 powershell
            if ($pp.ProcessName -notlike 'java*' -and $pp.ProcessName -notlike 'comsol*') { continue }
            $live += $tpid
        }
        if ($live.Count -eq 0) { break }
        foreach ($tpid in $live) {
            $msg = (& taskkill.exe /PID $tpid /T /F 2>&1 | Out-String).Trim()
            if ($killed -notcontains $tpid) { $killed += $tpid }
        }
        Start-Sleep -Milliseconds 500
    }

    $left = @(Get-JobProcIds $job)
    $recPid = [int](Get-JobProp $job 'pid')
    if ($recPid -gt 0) { $left += $recPid }
    $left = @($left | Sort-Object -Unique | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($left.Count -gt 0) {
        return ('终止失败，进程仍在: ' + ($left -join ',') + ' | ' + $msg)
    }
    Set-JobProp $job 'status' 'killed'
    Set-JobProp $job 'pid' 0
    $note = Clear-JobLock $job
    if ($killed.Count -eq 0) { return ('已终止（进程已自行结束）；模型锁: ' + $note) }
    return ('已终止 PID ' + ($killed -join ',') + '；模型锁: ' + $note)
}

function Invoke-KillMenu {
    Clear-LiveBox
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

function Get-JobProp($job, $name) {
    if ($job.PSObject.Properties[$name]) { return $job.$name }
    return ''
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

function Get-JobDisplay($job) {
    # 只做实时口径的转发：进度/剩余/完成时间点全部来自本次作业自己的日志与解计数
    return (Get-ProgressInfo $job)
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
                    if (Test-Path -LiteralPath (Join-Path $job.jobDir 'killed')) {
                        # 已经按过终止键：先收掉残留进程，再把作业判为终止。
                        # 之前的实现只在"进程真的没了"之后才写 killed，杀不干净时作业会永远挂着。
                        $leftIds = @(Get-JobProcIds $job)
                        if ($leftIds.Count -gt 0 -or [int](Get-JobProp $job 'pid') -gt 0) {
                            $km = Stop-OneJob $job
                            Clear-LiveBox
                            Write-Host ('  [终止] ' + (Split-Path -Leaf $job.jobDir) + '  ' + $km) -ForegroundColor Yellow
                        }
                        Set-JobProp $job 'status' 'killed'
                    }
                    elseif (Test-Path -LiteralPath (Join-Path $job.jobDir 'exported')) {
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
                        Start-Sleep -Milliseconds 400
                        $phaseNow = Get-JobPhase $job
                        if ($phaseNow -eq 'solve' -and -not (Test-Path -LiteralPath (Join-Path $job.jobDir 'killed'))) {
                            $why = Test-SolveOk $job
                            if ($why -eq '') {
                                # 求解成功：写 solved 标记（驱动据此走 resume），接着起导出
                                [System.IO.File]::WriteAllText((Join-Path $job.jobDir 'solved'), '', (New-Object System.Text.UTF8Encoding($false)))
                                Clear-LiveBox
                                $durTxt = ''
                                $ss = Parse-DateOrNull (Get-JobProp $job 'solveStarted')
                                if ($ss) { $durTxt = '  用时 ' + (Format-Elapsed ((Get-Date) - $ss).TotalSeconds) }
                                Write-Host ('  [求解完成] ' + (Split-Path -Leaf $job.jobDir) + $durTxt + '，开始导出…') -ForegroundColor Green
                                Start-ExportPhase $job
                            } else {
                                $job.status = 'failed'
                                Set-JobProp $job 'exitcode' $why
                            }
                        }
                        elseif (Test-Path -LiteralPath (Join-Path $job.jobDir 'exported')) {
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
                Show-ProgressJob $job $ord $total
            } else {
                Clear-LiveBox
                $body = ('【调度中】已用 ' + (Format-Elapsed $el.TotalSeconds) + ' · 完成 ' + $fin.Count + '/' + [math]::Max(1, $total) + ' · Q 退出监视  K 终止作业')
                Show-StatusLine $body 'White' 'DarkGray'
            }

            if ($i % 10 -eq 0) {
                try {
                    if ($cur.Count -gt 0) {
                        $dT = Get-JobDisplay $cur[0]
                        $Host.UI.RawUI.WindowTitle = ('【' + (Get-PhaseTag $dT) + ' ' + (Get-PctText $dT).Trim() + '】' + (Split-Path -Leaf $cur[0].jobDir) + ' - COMSOL 导出')
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
                    if ($k.Key -eq 'K') { Clear-LiveBox; Write-Host ''; Invoke-KillMenu; Write-Host '' }
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
                foreach ($m in @('started','exit','exported','killed','launch.txt','launch-solve.txt','solve.log')) {
                    $mp = Join-Path $job.jobDir $m
                    if (Test-Path -LiteralPath $mp) { $ev += ($m + '=有') } else { $ev += ($m + '=无') }
                }
                $hs = @(Get-ChildItem -LiteralPath $job.jobDir -Filter 'hs_err_pid*.log' -ErrorAction SilentlyContinue)
                if ($hs.Count -gt 0) { $ev += ('hs_err=' + $hs[0].Name) }
                foreach ($m in @('driver.log','driver.err','driver.self.log')) {
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
                    Write-Host ('  [失败] ' + $leaf + '  启动进程失败（见 launch.txt / launch-solve.txt 的 start-error）') -ForegroundColor Red
                } elseif ($code -eq 'solve-error') {
                    $el = Get-SolveErrorLine $job
                    if ($el) { Write-Host ('  [失败] ' + $leaf + '  求解报错：' + $el) -ForegroundColor Red }
                    else { Write-Host ('  [失败] ' + $leaf + '  求解报错（细节见 solve.log）') -ForegroundColor Red }
                } elseif ($code -eq 'solve-no-output' -or $code -eq 'solve-incomplete') {
                    Write-Host ('  [失败] ' + $leaf + '  求解没跑完：' + $code + '（见 solve.log）') -ForegroundColor Red
                } elseif ($code -eq '?') {
                    Write-Host ('  [失败] ' + $leaf + '  驱动启动了(started 有)但没有写 exit —— Java 崩溃或被外部杀掉') -ForegroundColor Red
                } else {
                    Write-Host ('  [失败] ' + $leaf + '  退出码 ' + $code) -ForegroundColor Red
                }
                foreach ($f in @('driver.err', 'driver.log', 'solve.log')) {
                    $fp = Join-Path $job.jobDir $f
                    if (-not (Test-Path -LiteralPath $fp)) { continue }
                    $tail = @(Get-Content -LiteralPath $fp -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() -ne '' -and $_ -notmatch '^\s+at ' } | Select-Object -Last 3)
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
$script:PStyle = $ProgressStyle
if ([string]::IsNullOrWhiteSpace($script:PStyle)) {
    $script:PStyle = [string](Read-Config).ProgressStyle
    if ([string]::IsNullOrWhiteSpace($script:PStyle)) { $script:PStyle = '2' }
}
if ($env:COMSOL_EXPORT_STYLE) { $script:PStyle = [string]$env:COMSOL_EXPORT_STYLE }
$script:WinCols = 0
if ($WinWidth -gt 0) { $script:WinCols = [int]$WinWidth }
$script:WinDebug = [bool]$WinDebug
Initialize-ConsoleWindow
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

if ($Diag) {
    $cands = @(Get-ChildItem -LiteralPath $JobsDir -ErrorAction SilentlyContinue |
               Where-Object { $_.PSIsContainer -and (Test-Path -LiteralPath (Join-Path $_.FullName 'job.properties')) } |
               Sort-Object LastWriteTime -Descending)
    if ($cands.Count -eq 0) { Write-Host ('  没有可调试的作业: ' + $JobsDir) -ForegroundColor Yellow; exit 1 }
    $jd = $cands[0].FullName
    Write-Host ('  调试运行: ' + (Split-Path $jd -Leaf)) -ForegroundColor Cyan
    Write-Host ('  java   : ' + $javaExe)
    Write-Host ('  直接输出到本窗口，崩溃信息会留在屏幕上') -ForegroundColor DarkGray
    $cpD = (Join-Path $comsolRoot 'plugins\*') + ';' + $driverDir
    Push-Location $jd
    & $javaExe (Get-HeapArg) '-Dfile.encoding=UTF-8' '-Dsun.stdout.encoding=UTF-8' '-Dsun.stderr.encoding=UTF-8' '-Dstdout.encoding=UTF-8' '-Dstderr.encoding=UTF-8' '-cp' $cpD 'ExportDriver' (Join-Path $jd 'job.properties')
    $rc = $LASTEXITCODE
    Pop-Location
    Write-Host ('  退出码: ' + $rc) -ForegroundColor Yellow
    $hs = @(Get-ChildItem -LiteralPath $jd -Filter 'hs_err_pid*.log' -ErrorAction SilentlyContinue)
    if ($hs.Count -gt 0) { Write-Host ('  Java 崩溃日志: ' + $hs[0].FullName) -ForegroundColor Red }
    exit 0
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
$solvedDir = Join-Path $Models 'solved'
$solvedFiles = @()
if (Test-Path -LiteralPath $solvedDir) { $solvedFiles = @(Get-ModelFiles $solvedDir) }
$fromSolved = $false
# solved\ 作为“额外一项”挂在模型列表最后：序号 = 当前条数 + 1
$solvedNo = 0
if ($solvedFiles.Count -gt 0) { $solvedNo = $modelFiles.Count + 1 }
if ($modelFiles.Count -eq 0 -and $solvedNo -eq 0) { throw "目录里没有 .mph 或指向 .mph 的快捷方式: $Models" }

$miRaw = [string]$ModelIndex
$shown = $false
$pickAll = $false
$idxs = @()
while ($true) {
    if (-not $shown) {
        $rows = @()
        for ($i = 0; $i -lt $modelFiles.Count; $i++) {
            $label = $modelFiles[$i].Name
            if ($modelFiles[$i].IsLink) { $label = $label + '  →  ' + [System.IO.Path]::GetFileName($modelFiles[$i].FullName) }
            $color = 'Gray'
            if ($modelFiles[$i].Missing) { $label = $label + '  （快捷方式目标不存在）'; $color = 'DarkYellow' }
            $rows += [pscustomobject]@{ Text = ('[{0}] {1}' -f ($i + 1), $label); Color = $color }
        }
        if ($solvedNo -gt 0) {
            $rows += [pscustomobject]@{ Text = ('[{0}] 从 solved\ 里选（已算过的模型，共 {1} 个，默认只导出）' -f $solvedNo, $solvedFiles.Count); Color = 'Cyan' }
        }
        $title = '选择模型'
        if ($fromSolved) { $title = '选择模型（solved\）' }
        Write-BoxRows $title $rows
        $shown = $true
    }
    if ([string]::IsNullOrWhiteSpace($miRaw)) {
        $miRaw = Read-Host '  选择模型序号（直接回车=1，多个用逗号，a=全部）'
        if ([string]::IsNullOrWhiteSpace($miRaw)) { $miRaw = '1' }
    }
    $idxs = @()
    if ($miRaw -match '^\s*a\s*$') { $idxs = @(1..$modelFiles.Count); $pickAll = $true }
    elseif ($solvedNo -gt 0 -and $miRaw -match ('^\s*' + $solvedNo + '\s*$')) {
        # 切到 solved\ 列表重选一次；切过去以后这一项就不再出现，避免套娃
        $modelFiles = $solvedFiles
        $solvedNo = 0
        $fromSolved = $true
        $shown = $false
        $miRaw = ''
        Write-Host ('  已切到 ' + $solvedDir) -ForegroundColor Cyan
        continue
    }
    else {
        foreach ($piece in ($miRaw -split ',')) {
            $n = 0
            if ([int]::TryParse($piece.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $modelFiles.Count) { $idxs += $n }
        }
    }
    if ($idxs.Count -gt 0) { break }
    if (-not [string]::IsNullOrWhiteSpace($ModelIndex)) { throw ('模型序号无效: ' + $ModelIndex) }
    $hint = '  序号无效：“' + $miRaw + '”，请输入 1-' + $modelFiles.Count
    if ($solvedNo -gt 0) { $hint = $hint + ' 或 ' + $solvedNo + '（solved\）' }
    Write-Host ($hint + '，多个用逗号，a=全部') -ForegroundColor Yellow
    $miRaw = ''
}
# solved\ 里的是算过的模型：默认只导出。这里强制不重算——输出路径就是
# <models>\solved\<outname>.mph，重算时输入和输出可能同名，等于边读边覆盖自己。
if ($fromSolved -and $doSolve) {
    $doSolve = $false
    if ($Mode -eq 'solve') {
        throw ('solved\ 里的模型是按「只导出」使用的：重算会把它自己覆盖掉。要重算请选 models\ 里的裸模型: ' + $modelFiles[0].FullName)
    }
    Write-Host '  solved\ 里的模型：只导出（要重算请选 models\ 里的裸模型）' -ForegroundColor Cyan
}
$modelList = @($idxs | ForEach-Object { $modelFiles[$_-1] })
# a=全部：失效的快捷方式直接跳过并提示，不让整个队列被一条坏链接卡死
if ($pickAll) {
    $skipped = @($modelList | Where-Object { $_.Missing })
    foreach ($s in $skipped) { Write-Host ('  跳过（快捷方式目标不存在）: ' + $s.Name) -ForegroundColor DarkYellow }
    $modelList = @($modelList | Where-Object { -not $_.Missing })
    if ($modelList.Count -eq 0) { throw '选中的模型都不可用（快捷方式都指向不存在的文件）' }
}
$bad = @($modelList | Where-Object { $_.Missing })
if ($bad.Count -gt 0) {
    $msg = @('这些快捷方式的目标模型不存在（快捷方式可能过期了，重建或者改指向新文件）：')
    foreach ($b in $bad) {
        $msg += ('  ' + $b.Name + '  →  ' + $b.FullName)
        # 目标被改过名（常见：多加了 _npim 之类后缀）就给个提示，不自动改，免得指错文件
        $d = Split-Path -Parent $b.FullName
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($b.FullName)
        if ((Test-Path -LiteralPath $d) -and $stem) {
            $near = @(Get-ChildItem -LiteralPath $d -Filter ($stem + '*.mph') -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })
            if ($near.Count -eq 1) { $msg += ('      疑似同名新文件: ' + $near[0].Name) }
        }
    }
    throw ($msg -join [Environment]::NewLine)
}
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
$blocks = @(Expand-Blocks $cfg (Get-ModuleDefs))
if ($blocks.Count -eq 0) { throw ('配方没有任何导出内容（Use 或 Export 为空）: ' + $r.Name) }

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
    $spec.Add('blocks='   + $blocks.Count)
    $spec.Add('solve='    + $(if ($doSolve) { '1' } else { '0' }))
    # 每块取多少个解（默认 200）；解特别多又内存紧张时可在配方里写 Chunk = 100
    $chunkVal = 200
    if ($cfg.Chunk) { $chunkVal = [int]$cfg.Chunk }
    $spec.Add('chunk='    + $chunkVal)
    for ($i = 0; $i -lt $blocks.Count; $i++) {
        $b = $blocks[$i]
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
    foreach ($cfgBlock in $blocks) { Write-Host ('  导出块: ' + $cfgBlock.Type + ' / ' + $cfgBlock.Name) }
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
