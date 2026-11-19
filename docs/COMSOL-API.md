# COMSOL Java API 笔记（驱动用到的部分）

> 最后更新：2026-11-12 · 对应 COMSOL 6.4 / 驱动 v1.1
> 本文只记**驱动里实际调用过的 API**与踩过的坑，不是 COMSOL 官方文档的替代品。项目自身的接口见 [API.md](API.md)。
> 标“已验证”的条目都在 `ExportDriver.java` 里跑通过；标“未验证”的别直接依赖。

## 1. 取数：EvalGlobal

```java
model.result().numerical().create("gev", "EvalGlobal");
model.result().numerical("gev").set("data", datasetTag);
model.result().numerical("gev").set("expr", new String[]{"c_const/ewfd.freq", "abs(ewfd.S21)^2"});
model.result().numerical("gev").set("descr", new String[]{"lambda_nm", "T"});
double[][] a = model.result().numerical("gev").getReal();
```

| 项 | 结论 | 状态 |
|---|---|---|
| 返回形状 | `[表达式][解]`，不是 `[解][表达式]` | 已验证 |
| 场表达式 | 模型里**没有** `ewfd.T` / `ewfd.R`；用 `abs(ewfd.S21)^2`（T）、`abs(ewfd.S11)^2`（R），否则报 `FlException('Failed_to_evaluate_expression')` | 已验证 |
| 波长 | `c_const/ewfd.freq` 在 6.4 直接返回 nm（866.0）；老版本可能返回 m，按量级判断：`|v| < 1 ? v*1e9 : v` | 已验证 |
| 单点耗时 | 约 53 s（网格复用，不做参数重扫时） | 已验证 |

## 2. 解与数据集

- 一个研究可能产出多个解节点：`sol1`（解 1）、`sol2`（参数化解 1）、`sol3`（sim_xy=501）…；`model.sol(tag).getSize()` 形如 `[521774, 1]`，即该节点 1 个解。
- 想取某个解节点的场：

```java
model.result().dataset().create("dset_x", "Solution");
model.result().dataset("dset_x").set("solution", "sol3");
plotGroup.set("data", "dset_x");
```

- 想取同一节点内第 k 个解：`plotGroup.set("solnum", "k")`；对 `numerical` 节点有同名的 `solnum`。
- **坑**：`set("solnum","-1")` → `属性值无效`；`set("solnum","all")` → `此属性仅支持常量表达式`；`set("solnumindices","1,2,3")` → `解编号无效`。只能 1..N 逐个试，越界抛异常即停。
- **坑**：`dataset("x")` 用 `model.result().dataset(tag)` 取，**不是** `model.result().dataset()(tag)`（后者 `DatasetFeatureListClient` 不可调用）。
- 稳定性：同一模型里不同解节点的参数集可能不同，切换 `solution` 后 `solnum>1` 可能报参数值不匹配，属正常，捕获后 break。

## 3. 绘图组

### 3.1 3D 切片

```java
model.result().create("pg1", "PlotGroup3D");
model.result("pg1").set("data", "dset1");
model.result("pg1").create("sli1", "Slice");
model.result("pg1").feature("sli1").set("quickplane", "xy");   // xy | yz | zx
model.result("pg1").feature("sli1").set("quickz", "0");        // 位置，单位 m
model.result("pg1").feature("sli1").set("expr", "ewfd.normE");
model.result("pg1").run();
```

| 项 | 结论 | 状态 |
|---|---|---|
| 平面取值 | 只有 `xy` `yz` `zx`；写 `xz` 报 `属性值无效 - 属性: quickplane` | 已验证 |
| 位置属性 | `quickx` / `quicky` / `quickz`，字符串，单位 m | 已验证 |
| 子节点访问 | `model.result(tag).feature("sli1")`；`model.result(tag)("sli1")` 会报 `ResultFeatureClient 不可调用` | 已验证 |

### 3.2 1D 曲线

```java
model.result().create("pg1d", "PlotGroup1D");
model.result("pg1d").set("data", "dset1");
model.result("pg1d").create("glob1", "Global");
model.result("pg1d").feature("glob1").set("expr", new String[]{"abs(ewfd.S21)^2", "abs(ewfd.S11)^2"});
model.result("pg1d").feature("glob1").set("descr", new String[]{"T", "R"});
model.result("pg1d").run();
```

- `expr` / `descr` 是数组，用 `set(String, String[])`。
- 横轴未强制指定时取默认（按解的扫描参数），多解会画成多条曲线在同一张图上——项目里 `spectrum` 的 `Plot=true` 就是这个行为。

## 4. 图片导出（Image）

```java
model.result().export().create("img1", "Image");
model.result().export("img1").set("plotgroup", "pg1");
model.result().export("img1").set("imagetype", "png");
model.result().export("img1").set("size", "manualweb");   // current | manualweb | manualprint | presentation
model.result().export("img1").set("unit", "px");
model.result().export("img1").set("width", "800");
model.result().export("img1").set("height", "600");
model.result().export("img1").set("pngfilename", "C:/tmp/a.png");
model.result().export("img1").run();
```

| 项 | 结论 | 状态 |
|---|---|---|
| `size` 取值 | 只有 `current` / `manualweb` / `manualprint` / `presentation`；`set("size","manual")` 报 `属性值无效 - 属性: size (预设)` | 已验证 |
| 像素控制 | `manualweb` + `unit=px` + `width/height` → 输出正好该像素数（实测 1400×1000 得到 1400×1000） | 已验证 |
| `widthpx/heightpx` | 设了不生效，仍出默认 800×600 | 已验证 |
| `manualprint` | 按 cm 算，`width=9/height=7 cm` 只出 106×83 px，不适合做报告图 | 已验证 |
| 导出节点复用 | 同一节点改 `pngfilename` 再 `run()` 可连续出多张；`export(tag).remove()` 需要 `(String,int)` 参数，别用无参版本 | 已验证 |

## 5. 求解与模型加载

```java
ModelUtil.initStandalone(false);
Model m = ModelUtil.load("m", path);
m.study("std1").run();
m.save(target);
ModelUtil.clear();
```

| 项 | 结论 | 状态 |
|---|---|---|
| 版本兼容 | 用低版本驱动打开高版本模型：`FlException: File created with a later version of COMSOL Multiphysics`，模型里还带版本号 | 已验证 |
| 研究标签 | 用 `model.study().tags()` 取真实标签；MCP 的 solve 工具认显示名，驱动里认标签，别混 | 已验证 |
| 求解进度 | standalone 下拿不到，`ModelUtil.showProgress(true)` 报 `No toolkit factory 'swing' found` | 已验证 |
| 单步控制 | 研究里的步骤无法用 `set("activate", false)` 关掉（报 `Invalid_property_value` / `Unknown_property`），只能整研究跑 | 已验证 |
| 已求解模型复用 | `save()` 出的模型可再 `load()` 后直接导出，跳过求解（315 s → 11 s） | 已验证 |

## 6. 编译与类路径

- 用 COMSOL 自带 JDK：`D:\COMSOL\COMSOL64\Multiphysics\java\win64\jre\bin\javac.exe`
- **带内部类/lambda 必须用 javac**：`comsolcompile ExportDriver.java` 只产出主类，运行报 `NoClassDefFoundError: ExportDriver$Handler`。

```
javac -encoding UTF-8 -proc:none -cp "<COMSOL>\plugins\*" ExportDriver.java
java -Xmx4g -cp "<COMSOL>\plugins\*;<driver 目录>" ExportDriver <job.properties>
```

| 坑 | 现象 |
|---|---|
| `-cp` 含空格 | 被拆成两个参数 → `ClassNotFoundException: programs\script\driver`；拼成单串再传 |
| 缺 `-encoding UTF-8` | 源文件里有中文，javac 用 GBK 解码报乱码/编译错 |
| `comsolcompile` 编译失败 | 仍返回 rc=0，错误打在 stdout，要 grep `ERROR` |
| 注解处理器告警 | 加 `-proc:none` 消除 |

## 7. 未验证 / 待补

- 特征频率研究里“单解节点内多模态”的枚举：`set("solnum", k)` 逐 k 取，尚未在真实 eig 模型上完整跑过（测试模型只有波长解）。
- 切片默认视图是自动的，几何纵向很长时图像会显得细长（测试模型 500×400 px 出图即如此），需要更好构图时再设 `view` / 旋转角。
- `PlotGroup1D` 横轴强制设为波长（而不是扫描参数）的写法还没验证。

## 9. 求解器序列生成（createAutoSequences）的坑

批处理（`comsolbatch -study`）在跑之前会先"生成求解器序列"，等价于 GUI 的"显示默认求解器"。这一步失败时日志长这样（方框 + 正文两行）：

```
/*****错误********/
/***************/
未知解。
 - 标记: all
```

对应的 Java 栈（`%USERPROFILE%\.comsol\v64\logs\javabridge*.log`）：

```
com.comsol.util.exceptions.UnknownEntityException: 未知解。
  at ModelEntityListDb.findObject(391)
  at ModelDb.sol(2132)              <- 把字面量 "all" 当成解标签去查
  at StudyMethod.doCreateAutoSequences(328)
  at StudyDb.createAutoSequences(202)
```

**症状**：打开模型 → 32 s → 立刻就挂，没有任何网格/求解进度；保存出来的 .mph 里没有解。

**已复现的触发条件（COMSOL 6.4，2026-11-19）**：一个研究里同时存在**两个参数化扫描（Parametric）研究步**——其中一个处于启用状态、另一个被取消勾选也照样触发。逐个删/留测试：

| 操作（每次重新打开模型） | 生成序列 |
|---|---|
| 原样（`param1` 启用 + `param` 禁用 + wave 启用） | **失败** |
| 只删 `param1`（剩下 `param` 禁用 + wave） | 成功 |
| 只删 `param`（剩下 `param1` 启用 + wave） | 成功 |
| 把 `param` 取消勾选（不删除） | **仍失败** |
| 把 `param` 的 `pname`/`plistarr` 改成和 `param1` 一样 | **仍失败** |
| 删掉 `param` 后**新建**一个同内容的 `param2` | 成功 |

→ 结论：不是列表长度、不是扫描类型，是那个**旧的研究步节点本身带着失效的内部引用**（`keepsol=all` 一类状态在 GUI 里看不出来）。取消勾选没用，**必须删掉重建**。

**办法**：在 GUI 的"研究"里删掉用不到的参数化扫描步（模型 → 研究1 → 右键 → 删除），保存后重跑；生成出来的解序列应与健康模型一致（`sol1` 里只有 `st1`(wave)/`v1`/`s1`，参数化结果在运行时才出现）。

## 10. 版本记录（续）

| 日期 | 版本 | 内容 |
|---|---|---|
| 2026-11-19 | — | 补第 9 节：`createAutoSequences` 报 `未知解。- 标记: all` 的复现矩阵与修法 |

## 8. 版本记录

| 日期 | 版本 | 内容 |
|---|---|---|
| 2026-11-12 | v1.1 | 初建：取数、数据集、绘图组、图片导出、编译、已知缺口 |
