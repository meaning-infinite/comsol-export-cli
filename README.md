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

- 参数没写在模块 `Keys` 里会直接报错，避免拼错字段悄悄失效。
- 老的 `Export = @(@{Type=...})` 写法仍然可用，两种可以混写。
- 加新模块 = 加一个 psd1（复制现有文件改 `Id`/`Kind`/`Defaults`）；加新能力 = 在 `ExportDriver.java` 的 `HANDLERS` 里加一行。

固定口径：取数用 `abs(ewfd.S21)^2` / `abs(ewfd.S11)^2`（模型里没有 `ewfd.T`/`ewfd.R`）；平面名是 `xy` `zx` `yz`（COMSOL 用 `zx` 不用 `xz`）；`At` 单位米，`auto` 取该方向几何中心。

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

## 文档

- 项目接口与扩展指南：[docs/API.md](docs/API.md)
- COMSOL Java API 笔记：[docs/COMSOL-API.md](docs/COMSOL-API.md)
- 配方字段：[recipes/README.md](recipes/README.md)
