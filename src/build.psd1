# ModuleBuilder settings (Build-Module reads this file; relative paths resolve against this directory).
# The build task in ModelContextProtocol.build.ps1 passes -OutputDirectory and -SemVer explicitly.
@{
    ModuleManifest           = 'ModelContextProtocol.psd1'
    OutputDirectory          = '../output'
    VersionedOutputDirectory = $true
    SourceDirectories        = @('Enums', 'Classes', 'Private', 'Public')
    PublicFilter             = 'Public/*.ps1'
    CopyPaths                = @('en-US', 'Types', 'Formats')
    Suffix                   = 'Suffix.ps1'
    Encoding                 = 'UTF8NoBom'
}
