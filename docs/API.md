# COMSOL 导出 CLI · API 文档

> 最后更新：2026-11-12 · 对应 v1.1 · COMSOL 侧 API 见 [COMSOL-API.md](COMSOL-API.md)
> 接口与内部约定的参考手册，随版本持续更新。使用说明见 [README.md](../README.md)，配方写法见 [recipes/README.md](../recipes/README.md)。

## 1. 分层与调用链

```
run.bat  →  cli.ps1  →  job.properties  →  ExportDriver.java  →  handler  →  output/<模型名>/
             │                                    │
             └── queue.json（调度/状态）           └── logs/<作业>/{solved,exporting,exported}
```

| 层 | 文件 | 职责 | 不做什么 |
|---|---|---|---|
| 入口 | `run.bat` | `chcp 65001` + 调 `cli.ps1` | — |
| 编排 | `cli.ps1` | 选模型/配方、写作业文件、调度队列、画界面、清锁 | 不碰模型内容 |
| 作业约定 | `job.properties` | 一次求解 + 若干导出块 | 不含逻辑 |
| 驱动 | `driver/ExportDriver.java` | 加载副本、跑研究、按块导出、写标记 | 不改参数/网格 |
| 导出块 | handler | 每类导出一种实现 | 互不知道彼此 |

## 2. CLI 接口（cli.ps1）

### 2.1 参数

| 参数 | 类型 | 说明 |
|---|---|---|
| `-Models <dir>` | string | 模型目录，默认 `<根>\models`（不存在则回退 `<根>\model`） |
| `-Recipe <name>` | string | 直接指定配方名（不交互选择） |
| `-ModelIndex <n>` | string | 直接指定第 n 个模型或 `a`（全部），默认空 = 交互 |
| `-ComsolPath <path>` | string | 指定 `comsolbatch.exe`，覆盖本机配置 |
| `-Setup` | switch | 配置菜单：COMSOL 路径 / 并发数 / 模型目录 / 重新扫描 |
| `-DryRun` | switch | 只打印作业与导出块；不写队列、不启动计算、不弹确认 |
| `-Resume` | switch | 跳过选择，直接调度队列里未完成的作业 |
| `-Mode` | string | `solve` 求解并导出（默认）/ `export` 只导出已有解的模型；空 = 交互询问 |
| `-KillJob <n>` | int | 终止队列里第 n 个作业（不受单实例守卫限制） |
| `-ProgressStyle <1\|2\|3>` | string | 进度显示样式，默认 `2`；环境变量 `COMSOL_EXPORT_STYLE` 覆盖；配置 `ProgressStyle` 次之 |
| `-Cores <n>` | int | 求解核数（传给 `comsolbatch -np`），默认 `0` = 让 COMSOL 自己决定 |
| `-Heap <6g>` | string | Java 堆，覆盖按物理内存自动估算的值；环境变量 `COMSOL_EXPORT_XMX` 亦可 |
| `-WinWidth <n>` | int | 控制台宽度（列），默认 `88`；高度自动按屏幕工作区占满。环境变量 `COMSOL_EXPORT_COLS` 覆盖；`COMSOL_EXPORT_NORESIZE=1` 关掉自动设尺寸 |
| `-Help` | switch | 帮助 |

### 2.2 退出码

| 码 | 含义 |
|---|---|
| 0 | 正常结束（含用户取消、DryRun） |
| 1 | 未捕获错误（顶部 `trap` 打一行中文原因） |
| 2 | 用法/文件错误（模型不存在、研究不存在、作业文件缺块） |
| 3 | 求解失败 |
| 4 | 导出失败（表达式取不到数、配置非法） |

> 2/3/4 由驱动产生，CLI 转成中文提示并打印 `driver.err` 末 3 行原因。

### 2.3 交互键

| 键 | 场景 | 行为 |
|---|---|---|
| `↑` `↓` / `Home` `End` / `PgUp` `PgDn` | 所有菜单 | 移动当前行（`❯` + 反色整行） |
| `Enter` | 所有菜单 | 确定当前行；多选时为「确认勾选的集合」（没有勾选就取当前行）。框随即清掉，只留一行 `✓ 标题: 已选…`（太长就折成多行） |
| `n` + `Enter` | 所有菜单 | 直选（保留旧习惯）；多选用逗号，如 `1,3` |
| `Space` | 多选菜单（选模型） | 勾选/取消（`●` 已勾选、`○` 未选；勾选的字为白、未选为暗灰） |
| `a` | 多选菜单 | 全选 / 全不选 |
| `↑` `↓` + `Enter` | 确认菜单（开始导出 / 终止作业 / 再看一轮进度） | 选 `是` / `否`；破坏性操作默认停在 `否`，回车即不做 |
| `Esc` | 所有菜单 | 有数字缓冲时先清缓冲，否则取消（取消模型/配方选择 = 不启动任何作业） |
| `Q` | 监视中 | 退出监视，不杀计算；再进一次继续显示 |
| `K` | 监视中 | 列出本 CLI 启动且在跑的作业，上下键选一个终止；终止前再弹一次 `是 / 否` |

菜单实现：`Read-Menu`（复用 `New-BoxDisplay` + `Show-LiveBox` 的差量重绘，不整屏重画）；输出被重定向（无人值守/管道）时自动退回「方框 + 输入序号」，脚本调用行为与旧版一致。

### 2.4 内部函数（维护时定位用）

| 函数 | 作用 |
|---|---|
| `Read-Menu` | 上下键菜单（单/多选），返回 1-based 序号（多选为扁平 `int[]`）；`0`/`@()` = 取消；`-Quiet` 不打结论行 |
| `Read-Confirm` | 是/否菜单，返回 `$true`/`$false`；`-NoDefault` 默认停在「否」 |
| `New-MenuRows` / `ConvertTo-IndexList` | 菜单行渲染（`❯` 游标、`●`/`○` 勾选、末行按键提示）/ 逗号输入解析 |
| `Cut-Text` / `Pad-Text` | 按显示宽度（中文两格）截断补省略号 / 右侧补空格对齐 |
| `Initialize-ConsoleWindow` | 启动时一次定好窗口：宽度按列数算、高度占满可用高度（像素级 `SetWindowPos`），收尾再钉一次 |
| `Resolve-Comsol` | 三步扫 COMSOL：桌面快捷方式 → 注册表 → 浅层磁盘 |
| `Read-Config` / `Save-Config` | 读写 `%LOCALAPPDATA%\comsol-export\state\config.psd1` |
| `Get-ModelFiles` / `Get-Recipes` | 扫描模型与配方 |
| `Format-JobName` | 用 NameTemplate 生成输出名 |
| `Save-Queue` / `Get-Queue` | 队列读写（JSON，无 BOM） |
| `Start-OneJob` | 分离启动 java 驱动，写 `pid`/`started` |
| `Test-JobAlive` | 进程存在 + 是 java.exe + 命令行含 ExportDriver 与该 jobDir |
| `Stop-OneJob` | 三重校验后 `taskkill /T /F`，写 `killed` 标记 |
| `Clear-JobLock` | 四道闸清 `.lock` |
| `Invoke-Scheduler` | 调度循环、界面刷新、统计 |
| `Write-Box` / `Write-BoxRows` | 画框（中文双宽对齐）；宽度统一由 `Get-BoxWidth` 定，内容超长交给 `Cut-Text`/`Trim-Row` 截断，框永不被撑宽 |
| `Get-BoxWidth` / `$script:BoxW` | 全部方框的统一内宽（默认 76，含标题框/菜单框/进度框/汇总框）；窄终端自动收缩 |
| `Trim-Row` | 按显示宽度截断一整行（多段、可带底色），用于菜单与进度框的动态内容 |
| `Write-Banner` / `Enable-VtColor` | 开场字标：6 行 ANSI 阴影块字，`Enable-VtColor` 用 `SetConsoleMode(ENABLE_VIRTUAL_TERMINAL_PROCESSING)` 打开 VT，逐字符发 24 位色；拿不到 VT（重定向/旧终端）自动退化成 DarkCyan 单色，字形不变 |
| `Get-ArtColor` / `$script:ArtRows` | 字标字模与对角渐变（竖向权重 0.62、横向 0.38，5 个色标插值）；字模里 C 自带 1 格尾空、O 自带 1 格首空，故 C-O 之间不再额外留空 |

## 3. 作业文件 job.properties

CLI 生成，驱动逐行 `key=value` 读（不用 `java.util.Properties`，避免反斜杠被当转义）。

| 键 | 说明 |
|---|---|
| `model` | 模型绝对路径 |
| `study` | 研究标签，空则取模型第一个研究 |
| `outdir` | 输出根目录；驱动实际写 `<outdir>/<模型文件名去 .mph>/`（每个模型一个同名子文件夹） |
| `outname` | 输出文件名（不含扩展名） |
| `modelsdir` | 模型目录，用于存 `solved/` 下已求解模型 |
| `solve` | `1` 求解后导出（默认）/ `0` 只导出：跳过研究求解，直接用模型里已有的解 |
| `blocks` | 导出块数量 |
| `block.N.<key>` | 第 N 个块的字段，key 为配方字段小写 |

块字段由 CLI 通用写入：数组用 `|` 连接，不做类型转换。

## 4. 导出块规格

### 4.1 公共

| 字段 | 说明 |
|---|---|
| `Type` | 必填，`global` `spectrum` `image` `eigenslice` |
| `Name` | 块名，多于一块时作为文件名后缀 |

单块作业输出 `<outname>.csv` / `<outname>_<name>.png`；多块输出 `<outname>_<name>.csv`。

### 4.2 global

| 字段 | 默认 | 说明 |
|---|---|---|
| `Expr` | — | `|` 分隔的表达式列表 |
| `Cols` | — | 列名，数量必须与 Expr 一致 |

行 = 解，列 = 扫描参数（自动前置）+ Expr。首列名以 `_nm` 结尾且表达式以 `c_const/` 开头时按 nm 输出（按量级判断米/纳米）。

### 4.3 spectrum

| 字段 | 默认 | 说明 |
|---|---|---|
| `Expr` | `c_const/ewfd.freq|abs(ewfd.S21)^2|abs(ewfd.S11)^2` | 一般不填 |
| `Cols` | `lambda_nm|T|R` | 一般不填 |
| `Plot` | `false` | `true` 时额外输出 T/R 曲线 PNG（1D Global 图） |

### 4.4 image — 场图（只出 1 张组合总表，v1.7.15 起）

**只产出 1 个文件**：`<outname>_<name>_all.png`。三维与三张二维切面先导到作业临时目录（`%TEMP%\comsol-export-*\img_N\`），拼完立即删除，模型的产物子目录里不会再留分面图。

总表 **300 dpi**（PNG 内写 `pHYs` = 11811 px/m；ImageIO 重编码会丢 dpi，驱动自己补写），带图题、色标、坐标轴刻度；默认画每个域的边界线，去掉了 COMSOL 徽标与三轴方向图标。

| 文件 | 内容 | 尺寸（示例：500×500×5080 nm 模型） |
|---|---|---|
| `<outname>_<name>_all.png` | 组合总表：每个分量一块，三维在左、右边上 x-y 下 x-z/y-z；二维不带 COMSOL 方框，坐标轴（左侧竖线+刻度）与竖色标由驱动自绘 | 约 5265×4065 |

分面图的中间尺寸（仅为排版服务，不落盘）：三维约 876×3492；x-y 约 3284×3284；x-z/z-y 约 600×4000。

`Expr` 写多个表达式（逗号分隔）时，**每个分量各占一块**拼进同一张总表，仍然只有一个 PNG。默认 `ewfd.Ex,ewfd.Ey`。

| 字段 | 默认 | 说明 |
|---|---|---|
| `Expr` | `ewfd.Ex,ewfd.Ey` | 场表达式，逗号分隔 = 逐分量各占一块（不用 `ewfd.normE` 模值） |
| `SolNum` | `1` | 取**全部解里的第几个**（与 CSV 行序一致）。多解节点时驱动自动翻成「解节点 + 节点内序号」并打日志 `场图解 N → 解节点 solX 第 M 个`；超出总数会报错并列出各节点范围 |
| `Width` | `1200` | 像素。`Height > 0` 时作为二维画布宽度 |
| `Height` | `0` | `0` = 按切面长宽比自动算（此时 `Width` 不参与）；写死数字则强制该像素高度 |
| `Title` | 空 | 自定义图题；空则用「平面 + COMSOL 自动量名」 |
| `Edges` | `on` | `on` 画域边界线（默认）；`off` 出纯净色块 |
| `Grid` | `off` | `on` 才画三维坐标框（栅格）；导出节点 `grid` 一关，刻度与数字也一起消失 |

分辨率：拼版由静态常量 `SCALE = 1.5` 统一缩放（`BLOCK_H=3600`、字号、边距、色标条全按它乘），改一个数即可整体升降。分面画布同步放大：二维短边 ≥1200、长边 ≥3600，三维长边约 3600。**COMSOL 单边像素硬上限 4096**（超了报 `The_width_must_not_exceed_X_pixels#4096`，`overrideresolutionlimit` 也不放行），所以更大的图只能由 Java 拼版产出。

画布比例不固定 4:3：三维按几何 bbox 长宽比给竖长/横长画布，二维按切面长宽比算；导出后按内容 bbox 裁白边（`cropWhite`），再去掉 COMSOL 那圈方框（`stripBox`，留左侧刻度与右侧色标）。
二维一律 **1:1 真实比例**，不做拉伸；色标竖排在右侧（拼图后正好落在两图中间）。

三个二维切面都过几何中心，位置由 `getBoundingBox()` 直接取（**单位就是几何单位**，不要乘米制系数）。



### 4.5 eigenslice

| 字段 | 默认 | 说明 |
|---|---|---|
| `Expr` | `ewfd.normE` | 同上 |
| `Planes` | `xy|zx|yz` | 每模态导出这些平面 |
| `At` | `0` | 同上 |
| `MaxModes` | `50` | 每个解节点最多导多少个模态 |
| `Width` / `Height` | `800` / `600` | 像素 |

命名：`<outname>_m<k>_<plane>.png`；模型里有多个解节点时插 `_s<j>`。

### 4.6 slice2d — 多切面二维正投影（2026-11）

字段：`Expr`（默认 `ewfd.normE`）、`Planes`（`xy|zx|yz`，默认三面全出）、`At`（米；`auto` = 该方向几何中心）、`Width`/`Height`（像素）、`Title`。
实现：每个平面建 `CutPlane` 数据集（`quickplane` + 偏移键）+ `PlotGroup2D`（`Surface` 节点），导出 `<outname>_<name>_<plane>.png`。
- 几何包围盒 `getBoundingBox()` 与 `CutPlane` 的偏移量**同一个单位（几何长度单位，如 nm）**，直接填即可；乘米制系数会把切面推出模型外、出空白图（v1.7.5 之前的错法）。
- 2D 图组 + CutPlane 才是真二维投影；用 3D 图组切片的透视投影，画面是斜看的长条。

### 4.7 integral — 线/面积分（2026-11）

字段：`Dim`（`surface`|`line`）、`Ents`（`all` 或编号列表 `3,4,17`）、`Expr`、`Cols`。
实现：`numerical().create(tag,"IntSurface"/"IntLine")`，`selection().all()` 或 `selection().set(int[])`；逐解节点、逐 `solnum` 取值，去重后写 CSV（一行一个解）。编号不存在时报错并中止该块。

### 4.8 modes — 模态数值表（2026-11）

字段：`Expr`（默认 `ewfd.freq`）、`Cols`、`MaxModes`（默认 50）。
实现：`EvalGlobal` + 逐 sol 逐 solnum，遇异常即停；输出列 `mode` + 指定列。对波长解模型也能用（每个解一行，值相同则去重）。

### 4.10 bigtable — 通用原始大表（2026-11）

一次导出：全局参数（`<name>_val`，自动）+ 谱线 9 列 + 各吸收域 `Qrh/A` 两列 + 合计两列。
- 参数列来自 `model.param().varnames()`，模型参数变了列自动变（`Params=all|none|名单`）。
- 吸收域：`AbsDomains=auto` 时按材料名含 ITO 收集域，再按 `IntVolume ∫z dV / ∫1 dV` 的 z 中心排序命名（2 个 lower/upper，3 个 lower/hole/upper）；也可显式 `3:lower,6:upper,9:hole`。
- 吸收百分比 = `100 × ∫AbsExpr dV / ewfd.Pin`；`T00/R00=|S21|²/|S11|²`（0 阶），`T_total/R_total=ewfd.Ttotal/Rtotal`（含衍射级）。
- 表头全 ASCII，避免远程控制台/Excel 乱码。

### 4.9 预制模块系统（2026-11）

`script/modules/<id>.psd1` 每个文件一个模块：

```powershell
@{ Id='slice2d'; Kind='slice2d'; Title='多切面（二维视图）'
   Defaults=@{ Expr='ewfd.normE'; Planes=@('xy','zx','yz'); At='auto' }
   Keys=@('Expr','Planes','At','Width','Height','Title','Name') }
```

配方 `Use = @(@{ Module='slice2d'; Name='field'; Planes=@('xy') })` 由 `Expand-Blocks`（cli.ps1）解析：
1. 取模块 `Defaults`；2. 用调用里的键覆盖（`Name` 单独处理，其余必须在 `Keys` 里，否则报错）；3. 补 `Type=Kind`；4. 与老写法 `Export` 块合并。

现有模块：

| 模块 | Kind | 说明 |
|---|---|---|
| `bigtable` | bigtable | 通用原始大表（参数 + 谱线 + 各域吸收） |
| `integral` | integral | 线/面积分 |
| `modes` | modes | 模态数值表 |
| `slice2d` | slice2d | 多切面二维正投影 |
| `spectrum` | spectrum | 常规谱线 |
| `table` | table | 任意表达式表 |
| `image` | image | 单点场图：**只出 1 张组合总表**（三维+xy+xz+zy 拼好），300 dpi |

`image` 模块的关键字段：`SolNum`（取第几个解 —— 做"逐共振点各出一组场图"时就是各共振点的解号）、`Expr`、`Width`（`Height>0` 时的二维宽度）、`Height`（0 = 二维按切面长宽比自动）、`Title`（空 = 自动）、`Edges`。分辨率由驱动内 `SCALE` 常量统一放大，不需要在配方里写。

新增模块 = 加一个 psd1；新增能力 = `HANDLERS` 一行 + 一个 psd1。

## 5. 扩展指南

### 5.1 新增一种导出类型（改两处）

1. 在 `ExportDriver.java` 写 handler：

```java
static void exportFoo(Job j, int i) throws Exception {
    String name = j.block(i, "name", "foo");       // 读块字段
    String expr = j.block(i, "expr", "ewfd.normE");
    Path target = j.outdir.resolve(j.outname + "_" + name + ".csv");
    // ... 取数 / 作图 / 写文件 ...
}
```

2. 注册：`HANDLERS.put("foo", ExportDriver::exportFoo);`

3. 配方直接写 `@{ Type='foo'; Name='x'; ... }` —— CLI 原样写入 job.properties，不用改 PowerShell。

### 5.2 Job 上下文成员

| 成员 | 说明 |
|---|---|
| `j.model` | 已加载的 `com.comsol.model.Model` |
| `j.dataset` | 第一个数据集标签 |
| `j.outdir` / `j.outname` | 输出目录（已含模型同名子文件夹）/ 文件名 |
| `j.pnames` | 研究的参数化扫描变量名（自动前置为 CSV 列） |
| `j.study` | 研究标签 |
| `j.block(i,key,def)` | 读字符串字段 |
| `j.blockArr(i,key)` | 读 `|` 分隔数组 |

### 5.3 复用的内部工具

| 方法 | 说明 |
|---|---|
| `buildSliceGroup(j, i, tag)` | 建 3D 绘图组 + 切片，按块字段设置平面与位置 |
| `exportPng(j, i, plotGroup, target)` | 导出 PNG（先写 `.part.png` 再改名） |
| `writeCsv(...)` | 写 CSV（先写 `.part` 再改名） |
| `offsetKey(plane)` | 平面 → 偏移属性名映射 |

## 6. 运行时状态

### 6.1 队列 queue.json

`%LOCALAPPDATA%\comsol-export\state\queue.json`，数组，每项：

| 字段 | 说明 |
|---|---|
| `id` | 输出名 |
| `model` | 模型绝对路径 |
| `recipe` | 配方名 |
| `pid` | 驱动进程号，0 = 未启动 |
| `jobDir` | 作业目录 `script\logs\<stamp>_<model>` |
| `outDir` | 输出目录 |
| `created` / `started` | ISO 时间 |
| `status` | `pending` `running` `done` `failed` `killed` `disconnected` |
| `duration` | 用时（秒），用于估算 |

### 6.2 标记文件

| 文件 | 写入方 | 含义 |
|---|---|---|
| `solved` | 驱动 | 研究跑完，`models/solved/<outname>.mph` 已存 |
| `exporting` | 驱动 | 正在写输出 |
| `exported` | 驱动 | 全部块完成 |
| `killed` | CLI | 被人工终止 |
| `counted` | CLI | 已计入历史累计，防重复 |

### 6.3 历史统计

`%LOCALAPPDATA%\comsol-export\state\stats.json`：`{ "exported": 12 }`。

### 6.4 两阶段执行（v1.7 起）

求解与导出拆成两个进程，CLI 负责交接：

1. **求解阶段**：`comsolbatch.exe -inputfile <原模型> -outputfile <modelsdir>\solved\<outname>.mph -batchlog <jobDir>\solve.log -batchlogout -alivetime 5`（配方给了 `Study` 就加 `-study`，`-Cores` 给了就加 `-np`）。
   - 不弹 COMSOL 窗口，headless；**不在原模型旁留 `.lock`**（实测只有它自己的输出模型会被写）。
   - 成功后 CLI 写 `solved` 标记，立刻起导出阶段，不需要人工干预。
2. **导出阶段**：驱动 `solve=0`，只做 打开 → 清点解 → 分块导出。

作业目录里的 `phase` 文件记录当前在 `solve` 还是 `export`，重启 CLI 后据此续跑。

### 6.5 进度显示（v1.7 起）

| 阶段 | 来源 | 口径 |
|---|---|---|
| 求解 | `jobDir\solve.log` 里最后一条 `当前进度: NN % - 阶段` | COMSOL 给的是**整项研究**的全局百分比，不在每个扫参点归零，可直接用；`-batchlogout` 写 stdout 的是 GBK，一律只读 log 文件 |
| 导出 | `jobDir\progress.txt`（驱动原子写 `done=` / `total=` / `label=`） | 解是我们自己枚举的，`已取 x/N` 精确 |

- **已用时间**到秒（定态显示，用来确认进程还活着）；**剩余时间**到分钟；**完成时间点**写成 `21:08` 这种。
- ETA 只用**本次作业实测速率**外推，不看历史：导出 `已用×(总数−已取)/已取`（不平滑）；求解 `已用×(100−p)/p`（`p≥3%` 且已用 ≥8 s 才算，p 上涨时按 `0.6×旧 + 0.4×新` 平滑；p=100% 立即归零）。
- 阶段名由日志里的短语归类：准备 / 网格与建模 / 编译 / 建立求解器 / 组装矩阵 / 矩阵分解 / 解方程 / 收尾。
- 输出被重定向（日志、管道）时自动降级为「阶段变化才打一行」，不会刷屏。

三套样式（`-ProgressStyle`）：

| 样式 | 形态 | 适合 |
|---|---|---|
| 1 | 单行：`▌【求解 1/2】[██░…] 42% 已用 00:07:12 · 剩 约 10 min → 21:08 · 矩阵分解 · sim_xy=501.0 · Q退出 K终止` | 长时间挂着，不滚屏 |
| 2（默认） | 方框五行：作业 / 进度 / 阶段 / 时间 / 按键 | 信息最全 |
| 3 | 八段阶段链 `√准备 √网格 √编译 … ▸收尾` + 解计数 | 一眼看出卡在哪一步 |

窗口标题同步显示 `【求解 42%】<模型名> - COMSOL 导出`，任务栏可见。

进度条是**同一种字形 `█`**（`▓`/`▒`/`░` 在 Consolas 里墨迹位置不同，混用会让"已完成"比"未完成"高），已完成用黄色、未完成用深灰，逐段 `Write-Host -NoNewline -ForegroundColor` 上色。

开窗时自动把窗口设成 88 列宽、高度占满屏幕工作区（`SM_CYFULLSCREEN ÷ 字体单元高度`，字体高度取自 `GetCurrentConsoleFontEx`），并挪到左上角；Windows Terminal 之类不认字符尺寸的宿主会退化成直接最大化。输出被重定向时不改窗口尺寸。

### 6.6 状态框重绘与终止（v1.7.2）

- **差量重绘**：`Show-LiveBox` 把每帧算成「纯文本 + 段数组」，与上一帧逐行比较，只对变化的行 `SetCursorPosition` 后重写，其余行一个字符都不动（不闪、不滚屏、不重复输出）。首帧整框画一次，`Clear-LiveBox` 按行数擦除。
- **开窗尺寸（v1.7.3 改成按像素算）**：`Initialize-ConsoleWindow` 宽度取 `-WinWidth` / `COMSOL_EXPORT_COLS` / 配置 `WindowCols`（默认 88 列），高度取屏幕可用区（`SystemParametersInfo(48)`）的像素高。步骤：`ShowWindow(SW_RESTORE)` 先取消最大化 → 量当前窗口像素 `pixW/pixH` 与 `[Console]::WindowWidth/Height` 算出 `cellW/cellH`（125% 缩放下字体报 16px、实际 20.5px，按磅值算必偏矮）→ `SetBufferSize(cols, 4000)` → `SetWindowPos(top, 0, workTop, newW, workH, 0)` 按像素定尺寸 → 回读 `[Console]::WindowWidth`，差几列就按 `cellW` 补一次（滚动条会吃掉 ~17px）。仍不达标再退 `cmd /c mode con`，最后才最大化。
  - 两个坑：`GetWindowRect(GetConsoleWindow())` 恒返回 0，必须 `GetParent` 拿顶层窗口再量；conhost 下 `[Console]::SetWindowSize` 只改逻辑行列、不动像素，且不夹取到屏幕内。
  - `-WinDebug`（或 `COMSOL_EXPORT_WINDEBUG=1`）打印 `[窗口] 目标 88 列，实得 88x46（px）· 每列 9.99px，每行 20.53px，可用高 912px`；`COMSOL_EXPORT_NORESIZE=1` 关掉整段。
  - 本机实测（1536×960、125%）：`120x30 / 1199×616px` → `88x46 / 899×912px`，窗口高正好等于可用高 912。
- **终止**：`K` → `Stop-OneJob`：立刻写 `killed` 标记（避免被当成正常结束）→ `Get-JobProcIds` 按「命令行含 jobDir / 目录名 / 模型路径」找齐 java 与 comsol 进程（求解阶段是 comsolbatch，导出阶段是 java，还可能派生）→ 最多 12 轮 `taskkill /PID <id> /T /F` + 500 ms 间隔 → 复核残留。调度器每拍先看 `killed` 标记，有就直接判终止并再收一遍残留进程。

## 7. 变更记录

| 版本 | 日期 | 内容 |
|---|---|---|
| v1.0 | 2026-11-12 | 首个可用版本：comsolbatch + Java 驱动、队列、锁、续跑、单实例守卫 |
| v1.0.1 | 2026-11-12 | 修首次运行 `state\` 目录不存在导致写配置失败 |
| v1.1 | 2026-11-12 | 驱动改 handler 分派；新增 `spectrum` / `image` / `eigenslice`；`-DryRun` 不再真正执行 |
| v1.2 | 2026-11-12 | 新增 `-Mode export`（只导出已求解模型，job.properties 的 `solve=0`）；模型列表支持 `.lnk` 快捷方式（显示快捷方式名、按其命名） |
| v1.3 | 2026-11-12 | 预制模块系统（`modules/*.psd1` + 配方 `Use`）；新增 `slice2d`（二维正投影切面）、`integral`（线/面积分）、`modes`（模态数值）三个 handler；`-Modules` 列出模块 |
| v1.4 | 2026-11-16 | 新增 `bigtable`（参数化大表：全局参数 + 谱线 + 相位 + 各 ITO 域吸收）；表头全 ASCII |
| v1.5 | 2026-11-17 | 修多步骤/多研究模型只导出第一步解：改为每个解节点建独立 `Solution` 数据集，取 `getReal()` 的全部解列；不再逐次 `set("solnum")` |
| v1.6 | 2026-11-18 | 修 651 解只导出 400 行：改按 `getSize()[1]` 逐块（`Chunk`，默认 200）显式取解编号，每块校验列数，取不满即报错；NaN 不再静默丢行（`Allownan=1` 才放行）；CSV 改流式写 `.part`；去重 O(n²)→哈希；`-Xmx4g` 改按物理内存自动（`-Heap`/`COMSOL_EXPORT_XMX` 可覆盖） |
| v1.7 | 2026-11-18 | 求解改走 `comsolbatch -batchlog` 的两阶段流程（headless、不留锁、求解完成自动交接导出），CLI 实时显示 求解百分比/导出 `已取 x/N`、已用（秒）、剩余（分钟）、预计完成时刻；新增 `-ProgressStyle 1/2/3` 三套样式、`-Cores`、`-Heap`；不再用历史耗时猜进度 |
| v1.7.1 | 2026-11-18 | 进度条改为同字形 `█` + 分段着色（黄=已完成、深灰=未完成），修「已完成比未完成高」；开窗自动设 88 列宽、高度按屏幕工作区占满并挪到左上角（`-WinWidth`/`COMSOL_EXPORT_COLS`/`COMSOL_EXPORT_NORESIZE`） |
| v1.7.2 | 2026-11-18 | 进度框改**差量重绘**（逐行比对，只重写变化的行，不再整框重画）；`Initialize-ConsoleWindow` 加回读校验与 `mode con` 回退；终止作业重写为「先写 killed 标记 → 按命令行标记扫 java/comsol 进程 → 最多 12 轮 taskkill /T /F → 复核」，调度器见到 killed 标记即收尾，杀不干净也不挂死 |
| v1.7.3 | 2026-11-18 | 窗口尺寸按像素定（量 `cellW/cellH` 后 `SetWindowPos`，先取消最大化），修「窗口没占满高度」；新增 `-WinDebug` 开关（不必再设环境变量） |
| v1.7.4 | 2026-11-19 | 求解失败不再只报 `solve-error`：从 `solve.log` 抠出 comsolbatch 的报错正文（方框后的行）并在 `[失败]` 行里直接打出来；现场清单补 `launch-solve.txt`/`solve.log` 并把 solve.log 尾部两行一起显示（原来只查 `launch.txt`，求解阶段永远显示"无"） |
| v1.7.5 | 2026-11-20 | 场图模块重做：`image` 一次出默认三维视图 + xy/xz/zy 三张真二维切面（`CutPlane`+`PlotGroup2D`），全部带图题/色标/坐标轴；修切面中心索引与偏移单位两个错误（原来切面位置算错、可能出空白图）；新增 `Stretch`（细长截面按画布比例拉伸）与 `Edges` |
| v1.7.7 | 2026-11-20 | 场图改 300 dpi；xz/zy 都出竖图（二维面从 zx 换到 xz）；竖图色标移到底部、标题只用平面名；画布按真实长宽比自动定尺寸 |
| v1.7.10 | 2026-11-20 | 场图改版：三维用 `view=auto`（GUI 同款默认视角）并按几何长宽比给画布；二维 xz/zy 改 `view=auto` 后左右拼成一张 `_xz_zy.png`（色标竖排落在中间）；默认 `Edges=on` 画域边界线；关 COMSOL 徽标与三轴图标；导出后按内容裁白边 |
| v1.7.11 | 2026-11-20 | 场图默认改分量 `Ex,Ey`（逗号分隔逐分量各出一套图）；三维色标移到下方、默认不画坐标框（`Grid` 字段）；三维恢复画域边界线 |
| v1.7.12 | 2026-11-20 | 六张图自动拼成 `_all.png` 总图（2 列 × 3 行，原分辨率）；二维裁掉 COMSOL 方框，只留左边一条轴 |
| v1.7.13 | 2026-11-20 | 场图总表改版：每分量一块（三维｜上 x-y、下 x-z 与 z-y），二维关掉 COMSOL 装饰、改为自绘竖轴+刻度+竖色标（COMSOL 二维的框去不掉）；尺寸改为等比例缩放排版 |
| v1.7.14 | 2026-11-20 | 总表按示意图对齐：左三维占满整块高度，右侧上 x-y（方形、宽=两张侧面+间隔）、下 x-z/z-y 并排铺满其余高度；每张二维各占一格（左轴+场+右色标），不再互相压字 |
| v1.7.15 | 2026-11-20 | 场图**只留组合总表**：分面图改写作业临时目录、拼完即删，`outdir` 不再出 `_3d/_xy/_xz/_zy`；补写 PNG `pHYs`=300 dpi（ImageIO 重编码会丢 dpi，改为 `writePng` 手插，拼版/裁白边/去框/拼图全部走它）；分辨率整体 ×1.5（`SCALE` 常量：`BLOCK_H` 2400→3600、字号边距色标同步、分面画布短边 1200/长边 3600），总表约 5265×4065 |
| v1.7.16 | 2026-11-20 | 产物不再平铺在 `output/`：驱动把 `j.outdir` 改为 `output/<模型文件名去 .mph>/`（`modelBase()`），CSV 与场图都落该子文件夹；`modelsdir` 默认值仍取 `output` 的父目录；驱动日志首行打印产出目录 |
| v1.7.17 | 2026-11-20 | 只改 `cli.ps1`（驱动仍是 v1.7.16，不用重编）：① 所有选择项改成上下键菜单（`Read-Menu`：`▸` 反色、`[n]` 标号保留、数字+Enter 仍可直选；选模型空格勾选、`a` 全选；无人值守重定向时退回输入序号）；② 窗口尺寸改为启动时一次定好、收尾再按像素钉一次高度，去掉 `mode con ... lines=46` 兜底——那是"高度先满足、随后又缩回"的原因；`run.bat` 先设 88×45 消除启动闪屏；③ 去掉结尾「（每个模型一个同名子文件夹）」等废话 |
| v1.7.18 | 2026-11-20 | 只改 `cli.ps1` + `run.bat`：① 修掉启动时 cmd 报的一段乱码——`run.bat` 改成 CRLF + 纯 ASCII 注释（UTF-8 中文注释 + LF 换行会让 cmd 把 rem 行和 powershell 行拼成一条乱命令）；② 菜单不用 `[x]` 了：游标 `❯`、勾选 `●`/`○`，勾选的白字、未选暗灰，不再和序号混淆；确定后清框只留 `✓ 已选` 一行；③ Y/N 提示全换成 `是`/`否` 菜单（`Read-Confirm`）；④ 模型列表直接显示快捷方式指向的模型名，不再写「链接名 → 目标」，也不标色；⑤ 新增 `Cut-Text`，菜单项与结论行按显示宽度截断，长名字不再撑破框 |
| v1.7.19 | 2026-11-21 | 只改 `cli.ps1`：① 所有方框统一内宽 `$script:BoxW = 76`（`Get-BoxWidth`）——标题框、菜单框、进度框、汇总框左右边缘现在对齐，原先进度框固定 74 而其它框随内容伸缩；② 新增 `Trim-Row`，动态内容（作业名、进度细节、模型名）超宽就截断加 `…`，框不再被撑宽；③ 状态条宽度跟方框右缘对齐；④ 窄终端（BufferWidth 偏小）自动等比收缩，不会折行打乱原地刷新的框 |
| v1.7.20 | 2026-11-21 | 只改 `cli.ps1`：开场加 6 行 ANSI 阴影字标 `COMSOL`（`Write-Banner`），对角渐变逐字符上色（白→亮青→深青，`Get-ArtColor` 5 色标插值）；颜色走 24 位 ANSI，靠 `Enable-VtColor` 打开 VT，重定向或拿不到 VT 时退化成单色 `DarkCyan`；字距统一，C 与第一个 O 之间不留额外空隙；标题框文字由「COMSOL 远程自动导出 CLI」改为「会话配置」（产品名已在字标里） |
| v1.7.8 | 2026-11-20 | 修 image 块多解节点报 `Unknown feature`：`Solution` 数据集的 `solution` 只能绑单个解节点，改成按全局 `SolNum` 定位节点后取节点内序号；堆上限加 64GB 封顶（公共电脑几百 GB 内存时不会给到 300GB+） |
| v1.7.9 | 2026-11-20 | 诊断补强：驱动每次启动打 `驱动版本=` 与 class 路径/修改时间（缺这行就是旧 class）、块失败打 FlException 全文与自己的栈帧、场图每步打阶段日志；`cli.ps1` 比对 class 里的版本串（`ExpectedDriverVersion`），不一致时启动前警告并写进 launch.txt；`update.ps1` 新增 `Repair-Driver`：版本不一致时用 COMSOL 自带 javac 自动重编 |

## 8. 待验证 / 已知缺口

- `eigenslice` 的“单解节点内多模态”枚举尚未在真实特征频率模型上跑过（测试模型只有波长解，用 4 个解节点代替验证）。
- `spectrum` 曲线图横轴取默认（未强制设为波长），多条解曲线会画在同一张图上。
- `MaxParallel > 1` 只做过串行实测，并发时的锁竞争未实测。

### 多解导出口径（v1.6 起）

- **先清点再取数**：驱动打开模型后先对每个解节点读 `model.sol(tag).getSize()`（`[自由度, 解数]`），日志打印 `解节点 solX: N 个解` 与 `待导出解数`。`getSize()` 抛错（未初始化的解）的节点记 0 个解并跳过。
- **按块显式指定解编号**：不再依赖 `innerinput=all` 一次取完——解数大（如 651 个 λ）时 COMSOL 会静默少给列。每块用 `innerinput=manualindices` + `solnumindices="1 2 …N"` 精确请求，块大小 `Chunk`（配方字段，默认 200）。
- **列数硬校验**：每块 `getReal()` 返回列数必须等于请求解数，否则抛错中止（提示可能是解没存全或堆不够）。整表行数不再可能比解数少而不报警。
- **NaN 不再静默丢弃**：解不出数（NaN/Inf）的解计数后默认**报错**，不写半截表；确认这些点本来就无定义时，在该块加 `Allownan=1` 才跳过。
- **流式写盘**：逐行写 `<outname>.csv.part`，全部成功才改名；中途失败不留半截 CSV。
- **去重**：整行做键进 `HashSet`（`RowKey`），替掉原先逐行线性比较（42 万行时跑不完）。
- 数据集仍按解节点各建一个 `Solution` 数据集 `dset_sol_<解节点>`；建失败时打日志并回退 `dset1`（不再静默）。
- **Java 堆**：`cli.ps1` 按物理内存自动给（默认 70%，最少 4GB），`-Heap 8g` 或环境变量 `COMSOL_EXPORT_XMX` 可覆盖。解数据总量约为 `解数 × 单解大小`（本仓模型约 8.25MB/解，651 解≈5.4GB），堆小于这个量级时取数会失败或短少。

### 本地回归（2026-11-18，只导出不求解）

- `ITO_LN_ITO_202611111720_波长域_(860,0.5,900).mph`（81 解，`chunk=40` → 3 块）：输出 81 行 × 29 列，与 v1.5 时代生成的 `output\ITO_LN_ITO_202611111720_波长域_(860,0.5,900).csv` **逐字节一致**。
- `ITO_LN_ITO_202611121701_sim_xy&r.mph`（5 个解节点 × 13 解 = 65，`chunk=5`）：逐节点 13/13、合计 65/65，去重合并 26 行（基解与参数组合节点本来就重复）。
- `ITO_LN_ITO_202611141149_宽谱波长域扫描.mph`（5.4GB，**651 解**，`chunk=50`，`-Xmx4g`）：`global` 与 `bigtable` 两块都 `期望 651 / 取到 651`，各写出 651 行（4 列 / 29 列）；λ 400→1050 步 1 完整、无 NaN；两个 handler 的 T/R 与 T00/R00 完全一致；与 2026-11-14 的参照表 `results\20261114_宽谱_400-1050nm_ITO无损\谱线_TRA相位_sim_xy500_r150_400-1050nm_步长1nm.csv` 逐行比对，**绝对差 ≤ 5e-6**（即参照文件 6 位有效数字的舍入量级）。导出全程约 12 min，其中取数约 8 min。




## 附：COMSOL 官方 API

驱动里用到的 COMSOL Java API、踩过的坑与验证记录单独成文：[COMSOL-API.md](COMSOL-API.md)。
