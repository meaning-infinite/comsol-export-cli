@{
    Id    = 'bigtable'
    Kind  = 'bigtable'
    Title = '通用原始大表（全局参数 + 谱线 + 各域吸收）'

    Defaults = @{
        Name       = 'bigtable'
        Params     = 'all'        # all / none / 逗号分隔的参数名
        AbsDomains = 'auto'       # auto = 材料名含 ITO 的所有域；也可写 '3,6,9' / none
        AbsExpr    = 'ewfd.Qh'    # 体积分被积函数
    }

    Keys = @('Name', 'Params', 'AbsDomains', 'AbsExpr', 'Allownan', 'Component', 'Material', 'Selection')
}
