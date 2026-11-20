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

## 11. 绘图与出图的坑（2026-11-20 实测，COMSOL 6.4）

### 11.1 场图装饰：总闸在 Image 节点，不在绘图组
- 绘图组上设 `legendactive=on`、`axisactive=on`、`title=...` **完全不影响导出**（导出文件字节一模一样）。
- 真正生效的是 Image 导出节点上的三组开关：`options1d/options2d/options3d`（**默认 `off`**）+ `titleNd` / `legendNd`。把 `options2d/options3d` 设 `on`，图题、色标、坐标轴立刻出来。
- 图题还要 `titletype=manual`；不设 manual 时 COMSOL 用自动量名（如「电场模 (V/m)」），可用 `getString("title")` 读出来再拼。

### 11.2 二维切面：CutPlane + PlotGroup2D
- 建立路径：`result().dataset().create(tag,"CutPlane")` → `set("data",<3D 数据集>)`、`set("quickplane","xy|zx|yz")`、`set(offsetKey, 位置)`；再 `result().create(tag,"PlotGroup2D")` + `Surface`。
- **偏移量单位 = 几何长度单位**（本机模型 nm），不是米；乘 1e-9 会把切面推出模型外。
- 包围盒 `getBoundingBox()` 顺序是 `[xmin,xmax,ymin,ymax,zmin,zmax]`；xy 面取 `(bb[4]+bb[5])/2`，zx 面取 `(bb[2]+bb[3])/2`，yz 面取 `(bb[0]+bb[1])/2`。
- 二维坐标里 **plane 名的第一个字母是横轴**：`xy`→(x,y)、`zx`→(z,x)、`yz`→(y,z)。

### 11.3 二维视图的轴范围与长宽比
- 2D 绘图组的 `view` 合法值形如 `auto | new | view2`（`view2` 是模型自带的 `ResultView2D`）；`view="auto"` 只能自动适配，压不住范围。
- `view2.axis()`：`viewscaletype` 取 `manual` 时才认 `xmin/xmax/ymin/ymax`；取 `none` 会自己缩。
- **COMSOL 保持等比例**：把 `xmin/xmax/ymin/ymax` 设成数据范围后，画面仍按 1:1 缩放，结果就是细长截面缩成一条窄带、两侧大片空白。
- 实测过的另一条路：`xscale/yscale` 能把数据拉满画布，但那是**人为变形**，出图不能用；真要铺满就改画布尺寸——按切面真实长宽比算画布（本项目 `canvasSize()` 的做法），这样 1:1 缩放时数据自然铺满。
- 换平面时务必把 `xscale/yscale` 归零，否则上一张的拉伸会把下一张的轴撑开。

### 11.4 尺寸与导出
- `Image.size` 合法值：`current | manualweb | manualprint | presentation`；`presentation` 在 API 里报「仅支持文件目标」。常用 `manualweb` + `unit=px` + `width/height`。
- 一张 2D 场图：`run()` 约 2 s、导出约 2 s（1200×900 级别），比求解便宜得多。
- 多个绘图特征（三个 Slice）会各画一条色标；用各特征 `rangeactualminmax` 取并集，统一 `rangecoloractive=on` + `rangecolormin/max`，再把除第一个之外的 `colorlegend` 设 `off`，只留一条。
- **dpi**：`Image` 节点有 `resolution`（默认 `96`），设 `300` 后 PNG 的 dpi 元数据读出来是 `299.9994`；`size=manualweb`+`unit=px` 时它只影响元数据与字号渲染，像素尺寸仍由 `width/height` 定。
- **字号**：同一节点有 `fontsize`（默认 `9`）。300 dpi 下 9 pt ≈ 37 px，窄面板（403 px 宽）里字会糊满画面 → 按短边缩放，取 `round(shortSide×0.03×72/300)`，夹在 3–9。
- **像素上限**：宽、高**都是 4096**，超了分别报 `The_width_must_not_exceed_X_pixels#4096` / `高度不得超过 4096 像素。`，`manualweb`/`manualprint`/`current` 都一样。
- **`quickplane` 六个值**：`xy, yz, zx, yx, zy, xz`。`zx` 是横 z 纵 x（横图），`xz` 是横 x 纵 z（竖图），`yz` 是横 y 纵 z（竖图）。
- **色标位置**：`PlotGroup2D.legendpos` 合法值 `alternating | bottom | left | leftdouble | right | rightdouble`。细长竖图用 `bottom`：右侧色标会吃掉本就只有几百像素的宽度，COMSOL 为保 1:1 把纵轴撑大，数据只剩中间一条。

### 11.5 多解节点下的「解号」（2026-11-20 实测，v1.7.8）

`Solution` 数据集的 `solution` 属性**一次只能绑一个解节点**：`getAllowedPropertyValues("solution")` 返回的就是 `none, sol1, sol2, …`。

| 写法 | 结果 |
|---|---|
| `set("solution", "all")` | `FlException: 未知特征。- 标记: all` |
| `set("solution", "dset1")` | `FlException: 未知特征。- 标记: dset1`（把数据集 tag 当解 tag 用） |
| `set("solution", "sol1, sol2")` | 同上，不接受列表 |
| `set("solution", "sol2")` | 成功，`getString` 读回 `sol2` |

因此「全部解里的第 N 个」必须先定位到解节点，再在该节点内数序号：

```
sol1 1-28, sol2 29-56, sol3 57-167, …   (按 model.sol().tags() 顺序，getSize()[1] 为各节点解数)
```

驱动里对应 `pickSol(job, solnum)`：按 `j.sols` 累加找节点，返回 `{节点 tag, 节点内序号}`；绘图组的 `solnum` 用**节点内序号**，日志打 `场图解 N → 解节点 solX 第 M 个`。若直接拿全局 N 去设 `solnum`，超出该节点解数就报解号无效或图空白。

## 10. 版本记录（续）

| 日期 | 版本 | 内容 |
|---|---|---|
| 2026-11-19 | — | 补第 9 节：`createAutoSequences` 报 `未知解。- 标记: all` 的复现矩阵与修法 |
| 2026-11-20 | v1.7.5 | 补第 11 节：场图装饰总闸（`optionsNd`）、CutPlane 偏移单位、二维坐标映射、等比例/拉伸、色标合并 |
| 2026-11-20 | v1.7.7 | 补 11.4：`resolution`/`fontsize`/4096 上限、`quickplane` 六个值、`legendpos=bottom` |
| 2026-11-20 | v1.7.8 | 补 11.5：`Solution` 数据集的 `solution` 只能绑一个解节点（`all` 报 `未知特征`）；全局解号需先翻成「节点 + 节点内序号」 |
| 2026-11-20 | v1.7.10 | 补 11.6：三维用 `view=auto` 才是 GUI 同款默认视角；`logo3d/logo2d`、`axisorientation` 关徽标与三轴图标；`edges=on` 才是域边界线；二维 `view=auto` 轴范围正好框数据（手工 view2 会被 1:1 撑大）；COMSOL 一次导出只能一个 plot group，左右拼图得导出后用 ImageIO 拼 |

### 11.6 场图配色与排版（v1.7.10 实测）

- **三维默认视角**：`PlotGroup3D.set("view","auto")` 即 GUI 里新建三维绘图组时的默认视角；显式绑 `view1`（ModelView3D）反而可能得到被裁剪/偏移的画面。`view=auto` 时画布比例仍要自己给（几何细长就给竖长画布），否则四周大片留白。
- **徽标与三轴图标**：`Image.export` 节点上的 `logo1d/logo2d/logo3d`、`axisorientation` 默认都是 `on`，要显式设 `off`；它们和 `optionsNd` 一样只在导出节点生效，绘图组上的同类属性无效。
- **域边界线**：`PlotGroup2D.edges="on"` 才画出每个域的轮廓（连同单元边）；`off` 是纯净色块。要“边界线但不要密密麻麻的网格线”，只能靠网格本身够粗，COMSOL 没有单独的“只画域边界”开关。
- **二维轴范围**：`view="auto"` 时 COMSOL 把轴范围正好框到数据；手工 `viewscaletype=manual` + 显式 `xmin/xmax` 虽然读回值正确，但导出时仍按 1:1 等比例把轴撑大（画布窄、色标又占宽时尤其明显），数据会缩成中间一条。
- **色标位置**：`legendpos` 是绘图组属性，`right` 为竖直贴右；两张竖图左右拼接时，左图留色标、右图 `colorlegend=off`，拼完色标正好落在中间。
- **拼接与裁边**：COMSOL 一次导出只能指定一个 plot group，多面板只能导出后自己拼（驱动里 `stitchH` 用 `Graphics2D` 白底横拼；`cropWhite` 逐像素找非白 bbox 裁边）。拼接用 300 dpi 原图，别先缩放。
- **栅格（v1.7.11）**：导出节点的 `grid` 就是三维那个坐标框 —— 设 `off` 时框线、刻度、数字一起消失（图很干净但没有比例信息）；`showgrid` 单独关不掉框线。所以驱动把 `grid` 做成 `image` 块的 `Grid` 字段（默认 `off`，要刻度就写 `Grid='on'`）。
- **二维的方框去不掉（v1.7.12）**：`PlotGroup2D` 的 `axisactive`、`frametype`（mesh/geometry/material/spatial/fromdataset）在导出时都不生效，二维导出必然带一圈坐标框；要「只留一条左边轴」只能导出后把上/右/下三边裁掉再补白。
- **色标长度（v1.7.11）**：`legendpos=right` 时长条会跟画布等高，细长样品的色标自然比模型长一截；设 `legendpos=bottom` 后色标是横条、长度只跟画布宽有关，3D 图现在用它。
- **域边界与网格线**：`PlotGroup3D/2D.edges="on"` 画的是单元边（网格）；`Grid` 关掉坐标框不影响它，所以三维可以「有结构轮廓、没有坐标框」。

## 8. 版本记录

| 日期 | 版本 | 内容 |
|---|---|---|
| 2026-11-12 | v1.1 | 初建：取数、数据集、绘图组、图片导出、编译、已知缺口 |
