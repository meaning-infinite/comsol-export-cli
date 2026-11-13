@{
    # 宽谱波长域扫描（models\ITO_LN_ITO_202611131501_宽谱波长域扫描.mph）
    # 研究 std1：param 步当前【已关闭】（isActive=false），实际只跑全局参数 sim_xy=500、r=150；
    # 波长 range(400,1,1050) = 651 点 → 651 行。若重新勾上参数化扫描（sim_xy=1006,1012）则为 2×651 = 1302 行。
    Task         = 'ITO-LN-ITO'
    Study        = 'std1'
    NameTemplate = '{model}'        # 产物与模型文件同名，例如 ITO_LN_ITO_202611131501_宽谱波长域扫描_spectrum.csv

    Use = @(
        # 透射/反射谱：lambda_nm,T,R + T/R 曲线图
        @{ Module = 'spectrum'; Name = 'spectrum'; Plot = 'true' }

        # 谱数据表：额外给出吸收 A = 1 - T - R（按组参数分列在最左）
        @{ Module = 'table'; Name = 'data'
           Expr = @('c_const/ewfd.freq', 'abs(ewfd.S21)^2', 'abs(ewfd.S11)^2',
                    '1-abs(ewfd.S21)^2-abs(ewfd.S11)^2')
           Cols = @('lambda_nm', 'T', 'R', 'A') }
    )
}
