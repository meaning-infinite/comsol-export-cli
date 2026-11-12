# 导出配方（recipes）

一个 `.psd1` = 一种导出方案。只描述"跑哪个研究、导哪些量、文件叫什么"，不含逻辑，也不改模型里的参数。

## 字段

| 字段 | 必填 | 说明 |
|---|---|---|
| `Task` | 是 | 任务名，用于文件名 |
| `Study` | 是 | 研究标签，如 `std1` |
| `NameTemplate` | 是 | 文件名模板，见下表 |
| `Export` | 是 | 导出块数组，每块产出一个 CSV |

### NameTemplate 占位符

| 占位符 | 值 |
|---|---|
| `{task}` | `Task` 字段 |
| `{model}` | 模型文件名（不含 `.mph`） |
| `{stamp}` | 启动时间 `yyyyMMddHHmm` |

出现未知占位符会直接报错，不会静默生成怪名字。

### Export 块

| 字段 | 说明 |
|---|---|
| `Type` | 导出类型，目前支持 `global`（全局标量/表达式） |
| `Name` | 块名；多于一块时拼进文件名 `_<Name>` |
| `Expr` | 表达式数组 |
| `Cols` | 列名数组，数量必须与 `Expr` 一致 |

`global` 的取数口径：对研究里的每一个解逐个求值，按解的顺序写行。参数列会自动加在最前面（来自研究里的 Parametric 步）。

## 案例：现有配方

`ITO-LN-ITO.psd1`：

```powershell
@{
    Task         = 'ITO-LN-ITO'
    Study        = 'std1'
    NameTemplate = '{task}_{model}_{stamp}'
    Export       = @(
        @{
            Type = 'global'
            Name = 'TR'
            Expr = @('c_const/ewfd.freq', 'abs(ewfd.S21)^2', 'abs(ewfd.S11)^2')
            Cols = @('lambda_nm', 'T', 'R')
        }
    )
}
```

产出 `ITO-LN-ITO_测试模型_202611121709.csv`：

```
sim_xy   r     lambda_nm  T        R
513.000  210   866.000    0.882199 0.0691044
```

第一列波长用 `c_const/ewfd.freq` 直接得 nm；透射/反射用 S 参数平方，模型里没有现成的 `ewfd.T` / `ewfd.R`。

## 案例：只导吸收

```powershell
@{
    Task         = 'LN-abs'
    Study        = 'std1'
    NameTemplate = '{task}_{model}_{stamp}'
    Export       = @(
        @{ Type = 'global'; Name = 'abs'
           Expr = @('c_const/ewfd.freq', '1-abs(ewfd.S21)^2-abs(ewfd.S11)^2')
           Cols = @('lambda_nm', 'A') }
    )
}
```

## 案例：两个文件

```powershell
    Export = @(
        @{ Type = 'global'; Name = 'TR'; Expr = @('c_const/ewfd.freq','abs(ewfd.S21)^2','abs(ewfd.S11)^2'); Cols = @('lambda_nm','T','R') },
        @{ Type = 'global'; Name = 'E';  Expr = @('ewfd.normE'); Cols = @('normE') }
    )
```

产出 `..._TR.csv` 和 `..._E.csv`。

## 加新配方

复制一个 `.psd1` 改名，改 `Task`/`NameTemplate`/`Export` 即可，CLI 启动时自动列出 `recipes/` 下所有 `.psd1`。

注意：`.psd1` 必须存成 **UTF-8 带 BOM**，否则 PowerShell 5.1 会报"无法分析为 PowerShell 数据文件"。用记事本"另存为 → 编码选 UTF-8 带 BOM"。
