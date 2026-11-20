# 导出配方

配方是一个 PowerShell 数据文件（`.psd1`），**必须存成 UTF-8 带 BOM**，否则 PowerShell 5.1 读不了。

## 结构

```powershell
@{
    Task         = '任务名'          # 只用于命名
    Study        = 'std1'            # 要跑的研究标签（GUI 里研究节点右键可看到）
    NameTemplate = '{task}_{model}_{stamp}'
    Export = @( <块1>, <块2>, ... )
}
```

## 两种写法

**写法 A（推荐）：调用预制模块**

```powershell
@{
    Task = 'ITO-LN-ITO'; Study = 'std1'
    NameTemplate = '{task}_{model}_{stamp}'
    Use = @(
        @{ Module = 'spectrum'; Name = 'spectrum' }
        @{ Module = 'slice2d';  Name = 'field'; Planes = @('xy','zx','yz') }
        @{ Module = 'integral'; Name = 'flux'; Dim = 'surface'; Ents = 'all' }
        @{ Module = 'image';    Name = 'field'; SolNum = '1' }
    )
}
```

模块定义在 `script/modules/*.psd1`，`run.bat -Modules` 可看清单。调用时写的键必须在模块的 `Keys` 里，否则报错（防拼错）。不写 `Name` 时用模块名。

**写法 B：直接写导出块**（老写法，仍然可用，可与 A 混写）

```powershell
Export = @( @{ Type='spectrum'; Name='spectrum'; Plot='true' } )
```

`NameTemplate` 里的占位符：`{task}` 配方 Task、`{model}` 模型文件名、`{stamp}` 时间戳 yyyyMMddHHmm。
一个作业有多个导出块时，文件名是 `<outname>_<块 Name>`。

## 解很多的时候（顶层两个可选字段）

| 字段 | 默认 | 用途 |
|---|---|---|
| `Chunk` | `200` | 每次向 COMSOL 要多少个解。解数上千、内存紧时调小（如 `Chunk = 100`）；机器内存富余可调大 |
| `Heap`（命令行 `-Heap`） | 物理内存的 70%（最少 4GB） | Java 堆。解数据总量 ≈ 解数 × 单解大小（本仓约 8.25MB/解，651 解≈5.4GB），堆不够会取数失败 |

```powershell
@{
    Task = 'ITO-LN-ITO'; Study = 'std1'
    NameTemplate = '{task}_{model}_{stamp}'
    Chunk = 100
    Use = @( @{ Module = 'bigtable'; Name = 'bigtable' } )
}
```

导出块里还可以写 `Allownan = 1`：默认解不出数的点（NaN/Inf）会报错中止，确认这些点本来就没定义时才开这个开关跳过它们。

## 导出块

### global — 任意表达式的表

```powershell
@{ Type='global'; Name='TR'
   Expr = @('c_const/ewfd.freq','abs(ewfd.S21)^2','abs(ewfd.S11)^2')
   Cols = @('lambda_nm','T','R') }
```

扫描变量（模型的 `pname`）会自动放在最左两列，行 = 每个解。

### spectrum — 透射/反射谱

```powershell
@{ Type='spectrum'; Name='spectrum'; Plot='true' }
```

列固定为 `lambda_nm,T,R`（`T=|S21|²`、`R=|S11|²`）；`Plot='true'` 再导一张 T/R 曲线 PNG。

### slice2d — 多切面二维正投影（推荐）

```powershell
@{ Type='slice2d'; Name='field'; Expr='ewfd.normE'
   Planes=@('xy','zx','yz'); At='auto'; Width='1200'; Height='900' }
```

每个平面单独出一张 **二维** 图：`xy` 是俯视、`zx` 是侧视、`yz` 是正视，不是三维透视图。
`At` 是切面沿法向的位置（m），`auto` = 该方向几何中心（按几何长度单位自动换算）。

### integral — 线积分 / 面积分

```powershell
@{ Type='integral'; Name='flux'; Dim='surface'
   Ents='all'; Expr=@('ewfd.normE'); Cols=@('E') }
```

`Dim` 取 `surface` 或 `line`；`Ents` 写 `all` 或实体编号 `3,4,17`（编号在 GUI 的几何/选择里看）。
编号不存在会报错并停止该块。输出 CSV：一行一个解。

### modes — 特征频率数值

```powershell
@{ Type='modes'; Name='modes'; Expr=@('ewfd.freq'); Cols=@('freq'); MaxModes='20' }
```

对每个解节点、每个模态取一遍数值，输出去重后的 CSV（列：`mode` + 指定列）。

### bigtable — 通用原始大表（推荐给谱线类需求）

```powershell
@{ Type='bigtable'; Name='bigtable'; Params='all'; AbsDomains='auto'; AbsExpr='ewfd.Qh' }
```

一次给全（表头全英文，无中文）：
- `<参数名>_val`：模型全局参数表全量，自动成列（参数改了不用改配方）
- `lambda_nm freq_THz T00 R00 T_total R_total phase_S21_rad A_1-T-R Pin_W`
- `Qrh_ITO_<layer>_W` / `A_ITO_<layer>_pct`：每个吸收域一组；`<layer>` 由 `AbsDomains` 决定
- `Qrh_ITO_total_W` / `A_ITO_total_pct`

`AbsDomains` 三种写法：
| 写法 | 效果 |
|---|---|
| `auto`（默认） | 取材料名含 ITO 的域，按 z 中心自动命名：2 个→`lower/upper`，3 个→`lower/hole/upper` |
| `3:lower,6:upper,9:hole` | 显式指定域号与名字（域号在 GUI 里看） |
| `none` | 不做吸收分解 |

`Params` 三种写法：`all`（默认，全部参数）/ `none` / `sim_xy,r`（指定名）。

### image — 场图（一张三维 + 三张二维）

```powershell
@{ Type='image'; Name='field'; Expr='ewfd.normE'; Width='1200'; Edges='off' }
```

一次出三个文件（300 dpi，都带图题、色标、坐标轴刻度，默认画域边界线）：

| 文件 | 内容 |
|---|---|
| `<名>_field_3d.png` | 三维默认视角（与 GUI 一致），三张互相垂直的切片（过几何中心），只留一条色标 |
| `<名>_field_xy.png` | 正对 xy 面，横 x 纵 y |
| `<名>_field_xz_zy.png` | 左 x-z、右 z-y 左右拼一张，顶部各带切面名，竖直色标在中间 |

二维图按切面真实长宽比出图（`Height` 不写就自动算），不做拉伸。
`Width` 是长边像素（上限 4096）；`Edges`（默认 `on`）画每个域的边界线；`Title` 空 = 「平面 + COMSOL 自动量名」。
`SolNum`（默认 `1`）= 取第几个解：做「逐共振点各出一组场图」时，每个块填该共振点的解号即可。

也可以走模块写法（推荐）：

```powershell
Use = @( @{ Module='image'; Name='res739'; SolNum='88' } )
```

### eigenslice — 每个特征频率三张切面图

```powershell
@{ Type='eigenslice'; Name='eigen'; Expr='ewfd.normE'
   Planes=@('xy','zx','yz'); At='0'; MaxModes='20'
   Width='1000'; Height='800' }
```

对每个解/模态输出 `<outname>_m<k>_xy.png`、`_zx.png`、`_yz.png`；模型里有多个解节点时文件名带 `_s<j>` 以免互相覆盖。
要求模型里的特征频率研究已经求解过（驱动跑的是配方的 `Study`，特征频率那一步必须在同一个研究里）。

## 例子

- `ITO-LN-ITO.psd1`：只导透射/反射谱。
- `示例-全导出.psd1`：四种类型各一个块，抄字段用。
- `示例-模块.psd1`：只用模块调用的写法（推荐从这里抄）。
- `20261119_候选共振细扫_共振场图导出.psd1`：7 个共振点各调用一次 `image` 模块，一次出 7 组场图（`SolNum` 就是各点在解序列里的序号）。
