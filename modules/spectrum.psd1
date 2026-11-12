@{
    # 模块：透射/反射谱
    # 产物：CSV(lambda_nm,T,R)；Plot='true' 时额外一张 T/R 曲线图
    Id       = 'spectrum'
    Kind     = 'spectrum'
    Title    = '透射/反射谱'
    Defaults = @{ Plot = 'false' }
    Keys     = @('Plot', 'Name')
}
