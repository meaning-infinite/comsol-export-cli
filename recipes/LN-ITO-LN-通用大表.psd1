@{
    # LN-ITO-LN 波长域通用大表：不改配方，模型里参数/波长窗口变了照样能导
    Task         = 'LN-ITO-LN'
    Study        = 'std1'
    NameTemplate = '{model}'

    Use = @(
        @{ Module = 'bigtable' }
    )
}
