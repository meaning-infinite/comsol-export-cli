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
    [ValidateSet('solve','export','watch','')]
    [string]$Mode = '',
    [string]$KillJob = '',
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
    if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected) { Read-Host '  按回车关闭' | Out-Null }
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
# 按显示宽度截断（中文算两格），超长补省略号；日志/菜单里都靠它防撑爆
function Cut-Text([string]$s, [int]$maxW) {
    if ($maxW -le 1) { return '' }
    if ((Get-TextWidth $s) -le $maxW) { return $s }
    $cut = ''
    foreach ($ch in $s.ToCharArray()) {
        if ((Get-TextWidth ($cut + $ch)) -gt ($maxW - 1)) { break }
        $cut = $cut + $ch
    }
    return $cut + '…'
}

# 把一行（多段）按显示宽度截到 $w 列：超出部分整段丢弃，末段补省略号
# 用途：动态内容（作业名、进度细节）再长也不撑破统一宽度的框
function Trim-Row($row, [int]$w) {
    $out = @()
    $used = 0
    foreach ($s in $row) {
        $tx = [string]$s.Text
        if (-not $tx) { continue }
        $tw = Get-TextWidth $tx
        if (($used + $tw) -le $w) {
            $out += @{ Text = $tx; Color = $s.Color; Bg = $s.Bg }
            $used = $used + $tw
            continue
        }
        $room = $w - $used
        if ($room -gt 2) {
            $out += @{ Text = (Cut-Text $tx $room); Color = $s.Color; Bg = $s.Bg }
        }
        break
    }
    if ($out.Count -eq 0) { $out += @{ Text = ''; Color = 'Gray'; Bg = $null } }
    return , $out
}

# 所有方框统一内宽：标题框、菜单框、进度框、汇总框左右边缘对齐
# （进度框一直按 74 字符排版，故基准取 76 = 74 + 左右各 1 格留白）
$script:BoxW = 76
function Get-BoxWidth([int]$contentW) {
    # 只用统一基准宽度：内容超长由 Cut-Text/Trim-Row 截断，绝不把框撑宽
    $w = $script:BoxW
    $lim = 0
    try { $lim = [math]::Min([Console]::BufferWidth, [Console]::WindowWidth) - 6 } catch { }
    if ($lim -gt 0) { $w = [math]::Min($w, $lim) }
    return $w
}
function Get-BoxLines([string]$title, [string[]]$lines) {
    $w = Get-BoxWidth 0
    $title = Cut-Text $title ($w - 6)
    $tw = Get-TextWidth (' ' + $title + ' ')
    $out = @('┌' + '─ ' + $title + ' ' + ('─' * [math]::Max(0, ($w - 1 - $tw))) + '┐')
    foreach ($l in $lines) { $out += ('│ ' + (Pad-Text (Cut-Text $l ($w - 2)) ($w - 1)) + '│') }
    $out += ('└' + ('─' * $w) + '┘')
    return $out
}
function Write-Box([string]$title, [string[]]$lines, [string]$color = 'Cyan') {
    foreach ($l in (Get-BoxLines $title $lines)) { Write-Host ('  ' + $l) -ForegroundColor $color }
}
function Write-BoxRows([string]$title, $rows, [string]$border = 'Cyan') {
    $w = Get-BoxWidth 0
    $title = Cut-Text $title ($w - 6)
    $tw = Get-TextWidth (' ' + $title + ' ')
    Write-Host ('  ┌─ ' + $title + ' ' + ('─' * [math]::Max(0, ($w - 1 - $tw))) + '┐') -ForegroundColor $border
    foreach ($r in $rows) { Write-Host ('  │ ' + (Pad-Text (Cut-Text ([string]$r.Text) ($w - 2)) ($w - 1)) + '│') -ForegroundColor $r.Color }
    Write-Host ('  └' + ('─' * $w) + '┘') -ForegroundColor $border
}

# 开场字标：ANSI 阴影块字（6 行）＋对角渐变（白 → 亮青 → 青 → 深青）
# 渐变靠 24 位 ANSI 逐字符上色，需要 VT 打开；拿不到 VT 时退化成 DarkCyan 单色，字形不变。
# 字模里 C 自带 1 格尾空、O 自带 1 格首空，所以 C 与第一个 O 之间不再额外留空（视觉间距与其它字母一致）。
$script:CliVersion = 'v1.9.1'
$script:CliExit = 0
$script:ArtRows = @(
    ' ██████╗  ██████╗   ███╗   ███╗  ███████╗   ██████╗   ██╗     ',
    '██╔════╝ ██╔═══██╗  ████╗ ████║  ██╔════╝  ██╔═══██╗  ██║     ',
    '██║      ██║   ██║  ██╔████╔██║  ███████╗  ██║   ██║  ██║     ',
    '██║      ██║   ██║  ██║╚██╔╝██║  ╚════██║  ██║   ██║  ██║     ',
    '╚██████╗ ╚██████╔╝  ██║ ╚═╝ ██║  ███████║  ╚██████╔╝  ███████╗',
    ' ╚═════╝  ╚═════╝   ╚═╝     ╚═╝  ╚══════╝   ╚═════╝   ╚══════╝'
)
$script:ArtCols = 62
$script:ArtStops = @(
    [int[]]@(252, 252, 252),
    [int[]]@(150, 232, 240),
    [int[]]@(86, 204, 218),
    [int[]]@(40, 156, 176),
    [int[]]@(22, 108, 128)
)
$script:VtOk = $null
function Enable-VtColor {
    if ($script:VtOk -ne $null) { return [bool]$script:VtOk }
    $script:VtOk = $false
    if ($script:IsRedirected) { return $false }
    try {
        if (-not ('ComsolCli.Con2' -as [type])) {
            Add-Type -Namespace ComsolCli -Name Con2 -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
'@
        }
        $h = [ComsolCli.Con2]::GetStdHandle(-11)
        $m = [uint32]0
        if ([ComsolCli.Con2]::GetConsoleMode($h, [ref]$m)) {
            $script:VtOk = [ComsolCli.Con2]::SetConsoleMode($h, ($m -bor 0x4))
        }
    } catch { }
    return [bool]$script:VtOk
}
# 对角渐变：竖向权重 0.62、横向 0.38，逐格插值后返回 "r;g;b"
function Get-ArtColor([int]$r, [int]$c) {
    $t = 0.62 * ($r / 5.0) + 0.38 * ($c / ([double][math]::Max(1, $script:ArtCols - 1)))
    if ($t -lt 0) { $t = 0.0 }
    if ($t -gt 1) { $t = 1.0 }
    $st = $script:ArtStops
    $x = $t * ($st.Count - 1)
    $i = [int][math]::Floor($x)
    if ($i -gt ($st.Count - 2)) { $i = $st.Count - 2 }
    $f = $x - $i
    $a = $st[$i]; $b = $st[$i + 1]
    $rr = [int][math]::Round($a[0] + ($b[0] - $a[0]) * $f)
    $gg = [int][math]::Round($a[1] + ($b[1] - $a[1]) * $f)
    $bb = [int][math]::Round($a[2] + ($b[2] - $a[2]) * $f)
    return ('{0};{1};{2}' -f $rr, $gg, $bb)
}
function Write-Banner {
    $vt = Enable-VtColor
    $esc = [string][char]27
    $last = $script:ArtRows.Count - 1
    for ($r = 0; $r -lt $script:ArtRows.Count; $r++) {
        $row = [string]$script:ArtRows[$r]
        if (-not $vt) {
            $line = '  ' + $row.TrimEnd()
            if ($r -eq $last) { $line = $line + '   ' + $script:CliVersion }
            Write-Host $line -ForegroundColor DarkCyan
            continue
        }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('  ')
        $cur = ''
        $colCount = $row.Length
        if ($r -eq $last) { while ($colCount -gt 0 -and $row[$colCount - 1] -eq ' ') { $colCount-- } }
        for ($c = 0; $c -lt $colCount; $c++) {
            $ch = $row[$c]
            if ($ch -eq ' ') { [void]$sb.Append(' '); continue }
            $col = Get-ArtColor $r $c
            if ($col -ne $cur) {
                [void]$sb.Append($esc + '[38;2;' + $col + 'm')
                $cur = $col
            }
            [void]$sb.Append($ch)
        }
        if ($r -eq $last) {
            if ($cur -ne '') { [void]$sb.Append($esc + '[0m'); $cur = '' }
            [void]$sb.Append('   ' + $esc + '[38;2;235;250;252m' + $script:CliVersion + $esc + '[0m')
        }
        if ($cur -ne '') { [void]$sb.Append($esc + '[0m') }
        Write-Host $sb.ToString()
    }
    Write-Host ''
}

# LiveCount 记录光标上方为活动框预留的屏幕行数。
$script:LiveCount = 0
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
    foreach ($s in $row) { $out += @{ Text = [string]$s.Text; Color = $s.Color; Bg = $s.Bg } }
    if ($out.Count -eq 0) { $out += @{ Text = ''; Color = 'Gray'; Bg = $null } }
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
    $w = Get-BoxWidth 0
    $title = Cut-Text $title ($w - 6)
    $tw = Get-TextWidth (' ' + $title + ' ')
    $disp = New-Object System.Collections.ArrayList
    $topLine = '  ┌─ ' + $title + ' ' + ('─' * [math]::Max(0, ($w - 1 - $tw))) + '┐'
    [void]$disp.Add(@{ Text = $topLine; Segs = @(@{ Text = $topLine; Color = $border }) })
    foreach ($r in $rows) {
        $padded = Pad-Row (Trim-Row $r ($w - 2)) ($w - 1)
        $segs = New-Object System.Collections.ArrayList
        [void]$segs.Add(@{ Text = '  │ '; Color = $border })
        foreach ($s in $padded) { [void]$segs.Add(@{ Text = [string]$s.Text; Color = $s.Color; Bg = $s.Bg }) }
        [void]$segs.Add(@{ Text = '│'; Color = $border })
        $arr = @($segs.ToArray())
        [void]$disp.Add(@{ Text = (Join-RowText $arr); Segs = $arr })
    }
    $botLine = '  └' + ('─' * $w) + '┘'
    [void]$disp.Add(@{ Text = $botLine; Segs = @(@{ Text = $botLine; Color = $border }) })
    return , @($disp.ToArray())
}

function Clear-ConsoleRows([int]$top, [int]$count) {
    $raw = $Host.UI.RawUI
    $rect = [Management.Automation.Host.Rectangle]::new(0, $top, $raw.BufferSize.Width - 1, $top + $count - 1)
    $blank = [Management.Automation.Host.BufferCell]::new(' ', $raw.ForegroundColor, $raw.BackgroundColor, 'Complete')
    $raw.SetBufferContents($rect, $blank)
}

# 一组方框共用同一块屏幕区域和行缓存。
function Write-LiveFrame($disp) {
    $raw = $Host.UI.RawUI
    $size = $raw.BufferSize
    $count = [math]::Min($disp.Count, $size.Height - 1)
    $prev = [math]::Min($script:LiveCount, [Console]::CursorTop)
    if ($prev -eq 0 -and [Console]::CursorLeft -ne 0) { Write-Host '' }
    # 先预留屏幕行，让必要的滚屏发生在定位之前。
    for ($i = $prev; $i -lt $count; $i++) { Write-Host '' }
    $height = [math]::Max($count, $prev)
    $top = [Console]::CursorTop - $height
    $width = Get-BoxWidth 0
    if ($prev -gt 0 -and $script:LiveBoxWidth -ne $width) { Clear-ConsoleRows $top $prev }
    $sameArea = ($script:LiveBoxWidth -eq $width -and $prev -gt 0 -and $script:LiveWidth -eq $size.Width -and $script:LiveTop -eq $top)
    $keys = @()
    if ($prev -gt $count) { Clear-ConsoleRows ($top + $count) ($prev - $count) }
    $wrote = $false
    for ($i = 0; $i -lt $count; $i++) {
        $key = ($disp[$i].Segs | ForEach-Object { "$($_.Color)|$($_.Bg)|$($_.Text)" }) -join [char]31
        $keys += $key
        if ($sameArea -and $i -lt $script:LiveKeys.Count -and $script:LiveKeys[$i] -ceq $key) { continue }
        $wrote = $true
        [Console]::SetCursorPosition(0, $top + $i)
        foreach ($seg in $disp[$i].Segs) {
            if ($seg.Bg) {
                Write-Host $seg.Text -NoNewline -ForegroundColor $seg.Color -BackgroundColor $seg.Bg
            } else {
                Write-Host $seg.Text -NoNewline -ForegroundColor $seg.Color
            }
        }
    }
    if ($wrote -or $prev -ne $count) { [Console]::SetCursorPosition(0, $top + $count) }
    $script:LiveTop = $top
    $script:LiveKeys = $keys
    $script:LiveWidth = $size.Width
    $script:LiveBoxWidth = $width
    $script:LiveCount = $count
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
        Write-LiveFrame $disp
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
    # 状态条与方框右缘对齐（框总宽 = 内宽 + 6 列）
    $want = $script:BoxW + 6
    if ($want -gt ($hw - 1)) { $want = $hw - 2 }
    if (-not $script:StatusW -or $script:StatusW -gt ($hw - 1)) { $script:StatusW = $want }
    $bw = $script:StatusW
    $line = '▌ ' + $text + ' '
    for ($n = 0; $n -lt 300 -and (Get-TextWidth $line) -gt ($bw - 2) -and $line.Length -gt 2; $n++) {
        $line = $line.Substring(0, $line.Length - 1)
    }
    $padN = $bw - 1 - (Get-TextWidth $line)
    if ($padN -lt 0) { $padN = 0 }
    $out = $line + (' ' * $padN) + '▐'
    try {
        $signature = "$fg|$bg|$out"
        if ($signature -ceq $script:LastStatus -and [Console]::CursorLeft -gt 0) { return }
        $script:LastStatus = $signature
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
    $script:LastStatus = ''
    try {
        $n = [math]::Min($script:LiveCount, [Console]::CursorTop)
        if ($n -gt 0) {
            $top = [Console]::CursorTop - $n
            Clear-ConsoleRows $top $n
            [Console]::SetCursorPosition(0, $top)
        }
    } catch { }
    $script:LiveCount = 0
}

# 数字输入解析：'1,3' → @(1,3)，只保留 1..$max 内的序号
function ConvertTo-IndexList([string]$text, [int]$max) {
    $out = New-Object System.Collections.ArrayList
    foreach ($piece in ($text -split ',')) {
        $n = 0
        if ([int]::TryParse($piece.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $max) { [void]$out.Add($n) }
    }
    return $out
}

# 菜单的显示行：游标行整条反色；多选在左边用 ● / ○ 标状态（不再用 [x]，也不和序号混在一起）
function New-MenuRows {
    param($Items, $Colors, [int]$Cur, $Marked, [bool]$Multi, [string]$Hint)
    # 框最宽只能到窗口右边界，否则整行折行会把原地重绘算乱
    $avail = $script:BoxW - 3
    try { if ([Console]::BufferWidth -gt 0) { $avail = [math]::Min($avail, [Console]::BufferWidth - 8) } } catch { }
    $avail = [math]::Max(24, $avail)
    $nw = ([string]$Items.Count).Length
    $rows = @()
    for ($k = 1; $k -le $Items.Count; $k++) {
        $isCur = ($k -eq $Cur)
        $isOn = ($Multi -and ($Marked -contains $k))
        $lead = '  '
        if ($isCur) { $lead = '❯ ' }
        $mark = ''
        if ($Multi) {
            if ($isOn) { $mark = '● ' } else { $mark = '○ ' }
        }
        $prefix = $lead + $mark + ([string]$k).PadLeft($nw) + ' '
        $label = [string]$Items[$k - 1]
        if ($avail -gt 0) {
            $room = $avail - (Get-TextWidth $prefix)
            if ($room -gt 6) { $label = Cut-Text $label $room }
        }
        $text = $prefix + $label + ' '
        $fg = 'Gray'
        if ($Multi) { $fg = 'DarkGray' }
        if ($Colors -and $Colors.Count -ge $k -and $Colors[$k - 1]) { $fg = [string]$Colors[$k - 1] }
        if ($isOn) { $fg = 'White' }
        $seg = @{ Text = $text; Color = $fg; Bg = $null }
        if ($isCur) { $seg.Color = 'Black'; $seg.Bg = 'DarkCyan' }
        $rows += , @($seg)
    }
    if ($Hint) { $rows += , @(@{ Text = ('  ' + $Hint); Color = 'DarkGray'; Bg = $null }) }
    return , $rows
}

# 上下键菜单：↑↓ 移动、Enter 确定、Esc 取消；序号还在，敲 n 回车照样能直选（多个用逗号）。
# -Multi：空格勾选、a 全选/全不选，返回 int[]。
# -Quiet：不打印「已选」那一行（确认类菜单用）。
# 输出被重定向（无人值守）时退回「方框 + 输入序号」，脚本化调用行为不变。
function Read-Menu {
    param(
        [string]$Title,
        [string[]]$Items,
        [int]$Default = 1,
        [switch]$Multi,
        [string[]]$ItemColors = $null,
        [switch]$Quiet
    )
    $n = @($Items).Count
    if ($n -le 0) {
        if ($Multi) { return }
        return 0
    }

    # 输出被重定向（无人值守）或标准输入不是键盘时退回「方框 + 输入序号」
    $noKeys = [bool]$script:IsRedirected
    if (-not $noKeys) { try { $noKeys = [bool][Console]::IsInputRedirected } catch { $noKeys = $false } }
    # 屏幕缓冲区装不下整个菜单时，用完整的编号列表，保留所有选项。
    if (-not $noKeys) { $noKeys = ($n + 3 -ge [Console]::BufferHeight) }
    if ($noKeys) {
        $rows = @()
        for ($k = 1; $k -le $n; $k++) {
            $rows += [pscustomobject]@{ Text = ('{0}. {1}' -f $k, [string]$Items[$k - 1]); Color = 'Gray' }
        }
        Write-BoxRows $Title $rows
        while ($true) {
            $s = Read-Host '  序号（回车=默认，多个用逗号，a=全部）'
            if ([string]::IsNullOrWhiteSpace($s)) { $s = [string]$Default }
            $idx = @(ConvertTo-IndexList $s $n)
            if ($Multi -and $s -match '^\s*a\s*$') { $idx = @(1..$n) }
            if ($idx.Count -gt 0) {
                if ($Multi) { return $idx }
                return $idx[0]
            }
            Write-Host ('  请输入 1-{0}' -f $n) -ForegroundColor Yellow
        }
    }

    $cur = [math]::Min([math]::Max(1, $Default), $n)
    $marked = New-Object System.Collections.ArrayList
    $buf = ''
    $kaFail = 0
    while ($true) {
        $hint = '↑↓ 移动   Enter 确定   数字 直选   Esc 取消'
        if ($Multi) { $hint = '↑↓ 移动   空格 勾选   A 全部   Enter 确定   Esc 取消' }
        if ($buf) { $hint = $hint + '   输入 ' + $buf }
        $rows = New-MenuRows $Items $ItemColors $cur $marked ([bool]$Multi) $hint
        Show-LiveBox $Title $rows 'Cyan'

        do {
            $ka = $false
            try { $ka = [Console]::KeyAvailable } catch { $kaFail = $kaFail + 1 }
            if ($kaFail -ge 20) {
                # 没有真正的键盘句柄（被宿主接管等）：别死等，按默认值继续
                Clear-LiveBox
                Write-Host '  （键盘不可用，用默认值继续）' -ForegroundColor Yellow
                if ($Multi) { return @($cur) }
                return $cur
            }
            if (-not $ka) { Start-Sleep -Milliseconds 40 }
        } until ($ka)
        $key = [Console]::ReadKey($true)
        $kaFail = 0
        $name = $key.Key.ToString()
        $ch = [string]$key.KeyChar

        if ($name -eq 'UpArrow') { $cur = $cur - 1; if ($cur -lt 1) { $cur = $n }; continue }
        if ($name -eq 'DownArrow') { $cur = $cur + 1; if ($cur -gt $n) { $cur = 1 }; continue }
        if ($name -eq 'Home') { $cur = 1; continue }
        if ($name -eq 'End') { $cur = $n; continue }
        if ($name -eq 'PageUp') { $cur = [math]::Max(1, $cur - 10); continue }
        if ($name -eq 'PageDown') { $cur = [math]::Min($n, $cur + 10); continue }
        if ($name -eq 'Escape') {
            if ($buf) { $buf = ''; continue }
            Clear-LiveBox
            if ($Multi) { return }
            return 0
        }
        if ($name -eq 'Spacebar') {
            if ($Multi) {
                if ($marked -contains $cur) { [void]$marked.Remove($cur) } else { [void]$marked.Add($cur) }
            }
            continue
        }
        if ($ch -match '^[0-9,]$') {
            if ($buf.Length -lt 12) { $buf = $buf + $ch }
            continue
        }
        if ($Multi -and ($ch -eq 'a' -or $ch -eq 'A')) {
            if ($marked.Count -ge $n) { $marked.Clear() }
            else { $marked.Clear(); foreach ($k in 1..$n) { [void]$marked.Add($k) } }
            continue
        }
        if ($name -eq 'Enter') {
            $picks = @()
            if ($buf) {
                $picks = @(ConvertTo-IndexList $buf $n)
                $buf = ''
                if ($picks.Count -eq 0) { continue }
            } elseif ($Multi) {
                if ($marked.Count -gt 0) { $picks = @($marked | Sort-Object) } else { $picks = @($cur) }
            } else {
                $picks = @($cur)
            }
            Clear-LiveBox
            if (-not $Quiet) {
                $names = @($picks | ForEach-Object { '{0}. {1}' -f $_, [string]$Items[$_ - 1] })
                $bwMax = 0
                try { $bwMax = [math]::Max(40, [Console]::BufferWidth - 2) } catch { }
                $line = '  ✓ ' + $Title + ': ' + ($names -join '、')
                if ($bwMax -gt 0 -and (Get-TextWidth $line) -gt $bwMax) {
                    Write-Host ('  ✓ ' + $Title + ': 共 ' + $picks.Count + ' 个') -ForegroundColor DarkCyan
                    foreach ($nm in $names) { Write-Host ('     · ' + (Cut-Text $nm ($bwMax - 7))) -ForegroundColor DarkCyan }
                } else {
                    Write-Host $line -ForegroundColor DarkCyan
                }
            }
            if ($Multi) { return $picks }
            return $picks[0]
        }
    }
}

# 是/否：同样走菜单（← 选中即确认），不再手打 Y/N。
# -NoDefault 表示默认落在「否」上，回车就是不做。
function Read-Confirm {
    param([string]$Title, [switch]$NoDefault)
    $def = 1
    if ($NoDefault) { $def = 2 }
    $r = Read-Menu $Title @('是', '否') $def -Quiet
    if ($r -le 0) { return $false }
    return ($r -eq 1)
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
        # 兜底只改列：line 一起写会把高度打回 46 行（"高度又缩回去"就是这个）
        try { $null = & cmd.exe /c ("mode con cols={0}" -f $cols); $script:WinInfo.how = 'mode' } catch { }
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
    # 最后按像素再钉一次：改缓冲区、兜底 mode 命令都可能把窗口改小，收尾保证"宽度合适、高度拉满"
    try {
        $r9 = New-Object 'ComsolCli.Win2+RECT'
        if ([ComsolCli.Win2]::GetWindowRect($top, [ref]$r9)) {
            $pixW9 = [int][math]::Max(320, ($r9.Right - $r9.Left))
            $cur9W = 0
            try { $cur9W = [int][Console]::WindowWidth } catch { }
            $dw9 = 0
            if ($cur9W -gt 0 -and $script:WinInfo.cellW -gt 0) { $dw9 = [int][math]::Round(($cols - $cur9W) * $script:WinInfo.cellW) }
            [void][ComsolCli.Win2]::SetWindowPos($top, [IntPtr]::Zero, 0, $workTop, [int][math]::Max(320, $pixW9 + $dw9), $workH, 0)
            Start-Sleep -Milliseconds 150
            try { $script:WinInfo.got = ('{0}x{1}' -f [int][Console]::WindowWidth, [int][Console]::WindowHeight) } catch { }
        }
    } catch { }
    if ($script:WinDebug -or $env:COMSOL_EXPORT_WINDEBUG -eq '1') {
        Write-Host ('  [窗口] 目标 {0} 列，实得 {1}（{2}）· 每列 {3}px，每行 {4}px，可用高 {5}px' -f `
            $cols, $script:WinInfo.got, $script:WinInfo.how, $script:WinInfo.cellW, $script:WinInfo.cellH, $workH) -ForegroundColor DarkGray
    }
}

# 尽早定窗口尺寸：函数一就绪就调，别等后面算完配置——否则会先刷出字再改窗口，看起来跳一下
$script:WinCols = 0
if ($WinWidth -gt 0) { $script:WinCols = [int]$WinWidth }
Initialize-ConsoleWindow

$ScriptDir = $PSScriptRoot
$Root      = Split-Path -Parent $ScriptDir
$StoreDir  = Join-Path $env:LOCALAPPDATA 'comsol-export'
$StateDir  = Join-Path $StoreDir 'state'
$JobsDir = Join-Path $ScriptDir 'logs'
$RecipeDir = Join-Path $ScriptDir 'recipes'
$QueueFile = Join-Path $StateDir 'queue.json'
$ConfigFile = Join-Path $StateDir 'config.psd1'
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
    Write-Host '    -Mode <solve|export|watch>  求解并导出 / 导出模式 / 监视模式'
    Write-Host '    -ProgressStyle 1|2|3  进度样式：1 单行 / 2 方框仪表 / 3 阶段链'
    Write-Host '    -Cores <n>       每作业核数（默认按并发数分配）'
    Write-Host '    -Heap <6g>       每作业 Java 堆（默认共用可用内存的 70%）'
    Write-Host '    -WinWidth <n>    控制台宽度（列），默认 88；高度自动占满'
    Write-Host '    -WinDebug        打印窗口实际尺寸（排查“窗口没铺满”）'
    Write-Host '    -Resume          接管未完成作业，启动资源足够的待办'
    Write-Host '    -KillJob <ID>    终止指定活动作业，也接受队列历史序号'
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
    $names = @{}
    foreach ($b in $blocks) {
        $kind = [string]$b.Type
        if ($kind -notin @('global','spectrum','image','slice2d','eigenslice','bigtable','integral','modes')) { throw "未知导出类型 $kind" }
        if ($b.Name) {
            if ($b.Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "非法导出块文件名 $($b.Name)" }
            if ($names.ContainsKey($b.Name)) { throw "导出块重名 $($b.Name)" }
            $names[$b.Name] = $true
        }
        if ($b.ContainsKey('Allownan') -and [string]$b.Allownan -notin @('0','1')) { throw 'Allownan 取 0 或 1' }
        if ($b.ContainsKey('MaxModes') -and ([int]$b.MaxModes -lt 1)) { throw 'MaxModes 必须为正整数' }
        if ($kind -in @('global','spectrum','integral','modes')) {
            $expr = @(($b.Expr -join '|') -split '\|')
            $cols = @(($b.Cols -join '|') -split '\|')
            if ($expr.Count -ne $cols.Count -or ([bool]$b.Expr -ne [bool]$b.Cols) -or ($kind -eq 'global' -and -not $b.Expr)) {
                throw "块 $($b.Name) 的 Expr 与 Cols 必须成对"
            }
            if ($b.ContainsKey('Units') -and @(($b.Units -join '|') -split '\|').Count -ne $expr.Count) { throw 'Units 与 Expr 长度不同' }
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
    $cfg = @{ ComsolBatch = ''; Models = '' }
    if (Test-Path -LiteralPath $ConfigFile) {
        try {
            $c = Import-PowerShellDataFile -LiteralPath $ConfigFile
            foreach ($k in @('ComsolBatch', 'Models')) {
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
    $last = 1
    while ($true) {
        $cfg = Read-Config
        $md = if ([string]::IsNullOrWhiteSpace($cfg.Models)) { '<默认: <根目录>\model>' } else { $cfg.Models }
        Write-Host ''
        Write-Host ('  配置: ' + $ConfigFile) -ForegroundColor Cyan
        $items = @(
            ('COMSOL   : ' + $cfg.ComsolBatch),
            ('模型目录 : ' + $md),
            '重新扫描 COMSOL 安装',
            '退出'
        )
        $sel = Read-Menu '设置（回车=当前项，Esc=退出）' $items $last
        if ($sel -le 0 -or $sel -eq 4) { return }
        $last = $sel
        switch ($sel) {
            1 {
                $all = @(Find-Comsol)
                $all = @($all | Sort-Object -Unique)
                if ($all.Count -eq 0) { Write-Host '  没扫到，直接输入完整路径' -ForegroundColor Yellow; $cfg.ComsolBatch = Read-Host '  路径'; Save-Config $cfg; continue }
                $n = Read-Menu '选择 COMSOL 安装' $all 1
                if ($n -le 0) { continue }
                $cfg.ComsolBatch = $all[$n - 1]
                Save-Config $cfg
            }
            2 {
                $v = Read-Host '  模型目录（留空=根目录\model）'
                $cfg.Models = $v.Trim()
                Save-Config $cfg
            }
            3 {
                $all = @(Find-Comsol)
                $all = @($all | Sort-Object -Unique)
                Write-Host ('  扫到 {0} 个:' -f $all.Count) -ForegroundColor Cyan
                foreach ($a in $all) { Write-Host ('    ' + $a) }
            }
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
        $n = Read-Menu '选择 COMSOL 安装' $all 1
        if ($n -le 0) { throw '已取消版本选择' }
        $pick = $all[$n - 1]
    }
    $cfg = Read-Config
    $cfg.ComsolBatch = $pick
    Save-Config $cfg
    return $pick
}

function Read-QueueFile([string]$path) {
    $stream = [IO.File]::Open($path, 'Open', 'Read', [IO.FileShare]'ReadWrite, Delete')
    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
    try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if (-not $raw.TrimStart().StartsWith('[') -or -not $raw.TrimEnd().EndsWith(']')) { throw '队列 JSON 不完整' }
    $raw | ConvertFrom-Json | ForEach-Object { $_ }
}

function Get-Queue {
    $backup = $QueueFile + '.bak'
    if (-not [IO.File]::Exists($QueueFile) -and -not [IO.File]::Exists($backup)) { return }
    try { Read-QueueFile $QueueFile }
    catch {
        if (-not [IO.File]::Exists($backup)) { throw }
        $snapshot = @(Read-QueueFile $backup)
        if (-not $script:QueueRecovered) { Write-Warning '队列主文件损坏，已读取上一个完整快照。' }
        $script:QueueRecovered = $true
        $snapshot
    }
}


# ---------------- 作业状态 ----------------

# 只认启动命令中专属于该作业的完整参数；模型名和 PID 均可能复用。
function Test-JobCommand($process, [string]$dir) {
    if ($process.Name -like 'comsol*') {
        $switch = '-batchlog'
        $file = 'solve.log'
    } elseif ($process.Name -like 'java*') {
        $switch = 'ExportDriver'
        $file = 'job.properties'
    } else { return $false }
    $arg = [regex]::Escape((Join-Path $dir $file))
    return ([string]$process.CommandLine -match ('(?:^|\s)' + $switch + '\s+(?:"' + $arg + '"|' + $arg + ')(?=\s|$)'))
}

function Test-JobAlive($procId, $jobDir, $expectedStart) {
    if (-not $procId) { return $false }
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $proc -or ($proc.ProcessName -notlike 'comsol*' -and $proc.ProcessName -notlike 'java*')) { return $false }
    if ($expectedStart) {
        try {
            $start = [datetimeoffset]::Parse([string]$expectedStart).UtcDateTime
            if ([math]::Abs(($proc.StartTime.ToUniversalTime()-$start).TotalMilliseconds) -gt 2) { return $false }
        } catch { }
    }
    $p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $procId) -ErrorAction SilentlyContinue
    # 无法读取命令行时可以继续观察，但不能据此终止进程。
    if (-not $p.CommandLine) { return $true }
    return (Test-JobCommand $p $jobDir)
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
        if ($entry) { $alive = Test-JobAlive $entry.pid $dir $entry.workerStartUtc }
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
$script:ExpectedDriverVersion = 'v1.9.0'

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

function Assert-DriverRuntime([string]$javaPath, [string]$classPath, [int]$timeoutMs = 60000) {
    # WinPS 的同步原生命令会共享菜单控制台。预检只接收参数，并通过管道返回诊断。
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $javaPath
    $start.Arguments = '-cp "' + $classPath + '" ExportDriver --check-runtime'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($start)
    try {
        $proc.StandardInput.Close()
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($timeoutMs)) {
            # 仅清理本次启动的预检进程，避免因刚好自行退出而隐藏超时原因。
            try { $proc.Kill() } catch [InvalidOperationException] { }
            [void]$proc.WaitForExit(1000)
            throw ('COMSOL 驱动预检超时（{0:g} 秒），请核对 Java 路径 {1}' -f ($timeoutMs/1000),$javaPath)
        }
        $version = $stdout.GetAwaiter().GetResult().Trim()
        $reason = $stderr.GetAwaiter().GetResult().Trim()
        if ($proc.ExitCode -ne 0 -or ($version -split '\s+')[0] -ne $script:ExpectedDriverVersion) {
            throw ('COMSOL 驱动预检失败（退出码 {0}，期望 {1}）。{2} {3}' -f $proc.ExitCode,$script:ExpectedDriverVersion,$version,$reason)
        }
    } finally { $proc.Dispose() }
}

function Get-ResourceBudget([int]$count) {
    $cpu = [Environment]::ProcessorCount
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $freeMB = [math]::Floor([double]$os.FreePhysicalMemory / 1024)
    } catch {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $freeMB = [math]::Floor(([Microsoft.VisualBasic.Devices.ComputerInfo]::new()).AvailablePhysicalMemory / 1MB)
    }
    $pool = [int][math]::Floor($freeMB * 0.7)
    $request = $Heap
    if (-not $request) { $request = $env:COMSOL_EXPORT_XMX }
    $heapMB = 0
    if ($request) {
        if ($request -notmatch '^(\d+)([kKmMgG]?)$') { throw 'Heap 格式示例 8g 或 2048m' }
        $factor = @{'g'=1024; 'm'=1; 'k'=(1/1024); ''=(1/1MB)}[$Matches[2].ToLowerInvariant()]
        $heapMB = [int][math]::Ceiling([double]$Matches[1] * $factor)
        if ($heapMB -le 0 -or $heapMB -gt $pool) { throw ("请求堆 {0} MiB，当前总预算 {1} MiB" -f $heapMB,$pool) }
    }
    if ($Cores -lt 0 -or $Cores -gt $cpu -or $pool -lt 1) { throw '核数或可用内存超出本机预算' }
    $minHeap = 4096
    if ($heapMB) { $minHeap = $heapMB }
    $slots = [int][math]::Max(1,[math]::Min([math]::Max(1,$count),[math]::Min(
            [math]::Floor($cpu / [math]::Max(1,$Cores)), [math]::Floor($pool / $minHeap))))
    if (-not $heapMB) {
        $share = [math]::Floor($pool/$slots)
        if ($share -ge 256) { $share -= $share % 256 }
        $heapMB = [int][math]::Min(65536,$share)
    }
    $perCpu = $Cores
    if (-not $perCpu) { $perCpu = [int][math]::Floor($cpu/$slots) }
    return @{ slots=$slots; cores=$perCpu; heapMB=$heapMB; cpu=$cpu; pool=$pool }
}

function Get-HeapArg($job) {
    if ($job -and $job.heapMB) { return ('-Xmx' + $job.heapMB + 'm') }
    return ('-Xmx' + (Get-ResourceBudget 1).heapMB + 'm')
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
    if ($spec['solvedfile']) { return [string]$spec['solvedfile'] }
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
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite, Delete')
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

# 仅读取所选研究的启用步骤，不启动 COMSOL，也不读取解向量。
function Get-StudyProgressKind([string]$modelPath, [string]$studyTag) {
    $file = $archive = $stream = $reader = $subtree = $null
    try {
        Add-Type -AssemblyName System.IO.Compression
        $file = [IO.File]::Open($modelPath, 'Open', 'Read', [IO.FileShare]'ReadWrite, Delete')
        $archive = [IO.Compression.ZipArchive]::new($file, 'Read', $true)
        $entry = $archive.GetEntry('dmodel.xml')
        if (-not $entry) { return 'unknown' }
        $stream = $entry.Open()
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.MaxCharactersInDocument = 67108864
        $reader = [Xml.XmlReader]::Create($stream, $settings)
        if (-not $reader.ReadToFollowing('StudyList')) { return 'unknown' }
        $subtree = $reader.ReadSubtree()
        $doc = [Xml.XmlDocument]::new()
        $doc.XmlResolver = $null
        $doc.Load($subtree)
        $studies = @($doc.DocumentElement.SelectNodes('Study') | Where-Object { -not $studyTag -or $_.GetAttribute('tag') -eq $studyTag })
        if ($studies.Count -ne 1) { return 'unknown' }
        $ops = @(foreach ($step in $studies[0].SelectNodes('StudyFeatureList/StudyFeature')) {
            if ($step.SelectSingleNode('entityFlags').InnerText -notmatch 'DISABLED') {
                $step.GetAttribute('op')
            }
        })
        if ($ops -match '^Eigen(?:frequency|value)') { return 'eigen' }
        if (($ops -match '^(Wavelength|Frequency)$') -and -not ($ops -notmatch '^(Wavelength|Frequency|Parametric)$')) { return 'sweep' }
    } catch {
        # 旧格式、读锁或未知研究类型均退回阶段显示。
    } finally {
        foreach ($resource in @($subtree,$reader,$stream,$archive,$file)) { if ($resource) { $resource.Dispose() } }
    }
    return 'unknown'
}

$script:SolveKinds = @{}
function Get-SolveLogState($job) {
    $o = @{ Pct = -1; Stage = ''; Param = ''; Eigen = $false; Iteration = ''; Opened = $false; Running = $false }
    $txt = Read-FileTailText (Join-Path $job.jobDir 'solve.log') 131072
    if ([string]::IsNullOrWhiteSpace($txt)) { return $o }
    if ($txt -match '正在打开文件|Opening file') { $o.Opened = $true }
    if ($txt -match '正在运行|研究\d|参数化扫描|Running:') { $o.Running = $true }
    $ms = [regex]::Matches($txt, '(?im)^[ \t]*(?:当前进度|Current progress)[:：]\s*(\d+)\s*%[^\S\r\n]*-[^\S\r\n]*([^\r\n]*)')
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
    # 只匹配求解器消息，文件名和模型名不作为研究类型证据。
    $eigenSolver = '特征值求解器|特征频率求解器|Eigen(?:value|frequency)\s+Solver'
    $o.Eigen = $o.Stage -match '特征频率|特征值|eigenfrequenc|eigenvalue|\bARPACK\b|\bFEAST\b' -or
               $txt -match ("(?im)^[ \t]*(?:(?:$eigenSolver)\b|<[-]+[^\r\n]*(?:$eigenSolver|特征频率|Eigenfrequency))")
    if ($o.Eigen) {
        $o.Running = $true
        if (-not $o.Stage) { $o.Stage = '特征求解' }
    }
    # Nconv 是本次迭代已收敛的特征值数，不是总工作量。
    $tables = [regex]::Matches($txt, '(?im)^[ \t]*(?<header>Iter[ \t]+[^\r\n]*\bNconv\b[^\r\n]*)\r?\n(?<rows>(?:[ \t]*\d+[ \t]+[^\r\n]+(?:\r?\n|$))*)')
    if ($tables.Count) {
        $o.Eigen = $true
        $table = $tables[$tables.Count - 1]
        $columns = $table.Groups['header'].Value.Trim() -split '\s+'
        $index = [array]::IndexOf([string[]]@($columns | ForEach-Object { $_.ToLowerInvariant() }), 'nconv')
        $lastRow = ($table.Groups['rows'].Value.Trim() -split '\r?\n')[-1].Trim() -split '\s+'
        if ($lastRow.Count -eq $columns.Count -and $lastRow[0] -match '^\d+$' -and $lastRow[$index] -match '^\d+$') {
            $o.Iteration = '最近迭代 ' + $lastRow[0] + ' · 已收敛特征值 ' + $lastRow[$index]
            $o.Running = $true
        }
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
        elseif ($ln -match '^unit=(.*)$') { $o.Unit = $Matches[1] }
        elseif ($ln -match '^block=(\d+)') { $o.Block = [int]$Matches[1] }
        elseif ($ln -match '^blocks=(\d+)') { $o.Blocks = [int]$Matches[1] }
        elseif ($ln -match '^label=(.*)$') { $o.Label = $Matches[1] }
    }
    return $o
}

$script:ProgState = @{}
# 每个作业单独保存最近两分钟的观测，每五秒最多留一个样本。
function Get-RecentEta($job, [string]$series, [double]$done, [double]$total, [datetime]$now) {
    if ($done -lt 0 -or $total -le 0) { return -1 }
    $key = [string]$job.jobDir
    $st = $script:ProgState[$key]
    if (-not $st -or $st.Series -ne $series -or $st.Total -ne $total -or $done -lt $st.Last) {
        $st = @{ Series = $series; Total = $total; Last = $done; Samples = [Collections.Queue]::new(); Saved = [datetime]::MinValue }
        $script:ProgState[$key] = $st
    }
    $st.Last = $done
    $samples = $st.Samples
    while ($samples.Count -and ($now - $samples.Peek().At).TotalSeconds -gt 120) { [void]$samples.Dequeue() }
    if (($now - $st.Saved).TotalSeconds -ge 5) {
        $samples.Enqueue(@{ At = $now; Value = $done })
        $st.Saved = $now
    }
    if ($done -ge $total) { return 0 }
    if (-not $samples.Count) { return -1 }
    $base = $samples.Peek()
    $span = ($now - $base.At).TotalSeconds
    $delta = $done - $base.Value
    if ($span -lt 10 -or $delta -le 0) { return -1 }
    return (($total - $done) * $span / $delta)
}

function Parse-DateOrNull($s) {
    if (-not $s) { return $null }
    try { return [datetime]::Parse([string]$s) } catch { return $null }
}

# 求解按日志百分比采样，导出按当前块的已取解数采样。
function Get-ProgressInfo($job) {
    $phase = Get-JobPhase $job
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
    $stageOnly = $false
    $phaseLabel = '导出'
    if ($phase -eq 'solve') {
        $s = Get-SolveLogState $job
        $stageIdx = Get-StageIndex $s.Stage
        $stageName = Get-StageLabel $s.Stage
        $key = [string]$job.jobDir
        if ($s.Eigen) { $script:SolveKinds[$key] = 'eigen' }
        if (-not $script:SolveKinds.ContainsKey($key)) {
            $kind = [string]$job.solveKind
            if (-not $kind) {
                $spec = Read-JobSpec $key
                $kind = Get-StudyProgressKind $job.model $spec['study']
            }
            $script:SolveKinds[$key] = $kind
        }
        $kind = $script:SolveKinds[$key]
        $phaseLabel = '求解'
        if ($kind -eq 'eigen') { $phaseLabel = '特征求解' }
        $stageOnly = $kind -ne 'sweep'
        if (-not $stageOnly) { $pct = $s.Pct }
        if ($stageOnly -and $s.Stage) { $stageName = $s.Stage }
        if ($s.Running) { $detail = $stageName } elseif ($s.Opened) { $detail = '打开模型（大模型要几分钟）' } else { $detail = '启动 comsolbatch' }
        if ($s.Iteration) {
            if (-not $s.Stage) { $detail = '特征求解' }
            $detail += ' · ' + $s.Iteration
        }
        if ($s.Param) { $detail = $detail + ' · ' + $s.Param }
    } else {
        $e = Get-ExportState $job
        $solDone = $e.Done; $solTotal = $e.Total
        if ($e.Total -gt 0 -and $e.Done -ge 0) {
            $pct = [int][math]::Min(100, [math]::Round(100.0 * $e.Done / $e.Total))
        }
        if ($e.Unit -eq 'files') { $detail = ('已写 ' + $e.Done + '/' + $e.Total + ' 个文件') }
        elseif ($e.Total -gt 0) { $detail = ('已取 ' + $e.Done + '/' + $e.Total + ' 个解') }
        else { $detail = '打开模型（大模型要几分钟）' }
        if ($e.Label) { $detail = $detail + ' · ' + $e.Label }
        if ($e.Blocks -gt 0 -and $e.Block -gt 0) {
            $fraction = 0
            if ($e.Total -gt 0) { $fraction = [math]::Max(0.0,[math]::Min(1.0,$e.Done/[double]$e.Total)) }
            $pct = [int][math]::Floor(100.0*($e.Block-1+$fraction)/$e.Blocks)
        }
        $stageName = '导出'
    }

    if ($stageOnly) { $eta = -1 }
    elseif ($phase -eq 'solve') { $eta = Get-RecentEta $job 'solve' $pct 100 $now }
    else { $eta = Get-RecentEta $job 'export-blocks' $pct 100 $now }

    $phaseNo = 1; $phaseAll = 1
    if ([string]$job.mode -ne 'export') { $phaseAll = 2; if ($phase -eq 'export') { $phaseNo = 2 } }

    $fg = 'Black'; $bg = 'DarkYellow'
    if ($phase -eq 'export') { $bg = 'DarkCyan' }

    return [pscustomobject]@{
        Phase = $phase
        PhaseLabel = $phaseLabel
        StageOnly = $stageOnly
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
        SolDone = $solDone
        SolTotal = $solTotal
        Fg = $fg
        Bg = $bg
    }
}

function Format-TimeLine($info) {
    # 只留剩余时间：已用/总时长由调用方各写一次，不再重复
    if ($info.StageOnly) { return '剩余时间不可估' }
    if ($info.Phase -eq 'export') { return ('导出剩 ' + (Format-Eta $info.Eta)) }
    return ('求解剩 ' + (Format-Eta $info.Eta))
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

function Get-PhaseTag($info) {
    if ($info.PhaseAll -gt 1) { return ($info.PhaseLabel + ' ' + $info.PhaseNo + '/' + $info.PhaseAll) }
    return $info.PhaseLabel
}

function Get-PctText($info) {
    if ($info.StageOnly) { return '阶段监视' }
    if ($info.Pct -lt 0) { return '  ?%' }
    return ((('{0,3}' -f $info.Pct)) + '%')
}

# 样式 1：单行（窄窗口/最省屏）
function Render-Progress1($info, [string]$jobName, $ord, $total) {
    $bar = '[' + (Get-Bar $info.Pct 18) + ']'
    $etaTxt = Format-TimeLine $info
    $tail = 'Q退出 K终止'
    if ([int]$total -gt 1) { $tail = ('作业 ' + $ord + '/' + $total + ' · ' + $tail) }
    $txt = '▌【' + (Get-PhaseTag $info) + '】' + $bar + ' ' + (Get-PctText $info) + ' ' + (Format-Elapsed $info.TotalElapsed) + ' · ' + $etaTxt + ' · ' + $info.Detail + ' · ' + $tail
    Show-StatusLine $txt $info.Fg $info.Bg
}

# 样式 2：方框仪表（与 CLI 其它框一致）
function Render-Progress2($info, [string]$jobName, $ord, $total) {
    $seg = (Get-BarSeg $info.Pct 30)
    # 固定内宽（$script:BoxW - 2）：避免每秒刷新时框线抖动；进度条两段同字形，靠颜色区分
    $rows = @(
        (Pad-Row @(@{ Text = ('作业   ' + $ord + '/' + [math]::Max(1, $total) + '   ' + $jobName); Color = $info.Bg }) ($script:BoxW - 2)),
        (Pad-Row @(
                @{ Text = '进度   '; Color = $info.Bg },
                $seg[0], $seg[1],
                @{ Text = ('   ' + (Get-PctText $info)); Color = $info.Bg }
            ) ($script:BoxW - 2)),
        (Pad-Row @(@{ Text = ('阶段   ' + (Get-PhaseTag $info) + ' · ' + $info.Detail); Color = $info.Bg }) ($script:BoxW - 2)),
        (Pad-Row @(@{ Text = ('时间   ' + (Format-Elapsed $info.TotalElapsed) + '   ·   ' + (Format-TimeLine $info)); Color = $info.Bg }) ($script:BoxW - 2)),
        (Pad-Row @(@{ Text = '按键   Q 退出监视   K 终止作业'; Color = $info.Bg }) ($script:BoxW - 2))
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
            ) ($script:BoxW - 2)),
        (Pad-Row @(@{ Text = $chain; Color = $info.Bg }) ($script:BoxW - 2)),
        (Pad-Row @(@{ Text = $info.Detail; Color = $info.Bg }) ($script:BoxW - 2)),
        (Pad-Row @(@{ Text = ((Format-Elapsed $info.TotalElapsed) + '   ·   ' + (Format-TimeLine $info) + '   ·   Q 退出监视  K 终止'); Color = $info.Bg }) ($script:BoxW - 2))
    )
    Show-LiveBox $jobName $rows $info.Bg
}

function Write-JobProgressLog($job, $info) {
    $sig = $info.Phase + '|' + [math]::Floor($info.Pct / 10)
    if ($info.StageOnly) { $sig = $info.PhaseLabel + '|' + $info.Detail }
    if ($script:JobLogSig[$job.jobDir] -eq $sig) { return }
    $script:JobLogSig[$job.jobDir] = $sig
    Write-Host ('  [' + (Split-Path -Leaf $job.jobDir) + '] ' + (Get-PhaseTag $info) + ' ' + (Get-PctText $info) + ' · ' + $info.Detail)
}

function Show-BatchProgress($jobs) {
    $textMode = $script:IsRedirected -or $script:BatchTextMode
    if (-not $textMode) {
        # 每框至少三行；预留一行提示和一行光标，矮窗口可翻页。
        $height = [math]::Min([Console]::WindowHeight, [Console]::BufferHeight)
        $room = [math]::Max(3, $height - 2)
        $expanded = ($jobs.Count * 4 -le $room)
        $perPage = [math]::Max(1, [math]::Floor($room / 3))
        if ($expanded) { $perPage = $jobs.Count }
        $pages = [int][math]::Ceiling($jobs.Count / $perPage)
        $script:BatchPage = [math]::Min($pages - 1, [math]::Max(0, $script:BatchPage))
        $first = $script:BatchPage * $perPage
        $frame = @()
    }
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        $job = $jobs[$i]
        $detail = ''
        $color = 'Gray'
        if ($job.status -eq 'running') {
            $info = Get-ProgressInfo $job
            if ($textMode) { Write-JobProgressLog $job $info; continue }
            $status = (Get-PhaseTag $info) + '  ' + (Get-PctText $info) + ' · ' + (Format-TimeLine $info)
            if ($info.StageOnly) { $status = $info.PhaseLabel + ' · 已用 ' + (Format-Elapsed $info.TotalElapsed) + ' · ' + (Format-TimeLine $info) }
            $detail = $info.Detail
            if ($job.cancelMessage) { $status = $job.cancelMessage; $color = 'Yellow' }
        } else {
            if ($textMode) { continue }
            switch ($job.status) {
                'done'   { $status = '已完成'; $color = 'Green' }
                'failed' { $status = '失败 · ' + $job.exitcode; $color = 'Red' }
                'killed' { $status = '已终止'; $color = 'Yellow' }
                default  { $status = '启动中' }
            }
        }
        if ($i -lt $first -or $i -ge ($first + $perPage)) { continue }
        $name = [IO.Path]::GetFileNameWithoutExtension([string]$job.model)
        $title = ('{0}/{1}  {2}' -f ($i + 1), $jobs.Count, $name)
        if (-not $expanded -and $detail) { $status += ' · ' + $detail }
        $rows = @(@{ Text = $status; Color = $color })
        if ($expanded) { $rows += @{ Text = $detail; Color = 'DarkGray' } }
        $frame += (New-BoxDisplay $title $rows 'Cyan')
    }
    if ($textMode) { return }
    $hint = if ($script:WatchOnly) { 'Q 退出只读监视' } else { 'Q 退出监视   K 终止作业' }
    if ($pages -gt 1) { $hint = ('PgUp/PgDn 翻页 {0}/{1}   ' -f ($script:BatchPage + 1), $pages) + $hint }
    $width = Get-BoxWidth 0
    $frame += @{ Segs = @(@{ Text = '  ' + (Pad-Text (Cut-Text $hint $width) $width); Color = 'DarkGray' }) }
    try { Write-LiveFrame $frame }
    catch {
        Clear-LiveBox
        $script:BatchTextMode = $true
        Write-Host '  控制台无法定位光标，改用作业状态日志。'
    }
}

function Show-ProgressJob($job, $ord, $total) {
    $info = Get-ProgressInfo $job
    $leaf = [string](Split-Path -Leaf $job.jobDir)
    $nm = $leaf -replace '^\d{12}_', ''
    if ($nm.Length -gt 40) { $nm = $nm.Substring(0, 40) }
    $style = '2'
    if ($script:PStyle) { $style = [string]$script:PStyle }
    if ($script:IsRedirected) { Write-JobProgressLog $job $info; return }
    if ($info.StageOnly) {
        $time = '已用 ' + (Format-Elapsed $info.TotalElapsed) + ' · ' + (Format-TimeLine $info)
        if ($style -eq '1') { Show-StatusLine ($info.PhaseLabel + ' · ' + $time + ' · ' + $info.Detail) $info.Fg $info.Bg }
        else { Show-LiveBox ($info.PhaseLabel + ' · ' + $nm) @($info.Detail, $time, 'Q 退出监视   K 终止作业') $info.Bg }
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
    if ([IO.File]::Exists($solved) -or [IO.Path]::GetFullPath($model) -eq [IO.Path]::GetFullPath($solved)) {
        $job.status = 'failed'
        Set-JobProp $job 'exitcode' 'solve-output-exists'
        return
    }
    foreach ($f in @((Join-Path $job.jobDir 'solve.log'), (Join-Path $job.jobDir 'solve.out'), (Join-Path $job.jobDir 'solve.err'))) {
        try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { }
    }
    $logF = Join-Path $job.jobDir 'solve.log'
    $outF = Join-Path $job.jobDir 'solve.out'
    $errF = Join-Path $job.jobDir 'solve.err'
    $argList = @('-inputfile', ('"' + $model + '"'), '-outputfile', ('"' + $solved + '"'),
                 '-batchlog', ('"' + $logF + '"'), '-batchlogout', '-alivetime', '5')
    if (-not [string]::IsNullOrWhiteSpace($study)) { $argList += @('-study', ('"' + $study + '"')) }
    if ($job.cores -gt 0) { $argList += @('-np', [string]$job.cores) }
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
    try { Set-JobProp $job 'workerStartUtc' ($proc.StartTime.ToUniversalTime().ToString('o')) }
    catch { Set-JobProp $job 'workerStartUtc' '' }
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


function Write-Handoff($q) {
    $changedBatches = @{}
    $changes = @()
    foreach ($job in $q) {
        if (-not $job.resultDir) { continue }
        if ($script:HandoffStates[$job.jobDir] -ceq $job.status) { continue }
        $changes += $job
        if ($job.batchDir -and $job.batchDir -ne $job.resultDir) { $changedBatches[$job.batchDir] = $true }
        $dir = [string]$job.resultDir
        $manifest = Join-Path $dir 'EXPORT_MANIFEST.md'
        if ($job.status -in @('failed','killed','done')) {
            $jobPath = [IO.Path]::GetFullPath([string]$job.jobDir)
            $render = [IO.Path]::GetFullPath((Join-Path $jobPath 'render-work'))
            if ([IO.Path]::GetDirectoryName($jobPath) -eq [IO.Path]::GetFullPath($JobsDir) -and
                [IO.Path]::GetDirectoryName($render) -eq $jobPath -and [IO.Directory]::Exists($render)) {
                try { Remove-Item -LiteralPath $render -Recurse -Force } catch { Write-Warning ('渲染临时目录待清理 ' + $render) }
            }
            if ($job.status -ne 'done' -and [IO.Directory]::Exists($dir)) {
                foreach ($part in [IO.Directory]::EnumerateFiles($dir,'csv-*.part')) {
                    try { [IO.File]::Delete($part) } catch { Write-Warning ('未完成表格待清理 ' + $part) }
                }
            }
        }
        if ($job.status -in @('failed','killed') -and -not [IO.File]::Exists($manifest)) {
            [IO.Directory]::CreateDirectory($dir) | Out-Null
            $lines = @('# Export manifest', '', ('- 状态 ' + $job.status), ('- 作业 ' + (Split-Path -Leaf $job.jobDir)),
                       ('- 模型 ' + $job.model), ('- 配方 ' + $job.recipe), ('- 阶段 ' + $job.phase),
                       ('- 退出原因 ' + $job.exitcode), ('- 诊断目录 ' + $job.jobDir), '', '## 已落盘文件', '')
            $files = @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Extension -in @('.csv','.png') })
            if ($files.Count) { $lines += @($files | ForEach-Object { '- ' + $_.Name + ' · ' + $_.Length + ' bytes' }) }
            else { $lines += '- 无已完成产物' }
            $spec = Join-Path $job.jobDir 'job.properties'
            if ([IO.File]::Exists($spec)) { $lines += @('', '## 作业规格', '', '~~~~text') + [IO.File]::ReadAllLines($spec) + @('~~~~') }
            Write-ManifestText $manifest $lines
        }
    }
    $batches = @($q | Where-Object { $_.batchDir -and $changedBatches.ContainsKey($_.batchDir) } | Group-Object -Property batchDir)
    foreach ($batch in $batches) {
        $lines = @('# Batch export manifest', '', '| 作业 | 状态 | 交付清单 |', '|---|---|---|')
        foreach ($job in $batch.Group) {
            $leaf = Split-Path -Leaf $job.resultDir
            $link = '待交付'
            if ([IO.File]::Exists((Join-Path $job.resultDir 'EXPORT_MANIFEST.md'))) { $link = '[EXPORT_MANIFEST.md](<' + $leaf + '/EXPORT_MANIFEST.md>)' }
            $lines += ('| ' + $leaf + ' | ' + $job.status + ' | ' + $link + ' |')
        }
        [IO.Directory]::CreateDirectory($batch.Name) | Out-Null
        Write-ManifestText (Join-Path $batch.Name 'EXPORT_MANIFEST.md') $lines
    }
    foreach ($job in $changes) {
        if ($job.status -in @('done','failed','killed') -and [IO.Directory]::Exists($job.jobDir)) {
            [IO.File]::WriteAllText((Join-Path $job.jobDir 'handoff'), [string]$job.status)
        }
        $script:HandoffStates[$job.jobDir] = $job.status
    }
}

function Write-ManifestText($path, $lines) {
    $content = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    if ([IO.File]::Exists($path) -and [IO.File]::ReadAllText($path) -ceq $content) { return }
    $tmp = $path + '.tmp'
    [IO.File]::WriteAllText($tmp,$content)
    if ([IO.File]::Exists($path)) { [IO.File]::Replace($tmp,$path,[Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($tmp,$path) }
}

function Save-Queue($q) {
    $jsonText = ConvertTo-Json -InputObject @($q) -Depth 6
    $qDir = Split-Path -Parent $QueueFile
    if (-not (Test-Path -LiteralPath $qDir)) { New-Item -ItemType Directory -Path $qDir -Force | Out-Null }
    if (-not $script:QueueRecovered -and $script:SavedQueueJson -ceq $jsonText) { return }
    $tmp = $QueueFile + '.tmp'
    $stream = [IO.File]::Open($tmp, 'Create', 'Write', 'None')
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($jsonText)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    if ([IO.File]::Exists($QueueFile)) {
        for ($attempt = 0; ; $attempt++) {
            try {
                if ($script:QueueRecovered) { [IO.File]::Replace($tmp, $QueueFile, [Management.Automation.Language.NullString]::Value) }
                else { [IO.File]::Replace($tmp, $QueueFile, ($QueueFile + '.bak')) }
                break
            } catch {
                # 某些外部读取器短暂禁止替换文件。
                $code = $_.Exception.GetBaseException().HResult -band 0xffff
                if ($attempt -ge 9 -or $code -notin @(5,32,33)) { throw }
                Start-Sleep -Milliseconds 50
            }
        }
    } else { [IO.File]::Move($tmp, $QueueFile) }
    $script:QueueRecovered = $false
    $script:SavedQueueJson = $jsonText
    Write-Handoff $q
}

function Clear-JobLock($job) {
    # 导出使用 loadCopy，求解写专属输出。输入模型旁的锁属于打开该模型的程序。
    if ($job.model -and [IO.File]::Exists(([string]$job.model + '.lock'))) { return '输入模型有外部锁，已保留' }
    return '无输入锁'
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
    $argStr = (Get-HeapArg $job) + ' -XX:ActiveProcessorCount=' + $job.cores + ' -Dfile.encoding=UTF-8 -Dsun.stdout.encoding=UTF-8 -Dsun.stderr.encoding=UTF-8 -Dstdout.encoding=UTF-8 -Dstderr.encoding=UTF-8 -cp "' + $cp + '" ExportDriver "' + (Join-Path $job.jobDir 'job.properties') + '"'
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
    try { Set-JobProp $job 'workerStartUtc' ($proc.StartTime.ToUniversalTime().ToString('o')) }
    catch { Set-JobProp $job 'workerStartUtc' '' }
    $job.status = 'running'
}

function Get-JobProcIds($job) {
    $workers = Get-CimInstance Win32_Process -Filter "Name LIKE 'comsol%' OR Name LIKE 'java%'" -ErrorAction Stop
    foreach ($worker in $workers) {
        if (-not (Test-JobCommand $worker $job.jobDir)) { continue }
        if ([int]$worker.ProcessId -eq [int]$job.pid -and $job.workerStartUtc) {
            $expected = [datetimeoffset]::Parse([string]$job.workerStartUtc).UtcDateTime
            if (-not $worker.CreationDate -or [math]::Abs(($worker.CreationDate.ToUniversalTime()-$expected).TotalMilliseconds) -gt 2) { continue }
        }
        $worker
    }
}

function Stop-OneJob($job) {
    [IO.File]::WriteAllText((Join-Path $job.jobDir 'killed'), (Get-Date).ToString('o'))
    try {
        $candidates = @(Get-JobProcIds $job)
        if ($job.pid) { $candidates = @($candidates | Where-Object { $_.ProcessId -eq $job.pid }) }
        if ($candidates.Count -gt 1) { return '终止待确认：存在多个匹配进程' }
        foreach ($candidate in $candidates) {
            $procId = [int]$candidate.ProcessId
            # 再读创建时间与命令行，防止 PID 复用。
            $worker = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $procId) -ErrorAction Stop
            if ($worker -and $worker.CreationDate -eq $candidate.CreationDate -and (Test-JobCommand $worker $job.jobDir)) {
                & taskkill.exe /PID $procId /T /F 2>&1 | Out-Null
            }
        }
        if (@(Get-JobProcIds $job).Count -or (Test-JobAlive $job.pid $job.jobDir $job.workerStartUtc)) {
            return '等待确认进程退出'
        }
    } catch { return ('终止待确认：' + $_.Exception.Message) }
    Set-JobProp $job 'status' 'killed'
    Set-JobProp $job 'pid' 0
    $note = Clear-JobLock $job
    return ('已终止；模型锁: ' + $note)
}

function Invoke-KillMenu {
    Clear-LiveBox
    $q = @(Get-Queue)
    $run = @($q | Where-Object { $_.status -eq 'running' -and (Test-JobAlive $_.pid $_.jobDir $_.workerStartUtc) })
    Write-Host ''
    if ($run.Count -eq 0) {
        Write-Host '  当前没有”本 CLI 启动且仍在运行”的作业，无法终止。' -ForegroundColor Yellow
        return
    }
    $items = @()
    for ($j = 0; $j -lt $run.Count; $j++) {
        $items += ((Split-Path -Leaf $run[$j].jobDir) + '   PID ' + $run[$j].pid)
    }
    $n = Read-Menu '终止哪个作业（Esc=取消）' $items 1
    if ($n -le 0) { Write-Host '  已取消。'; return }
    $job = $run[$n - 1]
    if (-not (Read-Confirm ('终止 ' + (Split-Path -Leaf $job.jobDir) + '？只终止这一个') -NoDefault)) { Write-Host '  已取消。' -ForegroundColor Yellow; return }
    [IO.File]::WriteAllText((Join-Path $job.jobDir 'killed'), (Get-Date).ToString('o'))
    Write-Host '  已请求终止所选作业。' -ForegroundColor Yellow
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
    return ('{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds)
}


function Test-SchedulerPresent {
    $lock = Join-Path $StateDir 'cli.lock'
    if (-not [IO.File]::Exists($lock)) { return $false }
    try {
        $stream = [IO.File]::Open($lock,'Open','Read','Read')
        $stream.Dispose()
        return $false
    } catch [IO.IOException] { return (($_.Exception.GetBaseException().HResult -band 0xffff) -in @(32,33)) }
}

function Watch-Queue {
    $script:WatchOnly = $true
    $script:JobLogSig = @{}
    $script:BatchPage = 0
    try {
        $initial = @(Get-Queue | Where-Object { $_.status -in @('running','pending') })
        if (-not $initial.Count) { Write-Host '  没有运行或待办作业。'; return }
        $dirs = @($initial | ForEach-Object { Write-Host ('  ' + (Split-Path -Leaf $_.jobDir) + '  ' + $_.status); $_.jobDir })
        while ($true) {
            $jobs = @(Get-Queue | Where-Object { $dirs -contains $_.jobDir })
            if (-not $jobs.Count) { break }
            Show-BatchProgress $jobs
            $live = @($jobs | Where-Object { $_.status -eq 'running' -and (Test-JobAlive $_.pid $_.jobDir $_.workerStartUtc) })
            if (-not @($jobs | Where-Object { $_.status -in @('running','pending') }).Count) { break }
            if (-not $live.Count -and -not (Test-SchedulerPresent)) { Write-Host '  当前没有活动进程。待办或阶段交接可用 -Resume 接管。'; break }
            try {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true).Key
                    if ($key -eq 'Q') { break }
                    if ($key -eq 'PageDown') { $script:BatchPage++ }
                    if ($key -eq 'PageUp') { $script:BatchPage-- }
                }
            } catch { }
            Start-Sleep -Milliseconds 500
        }
    } finally { Clear-LiveBox; $script:WatchOnly = $false }
}

function Invoke-Scheduler($submitted, $budget) {
    $script:LiveSig = ''
    $script:LiveCount = 0
    $reported = @{}
    $script:BatchPage = 0
    $script:BatchTextMode = $false
    $script:JobLogSig = @{}
    $i = 0
    $t0 = Get-Date
    $initial = @(Get-Queue)
    $active = @($initial | Where-Object { $_.status -in @('pending','running') })
    if ($submitted) {
        $active = @($active | Where-Object { $_.status -eq 'running' -or $submitted -contains $_.jobDir })
    }
    if ($active.Count) {
        if (-not $budget) { $budget = Get-ResourceBudget $active.Count }
        foreach ($job in $active) {
            if (-not $job.cores) { Set-JobProp $job 'cores' $budget.cores }
            if (-not $job.heapMB) {
                Set-JobProp $job 'heapMB' $budget.heapMB
                Set-JobProp $job 'autoHeap' (-not ($Heap -or $env:COMSOL_EXPORT_XMX))
            }
        }
    }
    foreach ($job in $active) {
        # 窗口可能恰在启动子进程与保存队列之间被关闭。用作业专属命令行接回该进程。
        $phaseFile = Join-Path $job.jobDir 'phase'
        if (-not [IO.File]::Exists($phaseFile)) { continue }
        $phase = [IO.File]::ReadAllText($phaseFile).Trim()
        if ($job.status -eq 'running' -and $phase -eq $job.phase -and (Test-JobAlive $job.pid $job.jobDir $job.workerStartUtc)) { continue }
        if ($phase -notin @('solve','export')) { continue }
        $workers = @(Get-JobProcIds $job)
        if ($workers.Count -gt 1) { throw ('同一作业存在多个进程，无法确定归属：' + $job.jobDir) }
        Set-JobProp $job 'phase' $phase
        if ($workers.Count) {
            $job.pid = [int]$workers[0].ProcessId
            Set-JobProp $job 'workerStartUtc' $workers[0].CreationDate.ToUniversalTime().ToString('o')
        }
        elseif ($phase -eq 'export' -and -not [IO.File]::Exists((Join-Path $job.jobDir 'started')) -and
                -not [IO.File]::Exists((Join-Path $job.jobDir 'killed')) -and
                -not [IO.File]::Exists((Join-Path $job.jobDir 'exported'))) {
            # 交接窗口中断且未启动驱动。只允许已存解作业重进导出。
            if ($job.mode -eq 'export' -or [IO.File]::Exists((Join-Path $job.jobDir 'solved'))) {
                $job.pid = 0
                $job.status = 'pending'
                continue
            }
        }
        # 没有活动进程时也先核对已有完成标记，交给常规收尾逻辑，不重新计算。
        $job.status = 'running'
    }
    if ($active.Count) { Save-Queue $initial }
    $sessionIds = @($active | ForEach-Object { $_.jobDir })
    $total = $sessionIds.Count
    if ($total -eq 0) {
        if ($script:QueueRecovered) { Save-Queue $initial } else { Write-Handoff $initial }
        $st0 = Read-Stats
        Write-Host ('  队列里没有未完成的作业。历史累计导出 ' + $st0.exported + ' 个。') -ForegroundColor DarkCyan
        return
    }
    while ($true) {
        $quitMonitor = $false
        while ($true) {
            $panels = ($total -gt 1 -and -not $script:IsRedirected -and -not $script:BatchTextMode)
            $q = @(Get-Queue)
            foreach ($job in $q) {
                if ($job.status -eq 'running') {
                    if ((Test-Path -LiteralPath (Join-Path $job.jobDir 'killed')) -and -not (Test-Path -LiteralPath (Join-Path $job.jobDir 'exported'))) {
                        $message = Stop-OneJob $job
                        if ($job.status -ne 'killed' -and $job.cancelMessage -ne $message) {
                            if (-not $panels) {
                                Clear-LiveBox
                                Write-Host ('  ' + (Split-Path -Leaf $job.jobDir) + '  ' + $message) -ForegroundColor Yellow
                            }
                            Set-JobProp $job 'cancelMessage' $message
                        }
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
                        if (-not $panels -and $note -eq '已清除') { Clear-LiveBox; Write-Host ("`n  已释放锁: " + $job.model) -ForegroundColor DarkGray }
                    }
                    elseif (-not (Test-JobAlive $job.pid $job.jobDir $job.workerStartUtc)) {
                        # 进程刚退出时文件可能还在落盘，等一拍再判
                        Start-Sleep -Milliseconds 400
                        $phaseNow = Get-JobPhase $job
                        if ($phaseNow -eq 'solve' -and -not (Test-Path -LiteralPath (Join-Path $job.jobDir 'killed'))) {
                            $why = Test-SolveOk $job
                            if ($why -eq '') {
                                # 求解成功：写 solved 标记（驱动据此走 resume），接着起导出
                                [System.IO.File]::WriteAllText((Join-Path $job.jobDir 'solved'), '', (New-Object System.Text.UTF8Encoding($false)))
                                if (-not $panels) {
                                    Clear-LiveBox
                                    $durTxt = ''
                                    $ss = Parse-DateOrNull (Get-JobProp $job 'solveStarted')
                                    if ($ss) { $durTxt = '  用时 ' + (Format-Elapsed ((Get-Date) - $ss).TotalSeconds) }
                                    Write-Host ('  [求解完成] ' + (Split-Path -Leaf $job.jobDir) + $durTxt + '，开始导出…') -ForegroundColor Green
                                }
                                Start-ExportPhase $job
                                Save-Queue $q
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
            # 续跑时已有进程已占用部分可用内存。最后一个进程退出后，重新核算待办容量。
            $waiting = @($q | Where-Object { $_.status -eq 'pending' -and $sessionIds -contains $_.jobDir })
            if ($waiting.Count -and -not @($q | Where-Object { $_.status -eq 'running' }).Count -and
                -not @($waiting | Where-Object { $_.heapMB -le $budget.pool -and $_.cores -le $budget.cpu }).Count) {
                $budget = Get-ResourceBudget $waiting.Count
                foreach ($job in $waiting) {
                    if ($job.autoHeap -and $job.heapMB -gt $budget.pool) { $job.heapMB = $budget.heapMB }
                    if ($job.autoCores -and $job.cores -gt $budget.cpu) { $job.cores = $budget.cores }
                }
                Save-Queue $q
                if (-not @($waiting | Where-Object { $_.heapMB -le $budget.pool -and $_.cores -le $budget.cpu }).Count) {
                    throw '当前可用资源不足以启动剩余作业。队列已保存，资源释放后可用 -Resume 接续。'
                }
            }
            # 每个模型用独立后台进程。逐个登记 PID，无需等前一个作业结束。
            foreach ($job in $q) {
                if ($job.status -eq 'pending' -and $sessionIds -contains $job.jobDir) {
                    $occupied = @($q | Where-Object { $_.status -eq 'running' })
                    $reservedCpu = ($occupied | Measure-Object -Property cores -Sum).Sum
                    $reservedHeap = ($occupied | Measure-Object -Property heapMB -Sum).Sum
                    if ([int64]$reservedCpu + $job.cores -gt $budget.cpu -or [int64]$reservedHeap + $job.heapMB -gt $budget.pool) { continue }
                    Start-OneJob $job
                    Save-Queue $q
                }
            }
            Save-Queue $q

            $running = @($q | Where-Object { $_.status -eq 'running' })
            $open = @($q | Where-Object { $sessionIds -contains $_.jobDir -and $_.status -in @('pending','running') })
            $mine = @($q | Where-Object { $sessionIds -contains $_.jobDir })
            $fin = @($mine | Where-Object { $_.status -eq 'done' -or $_.status -eq 'failed' -or $_.status -eq 'killed' })
            $el = (Get-Date) - $t0

            $cur = @($running | Where-Object { $sessionIds -contains $_.jobDir })
            foreach ($finished in $fin) {
                if (-not $panels -and -not $reported.ContainsKey($finished.jobDir)) {
                    Clear-LiveBox
                    $label = @{ done='导出完成'; failed='失败'; killed='已终止' }[[string]$finished.status]
                    Write-Host ('  [' + $label + '] ' + (Split-Path -Leaf $finished.jobDir))
                    $reported[$finished.jobDir] = $true
                }
            }
            if ($open.Count -eq 0) { break }
            if ($total -gt 1) {
                Show-BatchProgress $mine
            } elseif ($cur.Count -gt 0) {
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
                    if ($total -gt 1) {
                        $Host.UI.RawUI.WindowTitle = ('COMSOL · 运行 ' + $cur.Count + ' · 已结束 ' + $fin.Count + '/' + $total)
                    } elseif ($cur.Count -gt 0) {
                        $dT = Get-JobDisplay $cur[0]
                        $Host.UI.RawUI.WindowTitle = ('【' + (Get-PhaseTag $dT) + ' ' + (Get-PctText $dT).Trim() + '】' + (Split-Path -Leaf $cur[0].jobDir) + ' - COMSOL 导出')
                    } else {
                        $Host.UI.RawUI.WindowTitle = ('【调度中 ' + $fin.Count + '/' + [math]::Max(1, $total) + '】COMSOL 导出')
                    }
                } catch { }
            }

            try {
                if ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq 'Q') { $quitMonitor = $true; break }
                    if ($k.Key -eq 'PageDown') { $script:BatchPage++ }
                    if ($k.Key -eq 'PageUp') { $script:BatchPage-- }
                    if ($k.Key -eq 'K') { Clear-LiveBox; Write-Host ''; Invoke-KillMenu; Write-Host '' }
                }
            } catch { }
            Start-Sleep -Milliseconds 500
            $i++
        }
        Clear-LiveBox
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
        if (-not $quitMonitor) {
            if (@($mine | Where-Object { $_.status -eq 'failed' -and $_.phase -eq 'solve' }).Count) { $script:CliExit = 3 }
            elseif (@($mine | Where-Object { $_.status -in @('failed','killed') }).Count) { $script:CliExit = 4 }
            break
        }
        Write-Host ''
        if (-not (Read-Confirm '再看一轮进度？（后台计算不受影响）' -NoDefault)) { break }
        Write-Host ''
    }
}

$script:PStyle = $ProgressStyle
if ([string]::IsNullOrWhiteSpace($script:PStyle)) {
    $script:PStyle = [string](Read-Config).ProgressStyle
    if ([string]::IsNullOrWhiteSpace($script:PStyle)) { $script:PStyle = '2' }
}
if ($env:COMSOL_EXPORT_STYLE) { $script:PStyle = [string]$env:COMSOL_EXPORT_STYLE }
$script:WinDebug = [bool]$WinDebug
Write-Host ''
Write-Banner
if (($DryRun -and ($Resume -or $KillJob -or $Diag -or $Mode -eq 'watch')) -or
    ($Resume -and ($Mode -or $KillJob -or $Diag)) -or ($KillJob -and ($Mode -or $Diag))) {
    throw '预演、监视、续跑、诊断和终止参数组合冲突。'
}
# 模式：先决定这次是“求解+导出”还是“只导出已有解的模型”
$doSolve = $true
$doWatch = $false
if ($Mode -eq 'export') { $doSolve = $false }
elseif ($Mode -eq 'solve') { $doSolve = $true }
elseif ($Mode -eq 'watch') { $doWatch = $true }
elseif (-not $Resume -and -not $KillJob -and -not $Diag -and [string]::IsNullOrWhiteSpace($ModelIndex)) {
    $items = @('求解并导出', '导出模式', '监视模式')
    $mv = Read-Menu '选择模式' $items 1
    if ($mv -le 0) { Write-Host '  已取消，未启动任何作业。' -ForegroundColor Yellow; exit 0 }
    if ($mv -eq 2) { $doSolve = $false }
    if ($mv -eq 3) { $doWatch = $true }
}

if ($doWatch) { Watch-Queue; exit 0 }

# 新作业先完成选择。浏览和取消菜单不依赖调度器或 COMSOL 运行环境。
if (-not ($Resume -or $KillJob -or $Diag)) {
    Write-Host ('  读取模型目录 ' + $Models) -ForegroundColor DarkGray
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
    $pickAll = $false
    $idxs = @()
    if (-not [string]::IsNullOrWhiteSpace($miRaw)) {
        # -ModelIndex / 兼容旧的输入方式：直接解析，不弹菜单
        if ($miRaw -match '^\s*a\s*$') {
            $idxs = @(1..$modelFiles.Count)
            $pickAll = $true
        } elseif ($solvedNo -gt 0 -and $miRaw -match ('^\s*' + $solvedNo + '\s*$')) {
            $modelFiles = $solvedFiles
            $solvedNo = 0
            $fromSolved = $true
            $miRaw = ''
        } else {
            $idxs = @(ConvertTo-IndexList $miRaw $modelFiles.Count)
            if ($idxs.Count -eq 0) { throw ('模型序号无效: ' + $ModelIndex) }
        }
    }
    while ($idxs.Count -eq 0) {
        $items = @()
        $colors = @()
        for ($i = 0; $i -lt $modelFiles.Count; $i++) {
            # 快捷方式直接显示它指向的模型名（不再显示「链接名 → 目标」，也不做特殊标色）
            $label = [System.IO.Path]::GetFileName($modelFiles[$i].FullName)
            $color = 'Gray'
            if ($modelFiles[$i].Missing) { $label = $label + '  （目标不存在）'; $color = 'DarkYellow' }
            $items += $label
            $colors += $color
        }
        if ($solvedNo -gt 0) {
            $items += ('从 \solved 中选择（共 {0} 个）' -f $solvedFiles.Count)
            $colors += 'Gray'
        }
        $title = '选择模型'
        if ($fromSolved) { $title = '选择模型（solved\）' }

        # 空格勾选多个；回车=当前行；Esc 放弃本次运行
        $picks = @(Read-Menu $title $items 1 -Multi -ItemColors $colors)
        if ($picks.Count -eq 0) {
            Write-Host '  已取消，未启动任何作业。' -ForegroundColor Yellow
            exit 0
        }
        if ($solvedNo -gt 0 -and ($picks -contains $solvedNo)) {
            Start-Sleep -Milliseconds 120
            $plain = @($picks | Where-Object { $_ -ne $solvedNo })
            if ($plain.Count -eq 0) {
                # 只选了 solved\：整份列表换过去重选一次（换过去后这一项不再出现，避免套娃）
                $modelFiles = $solvedFiles
                $solvedNo = 0
                $fromSolved = $true
                Write-Host ('  已切到 ' + $solvedDir) -ForegroundColor Cyan
                continue
            }
            $picks = $plain
        }
        if ($picks.Count -eq $modelFiles.Count) { $pickAll = $true }
        $idxs = $picks
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
        $items = @($recipes | ForEach-Object { $_.Name })
        $ri = Read-Menu '选择配方' $items 1
        if ($ri -le 0) { Write-Host '  已取消，未启动任何作业。' -ForegroundColor Yellow; exit 0 }
        $r = $recipes[$ri - 1]
    }

    $cfg = $r.Data
    if (-not $cfg.NameTemplate) { throw ('配方缺少 NameTemplate: ' + $r.Name) }
    $blocks = @(Expand-Blocks $cfg (Get-ModuleDefs))
    if ($blocks.Count -eq 0) { throw ('配方没有任何导出内容（Use 或 Export 为空）: ' + $r.Name) }
}

[IO.Directory]::CreateDirectory($StateDir) | Out-Null

# 队列只有一个写者。独占写句柄随 CLI 进程退出自动释放。
$instFile = Join-Path $StateDir 'cli.lock'
$guard = $null
try {
    $guard = [IO.File]::Open($instFile, 'OpenOrCreate', 'ReadWrite', 'Read')
} catch [IO.IOException] {
    if (($_.Exception.GetBaseException().HResult -band 0xffff) -notin @(32, 33)) { throw }
    if (-not $KillJob) { Write-Host '  已有 CLI 正在管理队列。'; exit 0 }
}
try {
if ($guard) {
    # 兼容旧版本仍在运行时留下的 PID 文件。
    $reader = [IO.StreamReader]::new($guard, [Text.Encoding]::UTF8, $true, 128, $true)
    try { $old = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ($old -match '^\d+$' -and (Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue)) {
        throw '旧版 CLI 正在管理队列，请先从旧窗口退出监视。'
    }
    $guard.Position = 0
    $guard.SetLength(0)
    $bytes = [Text.Encoding]::ASCII.GetBytes("owner=$PID")
    $guard.Write($bytes, 0, $bytes.Length)
    $guard.Flush()
}

$script:HandoffStates = @{}
foreach ($prior in @(Get-Queue)) {
    if ($prior.status -in @('done','failed','killed') -and $prior.resultDir -and
        [IO.File]::Exists((Join-Path $prior.jobDir 'handoff'))) { $script:HandoffStates[$prior.jobDir] = $prior.status }
}
if ($KillJob) {
    $q = @(Get-Queue)
    if ($KillJob -match '^\d+$') {
        $index = [int]$KillJob
        if ($index -lt 1 -or $index -gt $q.Count) { throw '队列历史序号超出范围' }
        $target = $q[$index-1]
    } else {
        $matchesById = @($q | Where-Object { (Split-Path -Leaf $_.jobDir) -eq $KillJob })
        if ($matchesById.Count -ne 1) { throw ('作业 ID 不存在或不唯一：' + $KillJob) }
        $target = $matchesById[0]
    }
    Write-Host ('  目标: ' + (Split-Path -Leaf $target.jobDir) + '   PID ' + $target.pid) -ForegroundColor Yellow
    if ($target.status -ne 'running' -or (Test-Path -LiteralPath (Join-Path $target.jobDir 'exported'))) {
        Write-Host '  目标当前没有可终止的计算。'; exit 0
    }
    if ($guard) {
        $msg = Stop-OneJob $target
        Save-Queue $q
        Write-Host ('  ' + $msg)
    } else {
        [IO.File]::WriteAllText((Join-Path $target.jobDir 'killed'), (Get-Date).ToString('o'))
        Write-Host '  已请求终止。'
        # 调度器可能停在菜单或刚退出。即便如此也能停止后台作业，队列仍只由持锁者写入。
        Start-Sleep -Seconds 1
        $latest = @(Get-Queue | Where-Object { $_.jobDir -eq $target.jobDir -and $_.status -eq 'running' })
        if ($latest.Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $target.jobDir 'exported'))) {
            Write-Host ('  ' + (Stop-OneJob $latest[0]))
        }
    }
    exit 0
}

$comsolBatch = Resolve-Comsol $ComsolPath
$comsolRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $comsolBatch))
$javaExe    = Join-Path $comsolRoot 'java\win64\jre\bin\java.exe'
if (-not (Test-Path -LiteralPath $javaExe)) { throw ('找不到 Java: ' + $javaExe) }
$driverDir  = Join-Path $ScriptDir 'driver'
if (-not (Test-Path -LiteralPath (Join-Path $driverDir 'ExportDriver.class'))) {
    throw ('驱动未编译，先运行: comsolcompile ' + (Join-Path $driverDir 'ExportDriver.java'))
}

Write-Host ('  正在检查 COMSOL 导出驱动 ' + $comsolRoot) -ForegroundColor DarkGray
Assert-DriverRuntime $javaExe ((Join-Path $comsolRoot 'plugins\*') + ';' + $driverDir)
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
    exit $rc
}

if ($Resume) {
    Write-Host ''
    Write-Host '  接着跑队列里未完成的作业（已关掉的计算不会被杀）' -ForegroundColor Cyan
    Invoke-Scheduler
    exit $script:CliExit
}

# 模型同名或配方生成相同 outname 时，解文件和导出文件会共用路径。
$usedOutputs = @{}
foreach ($existing in @(Get-Queue)) {
    if ($existing.status -in @('pending','running')) { $usedOutputs[[string]$existing.id] = $true }
}
foreach ($m in $ModelList) {
    $name = Format-JobName $cfg.NameTemplate @{ task = [string]$cfg.Task; model = $m.BaseName; stamp = $Stamp }
    if (-not $name -or $name -in @('.','..') -or $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw ('作业输出文件名无效 ' + $name) }
    if ($usedOutputs.ContainsKey($name)) { throw ('作业输出名称重复：' + $name + '。请区分模型名或配方的 NameTemplate。') }
    $usedOutputs[$name] = $true
}
$solScope = if ($cfg.SolScope) { ([string]$cfg.SolScope).ToLowerInvariant() } else { 'study' }
if ($solScope -notin @('study','all')) { throw 'SolScope 取 study 或 all' }
$batchKey = (Get-Date -Format 'yyyyMMddHHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8)
$outRoot = Join-Path $Root 'output'
$batchDir = if ($ModelList.Count -gt 1) { Join-Path $outRoot ('batch_' + $batchKey) }
            else { Join-Path (Join-Path $outRoot $ModelList[0].BaseName) $batchKey }
$budget = Get-ResourceBudget $ModelList.Count
Write-Host ('  资源预算：最多同时 {0} 个，每作业 {1} 核、Java 堆 {2} MiB' -f $budget.slots,$budget.cores,$budget.heapMB)
$jobs = @()
$jobSpecs = @{}
foreach ($m in $ModelList) {
    $n = Format-JobName $cfg.NameTemplate @{ task = [string]$cfg.Task; model = $m.BaseName; stamp = $Stamp }
    $jobDir = Join-Path $JobsDir ($Stamp + '_' + $m.BaseName)
    if (Test-Path -LiteralPath $jobDir) { $jobDir += '_' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    $outDir = Join-Path $Root 'output'

    $resultDir = if ($ModelList.Count -gt 1) { Join-Path $batchDir (Split-Path -Leaf $jobDir) } else { $batchDir }
    $spec = New-Object System.Collections.Generic.List[string]
    $spec.Add('model='    + $m.FullName)
    $spec.Add('study='    + $cfg.Study)
    $spec.Add('outdir='   + $outDir)
    $spec.Add('modelsdir=' + $Models)
    $spec.Add('outname='  + $n)
    $spec.Add('solver=batch')
    if ($doSolve) { $spec.Add('solvedfile=' + (Join-Path (Join-Path $Models 'solved') ($n + '_' + $batchKey + '.mph'))) }
    $spec.Add('cli=' + $script:CliVersion)
    $spec.Add('recipe=' + $r.Name)
    $spec.Add('solscope=' + $solScope)
    $spec.Add('resultdir=' + $resultDir)
    if ($cfg.Solution) { $spec.Add('solution=' + $cfg.Solution) }
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
    $jobSpecs[$jobDir] = $spec

    $tag = ''
    if (-not $doSolve) { $tag = '（只导出）' }
    Write-Host ('  [作业]' + $tag + ' ' + $m.Name + '  ID ' + (Split-Path -Leaf $jobDir))
    $jobs += [pscustomobject]@{
        id = $n; model = $m.FullName; recipe = $r.Name
        pid = 0; jobDir = $jobDir; outDir = $outDir; resultDir = $resultDir; batchDir = $batchDir
        cores = $budget.cores; heapMB = $budget.heapMB
        autoHeap = -not ($Heap -or $env:COMSOL_EXPORT_XMX); autoCores = -not $Cores
        solveKind = $(if ($doSolve) { Get-StudyProgressKind $m.FullName ([string]$cfg.Study) } else { '' })
        created = (Get-Date).ToString('o'); started = ''
        status = 'pending'; mode = $(if ($doSolve) { 'solve' } else { 'export' })
    }
}

Write-Host ''
if ($DryRun) {
    # 预览模式：只报计划，绝不写队列、绝不启动计算
    foreach ($cfgBlock in $blocks) { Write-Host ('  导出块: ' + $cfgBlock.Type + ' / ' + $cfgBlock.Name) }
    Write-Host ('  预览：共 ' + $jobs.Count + ' 个作业，未写入队列、未启动计算。')
    exit 0
}

$ans = Read-Confirm ('开始导出？共 ' + $jobs.Count + ' 个作业')
if (-not $ans) {
    Write-Host '  已取消。' -ForegroundColor Yellow
    exit 0
}

foreach ($j in $jobs) {
    [IO.Directory]::CreateDirectory($j.jobDir) | Out-Null
    [IO.File]::WriteAllLines((Join-Path $j.jobDir 'job.properties'), $jobSpecs[$j.jobDir], [Text.UTF8Encoding]::new($false))
}
$queue = @(Get-Queue)
Save-Queue (@($queue) + @($jobs))
Write-Host ''
Invoke-Scheduler @($jobs | ForEach-Object { $_.jobDir }) $budget

} finally { if ($guard) { $guard.Dispose() } }
exit $script:CliExit
