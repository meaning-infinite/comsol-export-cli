# COMSOL 导出 CLI · API 文档

> 最后更新：2026-11-12 · 对应 v1.1 · COMSOL 侧 API 见 [COMSOL-API.md](COMSOL-API.md)
> 接口与内部约定的参考手册，随版本持续更新。使用说明见 [README.md](../README.md)，配方写法见 [recipes/README.md](../recipes/README.md)。

## 1. 分层与调用链

```
run.bat  →  cli.ps1  →  job.properties  →  ExportDriver.java  →  handler  →  output/
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
| `Q` | 监视中 | 退出监视，不杀计算；再进一次继续显示 |
| `K` | 监视中 | 列出本 CLI 启动且在跑的作业，选序号可终止 |

### 2.4 内部函数（维护时定位用）

| 函数 | 作用 |
|---|---|
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
| `Write-Box` / `Write-BoxRows` | 画框（中文双宽对齐） |

## 3. 作业文件 job.properties

CLI 生成，驱动逐行 `key=value` 读（不用 `java.util.Properties`，避免反斜杠被当转义）。

| 键 | 说明 |
|---|---|
| `model` | 模型绝对路径 |
| `study` | 研究标签，空则取模型第一个研究 |
| `outdir` | 输出目录 |
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

### 4.4 image

| 字段 | 默认 | 说明 |
|---|---|---|
| `Expr` | `ewfd.normE` | 切片表达式 |
| `Plane` | `xy` | `xy` / `zx` / `yz` |
| `At` | `0` | 沿法向位置，单位 m |
| `SolNum` | `1` | 取第几个解 |
| `Width` / `Height` | `800` / `600` | 像素 |
| `Title` | 空 | 图标题 |

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
- 几何包围盒 `getBoundingBox()` 返回的是**几何长度单位**（本模型为 nm），必须乘 `lengthUnit()` 的换算系数再当米用，否则 `auto` 位置落在模型外、出空白图（踩过一次）。
- 2D 图组 + CutPlane 才是真二维投影；用 3D 图组切片的透视投影，画面是斜看的长条。

### 4.7 integral — 线/面积分（2026-11）

字段：`Dim`（`surface`|`line`）、`Ents`（`all` 或编号列表 `3,4,17`）、`Expr`、`Cols`。
实现：`numerical().create(tag,"IntSurface"/"IntLine")`，`selection().all()` 或 `selection().set(int[])`；逐解节点、逐 `solnum` 取值，去重后写 CSV（一行一个解）。编号不存在时报错并中止该块。

### 4.8 modes — 模态数值表（2026-11）

字段：`Expr`（默认 `ewfd.freq`）、`Cols`、`MaxModes`（默认 50）。
实现：`EvalGlobal` + 逐 sol 逐 solnum，遇异常即停；输出列 `mode` + 指定列。对波长解模型也能用（每个解一行，值相同则去重）。

### 4.9 预制模块系统（2026-11）

`script/modules/<id>.psd1` 每个文件一个模块：

```powershell
@{ Id='slice2d'; Kind='slice2d'; Title='多切面（二维视图）'
   Defaults=@{ Expr='ewfd.normE'; Planes=@('xy','zx','yz'); At='auto' }
   Keys=@('Expr','Planes','At','Width','Height','Title','Name') }
```

配方 `Use = @(@{ Module='slice2d'; Name='field'; Planes=@('xy') })` 由 `Expand-Blocks`（cli.ps1）解析：
1. 取模块 `Defaults`；2. 用调用里的键覆盖（`Name` 单独处理，其余必须在 `Keys` 里，否则报错）；3. 补 `Type=Kind`；4. 与老写法 `Export` 块合并。

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
| `j.outdir` / `j.outname` | 输出目录 / 文件名 |
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

## 7. 变更记录

| 版本 | 日期 | 内容 |
|---|---|---|
| v1.0 | 2026-11-12 | 首个可用版本：comsolbatch + Java 驱动、队列、锁、续跑、单实例守卫 |
| v1.0.1 | 2026-11-12 | 修首次运行 `state\` 目录不存在导致写配置失败 |
| v1.1 | 2026-11-12 | 驱动改 handler 分派；新增 `spectrum` / `image` / `eigenslice`；`-DryRun` 不再真正执行 |
| v1.2 | 2026-11-12 | 新增 `-Mode export`（只导出已求解模型，job.properties 的 `solve=0`）；模型列表支持 `.lnk` 快捷方式（显示快捷方式名、按其命名） |
| v1.3 | 2026-11-12 | 预制模块系统（`modules/*.psd1` + 配方 `Use`）；新增 `slice2d`（二维正投影切面）、`integral`（线/面积分）、`modes`（模态数值）三个 handler；`-Modules` 列出模块 |

## 8. 待验证 / 已知缺口

- `eigenslice` 的“单解节点内多模态”枚举尚未在真实特征频率模型上跑过（测试模型只有波长解，用 4 个解节点代替验证）。
- `spectrum` 曲线图横轴取默认（未强制设为波长），多条解曲线会画在同一张图上。
- `MaxParallel > 1` 只做过串行实测，并发时的锁竞争未实测。

## 附：COMSOL 官方 API

驱动里用到的 COMSOL Java API、踩过的坑与验证记录单独成文：[COMSOL-API.md](COMSOL-API.md)。
