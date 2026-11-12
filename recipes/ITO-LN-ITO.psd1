# ITO-LN-ITO 任务的导出配方
# 只描述“算哪个研究、导哪些量、文件叫什么”，不含逻辑，也不碰模型里的参数。
# 参数、波长窗口、扫描点全部在 .mph 里设好；本文件改了也不会改模型。
@{
    Task         = 'ITO-LN-ITO'
    Study        = 'std1'
    NameTemplate = '{task}_{model}_{stamp}'

    # 导出块：Type 是分派键，加一块就多导一份数据
    Export       = @(
        @{
            Type = 'global'
            Name = 'TR'
            Expr = @('c_const/ewfd.freq', 'abs(ewfd.S21)^2', 'abs(ewfd.S11)^2')
            Cols = @('lambda_nm', 'T', 'R')
        }
    )
}
