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

        # ③ 场图：一次出 4 张 —— 三维默认视角 1 张 + xy/xz/zy 二维各 1 张
        @{
            Type    = 'image'
            Name    = 'field'
            Expr    = 'ewfd.normE'
            Width   = '1200'   # 长边像素；二维图按切面真实比例自动定尺寸
            Edges   = 'off'    # 是否画网格边
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
