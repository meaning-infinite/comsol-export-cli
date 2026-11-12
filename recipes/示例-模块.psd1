@{
    # 示例：只用预制模块。字段含义见 recipes/README.md，模块清单 `run.bat -Modules`
    Task         = '示例-模块'
    Study        = 'std1'
    NameTemplate = 'demo_{model}_{stamp}'

    Use = @(
        # ① 数据表：模型参数 + 指定表达式，每个解一行
        @{ Module = 'table'; Name = 'TR' }

        # ② 透射/反射谱 CSV，Plot='true' 再出一张曲线图
        @{ Module = 'spectrum'; Name = 'spectrum'; Plot = 'true' }

        # ③ 三个平面的二维正投影图（俯视 / 侧视 / 正视）
        @{ Module = 'slice2d'; Name = 'field'; Planes = @('xy', 'zx', 'yz') }

        # ④ 面积分（Ents='all' 表示全部边界；也可写 '3,4,17'）
        @{ Module = 'integral'; Name = 'flux'; Dim = 'surface'; Ents = 'all'
           Expr = @('ewfd.normE'); Cols = @('E') }

        # ⑤ 特征频率数值表（每个模态一行）
        @{ Module = 'modes'; Name = 'modes'; Expr = @('ewfd.freq'); Cols = @('freq') }
    )
}
