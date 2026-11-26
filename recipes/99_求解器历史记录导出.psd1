@{
    Task         = 'solver-history'
    NameTemplate = '{model}'
    SolScope     = 'all'
    Use          = @(@{ Module = 'solverlog' })
}
