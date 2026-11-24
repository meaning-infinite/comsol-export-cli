@{
    Files = @('run.bat','cli.ps1','update.bat','update.ps1','pack.ps1','release.psd1','README.md','AGENTS.md')
    Directories = @('driver','modules','recipes','docs','assets')
    Required = @('driver/ExportDriver.java','driver/ExportDriver.class','driver/ExportDriver$Handler.class',
        'driver/ExportDriver$Job.class','driver/ExportDriver$SolUse.class','driver/ExportDriver$CsvStream.class',
        'driver/ExportDriver$SliceSink.class','driver/ExportDriver$JobFailure.class',
        'modules/table.psd1','modules/spectrum.psd1','modules/bigtable.psd1','modules/image.psd1',
        'modules/integral.psd1','modules/slice2d.psd1','modules/modes.psd1','docs/API.md',
        'docs/COMSOL-API.md','recipes/README.md','recipes/ITO-LN-ITO.psd1','recipes/ITO-LN-ITO-宽谱.psd1','assets/banner.png','assets/screenshot.jpg')
}
