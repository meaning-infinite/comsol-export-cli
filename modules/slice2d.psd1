@{
    # 模块：多切面（正投影二维视图）
    # 每个平面单独出图，图里是二维场分布（不是三维透视）
    Id       = 'slice2d'
    Kind     = 'slice2d'
    Title    = '多切面（二维视图）'
    Defaults = @{
        Expr   = 'ewfd.normE'
        Planes = @('xy', 'zx', 'yz')
        At     = 'auto'
        Width  = 1200
        Height = 900
    }
    Keys     = @('Expr', 'Planes', 'At', 'Width', 'Height', 'Title', 'Name')
}
