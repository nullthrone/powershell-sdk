BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    $script:manifestPath = Get-McpBuiltModuleManifest
    $script:manifestData = Import-PowerShellDataFile -Path $script:manifestPath
    $script:accelerators = [psobject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
    $script:engineTypeNames = @('McpEra', 'McpLoggingLevel')
    Remove-Module -Name ModelContextProtocol -Force -ErrorAction SilentlyContinue
}

AfterAll {
    Remove-Module -Name ModelContextProtocol -Force -ErrorAction SilentlyContinue
}

Describe 'Importing the module' {
    It 'emits nothing on any stream' {
        $globalsBefore = @(Get-Variable -Scope Global | Select-Object -ExpandProperty Name)
        $streams = @(Import-Module -Name $script:manifestPath -Force *>&1)
        $streams | Should -BeNullOrEmpty
        Get-Module -Name ModelContextProtocol | Should -Not -BeNullOrEmpty
        $globalsAfter = @(Get-Variable -Scope Global | Select-Object -ExpandProperty Name)
        @(Compare-Object -ReferenceObject $globalsBefore -DifferenceObject $globalsAfter) | Should -BeNullOrEmpty
    }

    It 'exports exactly the functions listed in the manifest' {
        $module = Get-Module -Name ModelContextProtocol
        $expected = @($script:manifestData.FunctionsToExport | Sort-Object)
        $actual = @($module.ExportedFunctions.Keys | Sort-Object)
        $actual.Count | Should -Be $expected.Count
        if ($expected.Count -gt 0) { $actual | Should -Be $expected }
        $module.ExportedCmdlets.Count | Should -Be 0
        $module.ExportedAliases.Count | Should -Be 0
        $module.ExportedVariables.Count | Should -Be 0
    }

    It 'exports only functions with approved verbs and the Mcp noun prefix' {
        $approvedVerbs = @(Get-Verb | Select-Object -ExpandProperty Verb)
        foreach ($name in (Get-Module -Name ModelContextProtocol).ExportedFunctions.Keys) {
            $verb, $noun = $name.Split('-', 2)
            $verb | Should -BeIn $approvedVerbs
            $noun | Should -Match '^Mcp[A-Z]'
        }
    }

    It 'registers the type accelerator <_>' -ForEach @('McpEra', 'McpLoggingLevel') {
        $script:accelerators::Get.ContainsKey($_) | Should -BeTrue
        $type = $script:accelerators::Get[$_]
        $type.IsEnum | Should -BeTrue
        $type.Name | Should -Be $_
    }

    It 'makes engine types usable by name from outside the module' {
        [string] [McpEra]::Legacy | Should -Be 'Legacy'
        [int] [McpLoggingLevel]::Emergency | Should -Be 7
    }

    It 'survives Import-Module -Force twice and keeps the accelerators pointing at the live types' {
        { Import-Module -Name $script:manifestPath -Force -ErrorAction Stop } | Should -Not -Throw
        { Import-Module -Name $script:manifestPath -Force -ErrorAction Stop } | Should -Not -Throw
        foreach ($name in $script:engineTypeNames) {
            $script:accelerators::Get.ContainsKey($name) | Should -BeTrue
            $script:accelerators::Get[$name].Module.Name | Should -Not -BeNullOrEmpty
        }
    }

    It 'removes its type accelerators on Remove-Module' {
        Remove-Module -Name ModelContextProtocol -Force
        foreach ($name in $script:engineTypeNames) {
            $script:accelerators::Get.ContainsKey($name) | Should -BeFalse
        }
    }
}
