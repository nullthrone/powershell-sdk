BeforeDiscovery {
    $script:expectedVersion = $env:MCP_EXPECTED_PWSH_VERSION
}

Describe 'PowerShell version matrix' -Tag 'Compat', 'VersionMatrix' {
    It 'runs on PowerShell 7.4 or later, Core edition' {
        $PSVersionTable.PSVersion | Should -BeGreaterOrEqual ([version] '7.4')
        $PSVersionTable.PSEdition | Should -Be 'Core'
    }

    It 'runs on a supported minor version (7.4, 7.5, 7.6)' {
        '{0}.{1}' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor | Should -BeIn @('7.4', '7.5', '7.6')
    }

    It 'runs on the exact version the pipeline pinned (MCP_EXPECTED_PWSH_VERSION)' -Skip:(-not $script:expectedVersion) {
        $PSVersionTable.PSVersion.ToString() | Should -Be $env:MCP_EXPECTED_PWSH_VERSION
    }

    It 'ships the in-box assemblies the SDK relies on' {
        [System.Text.Json.JsonDocument].Assembly.GetName().Name | Should -Be 'System.Text.Json'
        Join-Path $PSHOME 'JsonSchema.Net.dll' | Should -Exist
    }

    It 'has PSResourceGet in-box for packaging' {
        Get-Module -ListAvailable -Name Microsoft.PowerShell.PSResourceGet | Should -Not -BeNullOrEmpty
    }
}
