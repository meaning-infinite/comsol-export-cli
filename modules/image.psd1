@{
    # 模块：单点场图（一次出 4 张 —— 三维默认视角 1 张 + 二维正投影 3 张）
    # 300 dpi；二维图按切面真实长宽比出图，xz/zy 是竖图
    Id       = 'image'
    Kind     = 'image'
    Title    = '单点场图（三维 + xy/xz/zy 三张二维，300 dpi）'

    Defaults = @{
        Name   = 'field'          # 文件名后缀：<outname>_<Name>_3d/_xy/_xz/_zy.png
        Expr   = 'ewfd.normE'
        SolNum = '1'              # 取第几个解；单点场图 = 某个共振的解号
        Width  = 1200             # 画布长边像素；宽高上限都是 4096
        Height = 0                # 0 = 二维按切面长宽比自动算
        Title  = ''               # 空 = 自动
        Edges  = 'off'
    }

    Keys = @('Name', 'Expr', 'SolNum', 'Width', 'Height', 'Title', 'Edges', 'At', 'Plane')
}
