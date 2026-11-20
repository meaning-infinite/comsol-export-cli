@{
    # 20261119 候选共振细扫 —— 逐共振点各出一组场图
    # 共振波长取自 results/20261119_候选共振细扫/说明.md「逐窗结果」的 λ谷（T00 最小点）
    # SolNum = 该点在解序列里的序号（1 起，按 363 点导出表的行序；解序不变就能对上）
    # 每组 4 张：<outname>_<Name>_3d/_xy/_xz/_zy.png，300 dpi
    Task         = 'ITO-LN-ITO'
    Study        = 'std1'
    NameTemplate = '{model}'

    Use = @(
        @{ Module = 'image'; Name = 'res739'; SolNum = '88' }    # 739.45 nm（Fano 谷底，最深）
        @{ Module = 'image'; Name = 'res775'; SolNum = '353' }   # 775.40 nm
        @{ Module = 'image'; Name = 'res787'; SolNum = '13' }    # 787.40 nm
        @{ Module = 'image'; Name = 'res827'; SolNum = '166' }   # 827.10 nm
        @{ Module = 'image'; Name = 'res868'; SolNum = '227' }   # 867.60 nm
        @{ Module = 'image'; Name = 'res913'; SolNum = '279' }   # 913.20 nm（孔壁吸收主导）
        @{ Module = 'image'; Name = 'res979'; SolNum = '323' }   # 979.00 nm（Q 最高、耦合最弱）
    )
}
