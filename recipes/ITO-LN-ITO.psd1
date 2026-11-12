@{
    # 配方：ITO - LN - ITO
    # 说明：驱动打开模型 -> 跑 study -> 按下面 Export 块导出。
    #      这里的世界只有模型；参数、波长窗口都在 .mph 里设好。
    Task        = 'ITO-LN-ITO'
    Study       = 'std1'
    NameTemplate = 'ITO-LN-ITO_{model}_{stamp}'

    Export = @(
        @{
            Type = 'spectrum'          # 透射/反射谱：CSV(lambda_nm,T,R) + 可选曲线图
            Name = 'spectrum'
            Plot = 'false'             # 'true' 时额外导出一张 T/R 曲线 PNG
        }
    )
}
