<p align="center"><img src="assets/banner.png" alt="COMSOL" width="640"></p>

<p align="center"><b>在远程或公共电脑上批量求解 COMSOL 模型、自动导出数据，只回传结果</b></p>

<p align="center">
  <a href="https://github.com/meaning-infinite/comsol-export-cli/releases"><img alt="version" src="https://img.shields.io/badge/version-v1.8.6-2AA0B0"></a>
  <img alt="platform" src="https://img.shields.io/badge/platform-Windows-0078D6">
  <img alt="powershell" src="https://img.shields.io/badge/PowerShell-5.1-5391FE">
  <img alt="comsol" src="https://img.shields.io/badge/COMSOL-6.x-368CCB">
</p>

<p align="center"><img src="assets/screenshot.jpg" alt="计算进度" width="780"></p>

## 特性

- **不用守着**：选完模型和配方就交给后台，求解、导出、命名一路做完
- **窗口关了也不丢**：重开后接着等、或补做导出，计算进程不受影响
- **产物归拢**：结果写进 `output/<模型名>/`，文件名带模型名与时间戳，整目录回传即可
- **换导出内容不改代码**：配方声明用哪些模块、覆盖哪些参数
- **看得见进度**：单行、方框、阶段链三种样式，原地刷新不滚屏
- **多解不出错**：按块显式取数并逐块核对列数，几百个波长也不会悄悄少列

## 快速开始

```powershell
git clone https://github.com/meaning-infinite/comsol-export-cli.git
```

1. 把 `.mph` 放进 `models/`
2. 双击 `run.bat`，选择模型与配方
3. 结束后从 `output/` 取结果

需要 COMSOL 6.x 与 Windows 10/11。首次运行会扫描本机 COMSOL 安装，路径记在本地配置里，不进仓库。

## 命令行

| 命令 | 作用 |
|---|---|
| `run.bat` | 交互启动：选模式、选模型、选配方 |
| `run.bat -Mode export` | 只导出，跳过求解 |
| `run.bat -Mode watch` | 监视在跑的任务 |
| `run.bat -Resume` | 接着跑队列里没完成的作业 |
| `run.bat -KillJob 2` | 终止第 2 个作业 |
| `run.bat -Setup` | 修改 COMSOL 路径、并发数、模型目录 |
| `run.bat -DryRun` | 只打印作业计划，不写队列、不计算 |
| `run.bat -Cores 8` | 指定核数 |
| `run.bat -Heap 8g` | 指定 Java 堆 |
| `run.bat -Modules` | 列出预制模块与可覆盖参数 |

双模型同时运行：在 `-Setup` 中将并发数设为 2，再从同一窗口选中两个模型。并行进度按作业显示，K 终止所选作业，Q 退出监视，`-Resume` 接回后台作业。剩余时间按最近两分钟的进度估算。

## 配方

导出内容全在 `recipes/*.psd1`。配方声明用哪些模块、覆盖哪些参数：

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

| 模块 | 产出 |
|---|---|
| `table` | 任意表达式的数据表，每解一行 |
| `spectrum` | 透射/反射谱，附曲线图 |
| `slice2d` | 指定平面的二维场图 |
| `image` | 单点场图总表，三维加三切面拼成一张 |
| `modes` | 特征频率等模态数据 |
| `integral` | 线、面积分 |
| `bigtable` | 全局参数、谱线、分域吸收合成一张大表 |

模块位于 `script/modules/`，新增能力只需在 `driver/ExportDriver.java` 的 `HANDLERS` 中注册。

## 输出

```
output/
  ITO_LN_ITO_202611121701_sim_xy&r/     ← 每个模型一个同名目录
    ITO-LN-ITO_..._spectrum.csv
    ITO-LN-ITO_..._field_all.png         ← 300 dpi
```

## 开发

改 `driver/ExportDriver.java` 后须重新编译，内部类才能一并生成：

```bat
set COMSOL=D:\COMSOL\COMSOL64\Multiphysics
"%COMSOL%\java\win64\jre\bin\javac.exe" -encoding UTF-8 -proc:none ^
    -cp "%COMSOL%\plugins\*" -d driver driver\ExportDriver.java
```

脚本与模块文件须存为 UTF-8 带 BOM，否则 PowerShell 5.1 按 GBK 解码导致整份脚本无法解析。`update.ps1` 每次运行会自动补。

## 文档

- 接口与扩展：[docs/API.md](docs/API.md)
- 配方字段：[recipes/README.md](recipes/README.md)
- COMSOL Java API 笔记：[docs/COMSOL-API.md](docs/COMSOL-API.md)
