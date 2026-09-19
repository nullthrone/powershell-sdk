BeforeDiscovery {
    $script:revisions = @('2026-07-28', '2025-11-25', '2025-06-18')
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module -Name (Get-McpBuiltModuleManifest) -Force
    $script:accelerators = [psobject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
}

AfterAll {
    Remove-Module -Name ModelContextProtocol -Force -ErrorAction SilentlyContinue
}

Describe 'McpLoggingLevel' {
    It 'has the members of the LoggingLevel definition in schema <_>' -ForEach $script:revisions {
        $definitions = Get-McpSpecDefinition -Revision $_
        $definitions.ContainsKey('LoggingLevel') | Should -BeTrue
        $expected = @($definitions['LoggingLevel']['enum'] | Sort-Object)
        $type = $script:accelerators::Get['McpLoggingLevel']
        $actual = @([enum]::GetNames($type) | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
        $actual | Should -Be $expected
    }

    It 'orders the levels by RFC 5424 severity, debug lowest' {
        [int] [McpLoggingLevel]::Debug | Should -Be 0
        [McpLoggingLevel]::Emergency | Should -BeGreaterThan ([McpLoggingLevel]::Alert)
        [McpLoggingLevel]::Error | Should -BeGreaterThan ([McpLoggingLevel]::Warning)
    }
}

Describe 'McpEra' {
    It 'distinguishes the modern and the legacy lifecycle' {
        @([enum]::GetNames([McpEra])) | Should -Be @('Modern', 'Legacy')
    }
}
