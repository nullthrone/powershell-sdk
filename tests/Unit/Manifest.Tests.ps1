BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    $script:repositoryRoot = Get-McpRepositoryRoot
    $script:sourceManifestPath = Join-Path $script:repositoryRoot 'src' 'ModelContextProtocol.psd1'
    $script:builtManifestPath = Get-McpBuiltModuleManifest
    $script:sourceData = Import-PowerShellDataFile -Path $script:sourceManifestPath
    $script:builtData = Import-PowerShellDataFile -Path $script:builtManifestPath
    $script:builtManifest = Test-ModuleManifest -Path $script:builtManifestPath -ErrorAction Stop
}

Describe 'Module manifest' {
    It 'source manifest is a valid data file that declares the assembled root module' {
        $script:sourceData.RootModule | Should -Be 'ModelContextProtocol.psm1'
        $script:sourceData.ModuleVersion -as [version] | Should -Not -BeNullOrEmpty
        $script:sourceData.PowerShellVersion | Should -Be '7.4'
        @($script:sourceData.CompatiblePSEditions) | Should -Be @('Core')
    }

    It 'built manifest passes Test-ModuleManifest' {
        $script:builtManifest | Should -Not -BeNullOrEmpty
        $script:builtManifest.Name | Should -Be 'ModelContextProtocol'
    }

    It 'requires PowerShell 7.4 and the Core edition only' {
        $script:builtManifest.PowerShellVersion | Should -Be ([version] '7.4')
        @($script:builtManifest.CompatiblePSEditions) | Should -Be @('Core')
    }

    It 'keeps the fixed module GUID' {
        $script:builtManifest.Guid | Should -Be ([guid] '2eccfbe4-491e-4163-ad5d-86961f1c29fc')
        $script:sourceData.GUID | Should -Be $script:builtData.GUID
    }

    It 'has no runtime dependencies' {
        @($script:builtManifest.RequiredModules) | Should -BeNullOrEmpty
        @($script:builtManifest.RequiredAssemblies) | Should -BeNullOrEmpty
        @($script:builtManifest.NestedModules) | Should -BeNullOrEmpty
    }

    It 'uses ModelContextProtocol.psm1 as the root module' {
        $script:builtData.RootModule | Should -Be 'ModelContextProtocol.psm1'
        Join-Path (Split-Path -Path $script:builtManifestPath) $script:builtData.RootModule | Should -Exist
    }

    It 'exports explicitly, without wildcards (<_>)' -ForEach @('FunctionsToExport', 'CmdletsToExport', 'VariablesToExport', 'AliasesToExport') {
        $script:sourceData.ContainsKey($_) | Should -BeTrue
        $script:builtData.ContainsKey($_) | Should -BeTrue
        @($script:sourceData[$_]) | Should -Not -Contain '*'
        @($script:builtData[$_]) | Should -Not -Contain '*'
    }

    It 'exports one function per file in src/Public' {
        $publicFiles = @(Get-ChildItem -Path (Join-Path $script:repositoryRoot 'src' 'Public') -Filter '*.ps1' -Recurse | Select-Object -ExpandProperty BaseName | Sort-Object)
        @($script:builtData.FunctionsToExport | Sort-Object) | Should -Be $publicFiles
    }

    It 'declares the PowerShell Gallery metadata' {
        $psData = $script:builtData.PrivateData.PSData
        @($psData.Tags) | Should -Contain 'MCP'
        @($psData.Tags) | Should -Contain 'PSEdition_Core'
        $psData.ProjectUri | Should -Match '^https://github\.com/nullthrone/powershell-sdk'
        $psData.LicenseUri | Should -Match '^https://'
        $psData.RequireLicenseAcceptance | Should -BeFalse
    }

    It 'uses a 0.x version with an alphanumeric prerelease label until 1.0.0' {
        $script:builtManifest.Version | Should -BeLessThan ([version] '1.0.0')
        $script:builtData.PrivateData.PSData.Prerelease | Should -Match '^[A-Za-z0-9]+$'
    }

    It 'references type and format files that exist in the built module' {
        $moduleBase = Split-Path -Path $script:builtManifestPath
        foreach ($relative in @($script:builtData.TypesToProcess) + @($script:builtData.FormatsToProcess)) {
            Join-Path $moduleBase $relative | Should -Exist
        }
    }

    It 'ships the license and the about topic' {
        $moduleBase = Split-Path -Path $script:builtManifestPath
        Join-Path $moduleBase 'LICENSE' | Should -Exist
        Join-Path $moduleBase 'en-US' 'about_ModelContextProtocol.help.txt' | Should -Exist
    }
}
