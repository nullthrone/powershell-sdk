#
# Module manifest for the ModelContextProtocol module.
#
# The build (ModuleBuilder, see build.psd1) copies this manifest to output/ModelContextProtocol/<version>/ and
# regenerates FunctionsToExport from the files in Public/. Keep the exports explicit: the PowerShell Gallery
# rejects wildcard exports and the manifest tests assert their absence.
#
@{
    RootModule           = 'ModelContextProtocol.psm1'
    ModuleVersion        = '0.1.0'
    CompatiblePSEditions = @('Core')
    GUID                 = '2eccfbe4-491e-4163-ad5d-86961f1c29fc'
    Author               = 'nullthrone'
    CompanyName          = 'nullthrone'
    Copyright            = '(c) 2026 nullthrone. Licensed under the MIT License.'
    Description          = 'PowerShell SDK for the Model Context Protocol (MCP): build and consume MCP servers and clients over stdio and Streamable HTTP. Targets specification revision 2026-07-28 with dual-era support for 2025-11-25 and 2025-06-18.'
    PowerShellVersion    = '7.4'
    RequiredModules      = @()
    RequiredAssemblies   = @()
    TypesToProcess       = @('Types/ModelContextProtocol.Types.ps1xml')
    FormatsToProcess     = @('Formats/ModelContextProtocol.Format.ps1xml')
    NestedModules        = @()
    FunctionsToExport    = @()
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags                       = @('MCP', 'ModelContextProtocol', 'JSON-RPC', 'AI', 'LLM', 'Agent', 'PSEdition_Core', 'Windows', 'Linux', 'MacOS')
            LicenseUri                 = 'https://github.com/nullthrone/powershell-sdk/blob/main/LICENSE'
            ProjectUri                 = 'https://github.com/nullthrone/powershell-sdk'
            ReleaseNotes               = 'https://github.com/nullthrone/powershell-sdk/blob/main/CHANGELOG.md'
            Prerelease                 = 'preview1'
            RequireLicenseAcceptance   = $false
            ExternalModuleDependencies = @()
        }
    }
}
