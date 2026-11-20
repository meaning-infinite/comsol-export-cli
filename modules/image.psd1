@{
    # 模块：单点场图 —— 只产出 1 张组合总表（三维 + xy + xz + zy 拼好），分面图拼完即删
    # 300 dpi（PNG 带 pHYs）；二维图按切面真实长宽比出图；带图题/色标/坐标轴，画域边界线，去 COMSOL 徽标与三轴图标
    Id       = 'image'
    Kind     = 'image'
    Title    = '单点场图（组合总表，300 dpi）'

    Defaults = @{
        Name   = 'field'          # 文件名后缀：<outname>_<Name>_all.png（唯一产物）
        Expr   = 'ewfd.Ex,ewfd.Ey'   # 分量场；逗号分隔则逐分量各占一块拼进同一张总表
        SolNum = '1'              # 取第几个解；单点场图 = 某个共振的解号
        Width  = 1200             # Height>0 时的二维画布宽度；像素上限 4096
        Height = 0                # 0 = 按切面长宽比自动算（此时 Width 不参与）
        Title  = ''                # 空 = 自动（平面名 + COMSOL 量名）
        Edges  = 'on'             # on = 画每个域的边界线（默认）
        Grid   = 'off'            # on = 三维画坐标框（栅格）；默认不画
    }

    Keys = @('Name', 'Expr', 'SolNum', 'Width', 'Height', 'Title', 'Edges', 'Grid', 'At', 'Plane')
}
