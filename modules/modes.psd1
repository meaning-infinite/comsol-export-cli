@{
    # 模块：特征频率后处理（每个模态一行数值）
    # Expr 里可直接写特征频率相关的量，例如 ewfd.freq、abs(ewfd.S11)^2
    Id       = 'modes'
    Kind     = 'modes'
    Title    = '特征频率数值'
    Defaults = @{
        Expr     = @('ewfd.freq')
        Cols     = @('freq')
        MaxModes = 50
    }
    Keys     = @('Expr', 'Cols', 'MaxModes', 'Name')
}
