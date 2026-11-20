@{
    # 模块：单点场图 —— 三维默认视角 1 张 + 二维正投影 2 张（xy 单独，xz/zy 左右拼成一张）
    # 300 dpi；二维图按切面真实长宽比出图；带图题/色标/坐标轴，画域边界线，去 COMSOL 徽标与三轴图标
    Id       = 'image'
    Kind     = 'image'
    Title    = '单点场图（三维 + xy + xz/zy 合并，300 dpi）'

    Defaults = @{
        Name   = 'field'          # 文件名后缀：<outname>_<Name>_3d.png / _xy.png / _xz_zy.png
        Expr   = 'ewfd.Ex,ewfd.Ey'   # 分量场；逗号分隔则逐分量各出一套图（文件名带 _Ex/_Ey）
        SolNum = '1'              # 取第几个解；单点场图 = 某个共振的解号
        Width  = 1200             # 画布长边像素；宽高上限都是 4096
        Height = 0                # 0 = 按切面长宽比自动算
        Title  = ''                # 空 = 自动（平面名 + COMSOL 量名）
        Edges  = 'on'             # on = 画每个域的边界线（默认）
        Grid   = 'off'            # on = 三维画坐标框（栅格）；默认不画
    }

    Keys = @('Name', 'Expr', 'SolNum', 'Width', 'Height', 'Title', 'Edges', 'Grid', 'At', 'Plane')
}
