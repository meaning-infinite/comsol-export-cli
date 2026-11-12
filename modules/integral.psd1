@{
    # 模块：线积分 / 面积分（数值 CSV）
    # Ents：'all' 或边界/边编号，如 '3,4,17'；Dim：surface 或 line
    Id       = 'integral'
    Kind     = 'integral'
    Title    = '线积分/面积分'
    Defaults = @{
        Dim  = 'surface'
        Ents = 'all'
        Expr = @('ewfd.normE')
        Cols = @('E')
    }
    Keys     = @('Dim', 'Ents', 'Expr', 'Cols', 'Name')
}
