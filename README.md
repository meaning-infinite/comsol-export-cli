# COMSOL 导出 CLI

在远程/公共电脑上批量跑 COMSOL 模型、自动导出数据，只把结果回传。不用把 `.mph` 搬来搬去，也不用在 GUI 里手点导出。

## 干什么

1. 把裸模型放进 `models/`（参数、波长窗口都在模型里设好）；也可以放**指向 .mph 的快捷方式**（.lnk），CLI 会显示快捷方式名字、按快捷方式名字命名产物
2. 运行 `run.bat`，选模型、选配方
3. 后台求解 → 按配方的 Export 块导出 CSV/PNG → 写进 `output/`，文件名自动带模型名和时间戳
4. 关掉窗口不影响计算；重开会自动接着等、或补做导出

## 目录

```
<根>/
  models/           裸模型（人工上传）
  script/           ← 本仓库
    run.bat         双击入口
    cli.ps1         全部逻辑
    driver/         ExportDriver.java（求解 + 导出 + 写文件）
    recipes/        导出配方，见 recipes/README.md
    modules/        预制模块，配方用 Use 调用，见下文
    logs/           每个作业一个目录（作业文件 + 日志 + 标记）
  output/           导出的 CSV / PNG，只回传这个目录
```

## 常用命令

| 命令 | 作用 |
|---|---|
| `run.bat` | 正常启动：选模型 → 选配方 → 确认 |
| `run.bat -Mode export` | 只导出：模型里已经有解，跳过求解（交互时在选模型之前会先问模式） |
| `run.bat -Mode solve` | 求解并导出（默认） |
| `run.bat -Resume` | 不选东西，直接接着跑队列里没完成的作业 |
| `run.bat -KillJob 2` | 终止第 2 个作业（只杀本 CLI 启动的） |
| `run.bat -Setup` | 改 COMSOL 路径 / 并发数 / 模型目录 |
| `run.bat -DryRun` | 只打印作业与导出块，不写队列、不启动计算 |
| `run.bat -Modules` | 列出所有预制模块与可覆盖参数 |
| `run.bat -ProgressStyle 3` | 换进度样式：`1` 单行 / `2` 方框（默认）/ `3` 阶段链 |
| `run.bat -Cores 8` | 求解给 8 个核（默认交给 COMSOL 自己定） |
| `run.bat -Heap 8g` | 手动指定 Java 堆（默认按物理内存 70%） |

## 预制模块（推荐写法）

导出能力做成模块放在 `script/modules/*.psd1`，配方只写「用哪个模块、覆盖哪些参数、叫什么」：

```powershell
@{
    Task = 'ITO-LN-ITO'; Study = 'std1'
    NameTemplate = 'ITO-LN-ITO_{model}_{stamp}'
    Use = @(
        @{ Module = 'spectrum'; Name = 'spectrum' }
        @{ Module = 'slice2d';  Name = 'field'; Planes = @('xy','zx','yz') }
    )
}
```

| 模块 | 产出 | 可覆盖 |
|---|---|---|
| `table` | 数据 CSV（任意表达式，每解一行） | `Expr` `Cols` |
| `spectrum` | 透射/反射谱 CSV（λ,T,R）+ 可选曲线 PNG | `Plot` |
| `slice2d` | 每个平面一张**二维正投影** PNG（xy→俯视、zx→侧视、yz→正视） | `Expr` `Planes` `At` `Width` `Height` `Title` |
| `modes` | 每个模态一行数值 CSV（特征频率等） | `Expr` `Cols` `MaxModes` |
| `integral` | 线/面积分数值 CSV | `Dim`(surface/line) `Ents`(all 或 `3,4,17`) `Expr` `Cols` |
| `bigtable` | 通用原始大表：全局参数 + 谱线 + 各域吸收，一文件全给（表头全英文） | `Params`(all/none/名单) `AbsDomains`(auto/编号:名字) `AbsExpr` |

- 参数没写在模块 `Keys` 里会直接报错，避免拼错字段悄悄失效。
- 老的 `Export = @(@{Type=...})` 写法仍然可用，两种可以混写。
- 加新模块 = 加一个 psd1（复制现有文件改 `Id`/`Kind`/`Defaults`）；加新能力 = 在 `ExportDriver.java` 的 `HANDLERS` 里加一行。

固定口径：取数用 `abs(ewfd.S21)^2` / `abs(ewfd.S11)^2`（模型里没有 `ewfd.T`/`ewfd.R`）；平面名是 `xy` `zx` `yz`（COMSOL 用 `zx` 不用 `xz`）。

场图（`Type = 'image'`，或写进配方的 `Export`）一次出四张，**300 dpi**，都带图题、色标、坐标轴刻度：

| 文件 | 内容 |
|---|---|
| `<名>_field_3d.png` | 三维默认视角，三张互相垂直的切片 |
| `<名>_field_xy.png` | 横 x 纵 y（方图） |
| `<名>_field_xz.png` | 横 x 纵 z（**竖图**） |
| `<名>_field_zy.png` | 横 y 纵 z（**竖图**） |

三个二维面都过几何中心，**按切面真实长宽比出图**（不做拉伸）：方形截面出方图，细长截面（如 500×5080 nm 的侧壁）出竖长条图，色标自动挪到下方。`Width` 是长边像素（宽高上限都是 4096），高度自动算；`Edges = 'on'` 画网格边。

## 解很多的时候（651 个波长这种）

- 驱动先清点：对每个解节点读 `model.sol(tag).getSize()[1]`，日志打 `解节点 solX: N 个解` 与 `待导出解数`。
- 再按块显式取：配方字段 `Chunk`（默认 200）控制每块多少个解，用 `innerinput=manualindices` + `solnumindices="1 2 …N"` 精确请求。**不再靠「取全部解」一次取完**——解多时 COMSOL 会静默少给列（远程曾出现 651 个解只写出 400 行）。
- 每块校验「请求解数 = 返回列数」，不等就报错中止；解不出数的点（NaN/Inf）默认也报错，不写半截表（确认这些点本来无定义时在该块加 `Allownan=1`）。
- 堆按物理内存自动给（默认 70%，最少 4GB）：`run.bat -Heap 8g` 或环境变量 `COMSOL_EXPORT_XMX=8g` 覆盖。解数据总量 ≈ 解数 × 单解大小（本仓约 8.25MB/解）。
- 对账就看日志三行：`解节点 solX: 期望 N 个解，取到 M 列`、`合计 …`、`写出 …（N 行 × M 列）`。

## 进度显示

求解和导出是两个进程，CLI 负责交接：`comsolbatch` 先 headless 跑研究（不弹窗口、不占原模型），算完自动接着导出，中间不用管。

| 看什么 | 从哪来 | 长什么样 |
|---|---|---|
| 求解进度 | `logs/<作业>/solve.log` 里的 `当前进度: NN % - 阶段` | 整项研究的百分比，扫参时不会每个点归零 |
| 导出进度 | `logs/<作业>/progress.txt`（驱动逐块写） | `已取 120/651 个解 · 导出块 1/2` |
| 已用时间 | 作业启动时刻 | `已用 00:07:12`，定态到秒——数字在走就说明进程还活着 |
| 剩余时间 | 本次作业实测速率外推 | `剩 约 10 min`（不到 30 s 显示"即将完成"） |
| 完成时刻 | 同上 | `预计 21:08 完成` |

三套样式（`-ProgressStyle`，也可以设环境变量 `COMSOL_EXPORT_STYLE`；默认取配置 `ProgressStyle`，再不行用 `2`）：

| 样式 | 形态 | 适合 |
|---|---|---|
| `1` | 单行：`▌【求解 1/2】[██████    ] 42% 已用 00:07:12 · 剩 约 10 min → 21:08 · 矩阵分解 · sim_xy=501.0 · Q退出 K终止` | 长时间挂着，不滚屏 |
| `2` | 方框五行：作业 / 进度 / 阶段 / 时间 / 按键 | 信息最全（默认） |
| `3` | 八段链 `√准备 √网格 √编译 √求解器 √组装 √分解 √解方程 ·收尾` | 一眼看出卡在哪一步 |

窗口标题也带进度：`【求解 42%】<模型名> - COMSOL 导出`。

状态框是**原地差量刷新**：只重写变化的那几行（进度、阶段、时间），其余行不动，所以不会整屏重画、不会滚屏。第一次画出来之后就一直停在原处。

窗口开出来就设好尺寸：宽度 88 列（方框 74 字 + 边距），高度占满屏幕可用高度，并挪到左上角。
想改宽度用 `-WinWidth 100`；不想让它动窗口就设环境变量 `COMSOL_EXPORT_NORESIZE=1`；想知道到底设上没有，加 `-WinDebug`，会多打一行 `[窗口] 目标 88 列，实得 …（px）· 每列 …px，每行 …px，可用高 …px`。
（口径：像素尺寸是量出来的，不是按字体磅值算的——125% 缩放下字体报 16px、实际每行 20.5px，按磅值算必然偏矮。）

按 `K` 终止是真杀进程：求解阶段的 `comsolbatch` 和导出阶段的 `java` 都按命令行识别（含作业目录或模型路径），连派生子进程一起 `taskkill /T /F`；最多重试 12 轮，杀完人工复核残留。作业一旦按过终止，就不会再被当成正常结束接手。
把输出重定向到日志/管道时，自动降级成"阶段变了才打一行"，不刷屏。

注意：进度条用的是**本次作业自己测出来的速率**，不看历史记录，所以刚开始的几分钟显示"未知"或跳动是正常的，跑过 3% 之后才稳定。

## 状态与续跑

每个作业一个目录 `script/logs/<时间戳>_<模型名>/`，里面放作业文件、日志和标记：

| 标记 | 含义 | 重开 CLI 时 |
|---|---|---|
| 无标记 | 还没开始或中途断了 | 报"断开"，可手动重跑导出 |
| `solved` | 模型已算完（`models/solved/` 里有解场） | 只补导出，不重新求解 |
| `exporting` | 正在写文件 | 等待 |
| `exported` | 全部写完 | 视为完成，顺手清自己的 `.lock` |

监视时：`Q` 退出监视（不杀计算），`K` 终止本 CLI 启动的作业。

## 锁

只处理本作业自己那个模型的 `.lock`，且要同时满足：文件名对得上、没有别的进程在用这个模型、锁文件比作业启动晚、改名成功。任一条不满足就保留不动，避免误删别人的锁。

## 改驱动后要重新编译

带内部类的源码用 `comsolcompile` 只会生成主类文件，必须用 COMSOL 自带的 `javac`：

```bat
set COMSOL=D:\COMSOL\COMSOL64\Multiphysics
"%COMSOL%\java\win64\jre\bin\javac.exe" -encoding UTF-8 -proc:none ^
    -cp "%COMSOL%\plugins\*" -d driver driver\ExportDriver.java
```

## 环境

- Windows + PowerShell 5.1
- COMSOL 6.x（`comsolbatch.exe` 所在版本必须 ≥ 保存模型用的版本）
- 首次运行会扫 COMSOL 安装并记在本机配置里，不写进仓库

## 配方

导出什么、叫什么，全在 `recipes/*.psd1` 里，见 [recipes/README.md](recipes/README.md)。


## 编码（别踩的坑）

`cli.ps1`、`update.ps1`、`pack.ps1`、`modules\*.psd1`、`recipes\*.psd1` **必须存成 UTF-8 带 BOM**。PowerShell 5.1 会把无 BOM 的 UTF-8 按 GBK 解码，中文串被吃坏后整份脚本直接解析失败，报一串 `Missing closing '}'` / `意外的标记"}"`（实测：去掉 BOM 后 132 处报错，加上就 `PARSE_OK`）。

`update.ps1` 与 `pack.ps1` 现在每次运行都会自动扫一遍并补 BOM；自己改脚本或从别处拷脚本进来，也要保持 BOM。

## 文档


- 项目接口与扩展指南：[docs/API.md](docs/API.md)
- COMSOL Java API 笔记：[docs/COMSOL-API.md](docs/COMSOL-API.md)
- 配方字段：[recipes/README.md](recipes/README.md)
