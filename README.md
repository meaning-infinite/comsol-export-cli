# COMSOL 导出 CLI

在远程/公共电脑上批量跑 COMSOL 模型、自动导出数据，只把 CSV 传回来。不用把 `.mph` 搬来搬去，也不用在 GUI 里手点导出。

## 干什么

1. 把裸模型放进 `model/`
2. 运行 `run.bat`，选模型、选导出配方
3. 后台求解 → 按配方取数 → 写 CSV 到 `output/`，文件名自动带模型名和时间戳
4. 关掉窗口不影响计算；重开会自动接着等、或补做导出

## 目录

```
<根>/
  model/            裸模型（人工上传，参数在模型里设好）
  script/           ← 本仓库
    run.bat         双击入口
    cli.ps1         全部逻辑
    driver/         ExportDriver.java（求解 + 取数 + 写文件）
    recipes/        导出配方，见 recipes/README.md
  output/           导出的 CSV，只回传这个目录
```

## 常用命令

| 命令 | 作用 |
|---|---|
| `run.bat` | 正常启动：选模型 → 选配方 → 确认 |
| `run.bat -Resume` | 不选东西，直接接着跑队列里没完成的作业 |
| `run.bat -KillJob 2` | 终止第 2 个作业（只杀本 CLI 启动的） |
| `run.bat -Setup` | 改 COMSOL 路径 / 并发数 / 模型目录 |
| `run.bat -DryRun` | 只打印将要生成的作业与文件名，不算 |

## 状态与续跑

每个作业一个目录 `script/logs/<时间戳>_<模型名>/`，里面放作业文件、日志和标记：

| 标记 | 含义 | 重开 CLI 时 |
|---|---|---|
| 无标记 | 还没开始或中途断了 | 报"断开"，可手动重跑导出 |
| `solved` | 模型已算完（`models/solved/` 里有解场） | 只补导出，不重新求解 |
| `exporting` | 正在写 CSV | 等待 |
| `exported` | 全部写完 | 视为完成，顺手清自己的 `.lock` |

监视时：`Q` 退出监视（不杀计算），`K` 终止本 CLI 启动的作业。

## 锁

只处理本作业自己那个模型的 `.lock`，且要同时满足：文件名对得上、没有别的进程在用这个模型、锁文件比作业启动晚、改名成功。任一条不满足就保留不动，避免误删别人的锁。

## 环境

- Windows + PowerShell 5.1
- COMSOL 6.x（`comsolbatch.exe` 所在版本必须 ≥ 保存模型用的版本）
- 首次运行会扫 COMSOL 安装并记在本机配置里，不写进仓库

## 配方

导出什么、叫什么，全在 `recipes/*.psd1` 里，见 [recipes/README.md](recipes/README.md)。
