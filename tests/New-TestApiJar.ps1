#requires -Version 5.1
param([Parameter(Mandatory)][string]$Path)
$ErrorActionPreference = 'Stop'
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($Path,'Create')
try {
    foreach ($name in 'util/ModelUtil','SolverSequence','SolutionInfo','Study','NumericalFeature','PropFeature') {
        [void]$archive.CreateEntry('com/comsol/model/' + $name + '.class')
    }
} finally { $archive.Dispose() }
