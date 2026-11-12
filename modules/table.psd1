@{
    # 模块：数据导出（任意表达式成表，每个解一行）
    # 扫描参数会自动放在最前面
    Id       = 'table'
    Kind     = 'global'
    Title    = '数据导出（全局量）'
    Defaults = @{
        Expr = @('c_const/ewfd.freq', 'abs(ewfd.S21)^2', 'abs(ewfd.S11)^2')
        Cols = @('lambda_nm', 'T', 'R')
    }
    Keys     = @('Expr', 'Cols', 'Name')
}
