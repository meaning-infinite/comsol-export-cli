@{
    # 示例配方：演示全部导出类型。把常用字段抄到自己的配方里即可。
    Task         = '示例-全导出'
    Study        = 'std1'
    NameTemplate = 'demo_{model}_{stamp}'

    Export = @(
        # ① 表：任意表达式的 CSV，扫描变量自动放最前两列
        @{
            Type = 'global'
            Name = 'TR'
            Expr = @('c_const/ewfd.freq','abs(ewfd.S21)^2','abs(ewfd.S11)^2')
            Cols = @('lambda_nm','T','R')
        }

        # ② 谱：等价于上面的表，但列名/表达式不用写；Plot='true' 再出一张曲线图
        @{
            Type  = 'spectrum'
            Name  = 'spectrum'
            Plot  = 'true'
        }

        # ③ 单张多切面图：一个平面，指定位置（单位 m）
        @{
            Type   = 'image'
            Name   = 'slice'
            Expr   = 'ewfd.normE'
            Plane  = 'zx'      # xy | zx | yz
            At     = '0'       # 切面沿法向的位置，单位 m
            Width  = '1200'
            Height = '900'
        }

        # ④ 特征频率：每个模态导出 3 张切面图 <outname>_m<k>_<plane>.png
        @{
            Type     = 'eigenslice'
            Name     = 'eigen'
            Expr     = 'ewfd.normE'
            Planes   = @('xy','zx','yz')
            At       = '0'
            MaxModes = '20'    # 最多导多少个模态
            Width    = '1000'
            Height   = '800'
        }
    )
}
