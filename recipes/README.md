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

`NameTemplate` 里的占位符：`{task}` 配方 Task、`{model}` 模型文件名、`{stamp}` 时间戳 yyyyMMddHHmm。
一个作业有多个导出块时，文件名是 `<outname>_<块 Name>`。

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

### image — 单张多切面图

```powershell
@{ Type='image'; Name='slice'; Expr='ewfd.normE'
   Plane='zx'; At='0'; Width='1200'; Height='900' }
```

`Plane` 取 `xy` `zx` `yz`；`At` 是切面沿法向的位置（m），一般放在器件中心；`SolNum` 选第几个解，默认 1。

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
