<p align="center"><img src="assets/banner.png" alt="COMSOL" width="640"></p>

<p align="center"><b>在远程或公共电脑上批量求解 COMSOL 模型、自动导出数据，只回传结果</b></p>

<p align="center">
  <a href="https://github.com/meaning-infinite/comsol-export-cli/releases"><img alt="version" src="https://img.shields.io/badge/version-v1.9.0-2AA0B0"></a>
  <img alt="platform" src="https://img.shields.io/badge/platform-Windows-0078D6">
  <img alt="powershell" src="https://img.shields.io/badge/PowerShell-5.1-5391FE">
  <img alt="comsol" src="https://img.shields.io/badge/COMSOL-6.1~6.4-368CCB">
</p>

<p align="center"><img src="assets/screenshot.jpg" alt="计算进度" width="780"></p>

## 特性

- **不用守着**：选完模型和配方就交给后台，求解、导出、命名一路做完
- **窗口关了也不丢**：重开后接着等、或补做导出，计算进程不受影响
- **产物归拢**：每次作业独立目录，回传 CSV、图片和 `EXPORT_MANIFEST.md`
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

适配 Windows PowerShell 5.1 和 COMSOL 6.1–6.4。6.2、6.4 已在本机从正式入口导出已有解。6.1、6.3 已核对公共 API，仍待对应安装实测。模型文件须与所选 COMSOL 版本兼容。首次运行会扫描本机 COMSOL 安装，路径记在本地配置里，不进仓库。

## 命令行

| 命令 | 作用 |
|---|---|
| `run.bat` | 交互启动：选模式、选模型、选配方 |
| `run.bat -Mode export` | 只导出，跳过求解 |
| `run.bat -Mode watch` | 只读监视，可与调度窗口同时打开 |
| `run.bat -Resume` | 接管未完成作业、衔接导出并启动待办 |
| `run.bat -KillJob <作业ID>` | 终止该活动作业，ID 见作业列表。数字兼容队列历史序号 |
| `run.bat -Setup` | 修改 COMSOL 路径、模型目录 |
| `run.bat -DryRun` | 只打印作业计划，不写队列、不计算 |
| `run.bat -Cores 8` | 每作业核数 |
| `run.bat -Heap 8g` | 每作业 Java 堆上限 |
| `run.bat -Modules` | 列出预制模块与可覆盖参数 |

多选后按逻辑核数和可用物理内存的 70% 分配预算，资源足够即并行，其余排队。每个模型有独立状态框。K 终止所选作业，Q 退出监视，`-Resume` 接回后台作业。波长域和频域求解按最近两分钟的进度估时。特征频率求解显示阶段和已用时间，日志提供时显示迭代与已收敛特征值数。导出显示当前块计数、各块合计进度和剩余时间估算。

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

## 输出与交接

```text
output/
  <模型名>/<批次ID>/EXPORT_MANIFEST.md
  batch_<批次ID>/
    EXPORT_MANIFEST.md
    <作业ID>/EXPORT_MANIFEST.md
```

单模型回传本次目录，多模型回传整个批次目录。作业清单列出实际输入、研究和解节点、配方快照、运行版本、文件、表格行数及缺件。批次清单列出每个作业的状态和交付链接。求解产生的新模型保存在模型目录的 `solved` 子目录，文件名包含批次 ID。

每行 CSV 保留研究、解节点、节点内序号及全局序号。复现单点场图时，把 `solution_index` 填入 `SolNum`。宽谱吸收使用含全部衍射级的总透射和总反射。

## 离线更新

在发布目录运行 `powershell -ExecutionPolicy Bypass -File pack.ps1`，把生成的 `_dist/*.zip` 带到目标机，执行 `update.bat -Offline "D:\transfer\包名.zip"`。更新器先核对模块、驱动、配方、文档和图片及其 SHA-256，再安装并备份被替换文件。输入 ZIP 可重复使用。

首次从 1.8.x 离线升级时，先将新 ZIP 解压至临时目录。用包内新版 `update.ps1 -Offline <ZIP绝对路径> -InstallDir <现有script目录>` 启动升级。

## 开发

改 `driver/ExportDriver.java` 后须重新编译，内部类才能一并生成：

```bat
set COMSOL=D:\COMSOL\COMSOL62\Multiphysics
"%COMSOL%\java\win64\jre\bin\javac.exe" -encoding UTF-8 -proc:none -source 11 -target 11 ^
    -cp "%COMSOL%\plugins\*" -d driver driver\ExportDriver.java
```

脚本与模块文件须存为 UTF-8 带 BOM，否则 PowerShell 5.1 按 GBK 解码导致整份脚本无法解析。发布驱动使用 Java 11 类文件格式。

队列和离线回归分别运行 `tests/queue.ps1`、`tests/package.ps1`，均使用独立临时目录。

## 文档

- 接口与扩展：[docs/API.md](docs/API.md)
- 配方字段：[recipes/README.md](recipes/README.md)
- COMSOL Java API 笔记：[docs/COMSOL-API.md](docs/COMSOL-API.md)
