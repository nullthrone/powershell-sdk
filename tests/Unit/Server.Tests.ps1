[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force
}

Describe 'New-McpServer' {
    It 'creates a server object with defaults' {
        $server = New-McpServer -Name 'demo' -Version '0.1.0'
        $server.PSObject.TypeNames | Should -Contain 'Mcp.Server'
        $server.SupportedVersions | Should -Be @('2026-07-28')
        $server.Tools.Count | Should -Be 0
        $server.Options.MaxConcurrency | Should -BeGreaterOrEqual 1
        $server.Options.PageSize | Should -Be 100
        $server.Options.DefaultCacheScope | Should -Be 'public'
        $server.Options.IncludeServerInfo | Should -BeTrue
        $server.Options.LogLevel | Should -Be ([McpLoggingLevel]::Warning)
    }

    It 'rejects protocol versions this milestone does not support' {
        { New-McpServer -Name 'demo' -Version '1' -SupportedVersions '2025-11-25' } | Should -Throw -ExpectedMessage '*not supported*'
    }

    It 'sets the default server with -SetDefault' {
        $server = New-McpServer -Name 'default' -Version '1' -SetDefault
        (Invoke-McpInModule { Resolve-McpServer -Server $null }).Name | Should -Be 'default'
        $server.Name | Should -Be 'default'
    }
}

Describe 'server/discover' {
    It 'builds a DiscoverResult that matches the specification schema' {
        $server = New-McpServer -Name 'demo' -Version '0.1.0' -Title 'Demo' -Instructions 'Use it.' -WebsiteUrl 'https://example.com' -DefaultTtlMs 5000 -DefaultCacheScope private
        $result = Invoke-McpInModule { param($s) Get-McpDiscoverResult -Server $s } $server
        @($result.Keys) | Should -Be @('resultType', 'supportedVersions', 'capabilities', 'instructions', 'ttlMs', 'cacheScope', '_meta')
        $result['resultType'] | Should -Be 'complete'
        $result['supportedVersions'] | Should -Be @('2026-07-28')
        $result['capabilities']['tools']['listChanged'] | Should -BeFalse
        $result['ttlMs'] | Should -Be 5000
        $result['cacheScope'] | Should -Be 'private'
        $result['_meta']['io.modelcontextprotocol/serverInfo']['name'] | Should -Be 'demo'
        $result['_meta']['io.modelcontextprotocol/serverInfo']['title'] | Should -Be 'Demo'
        $result['_meta']['io.modelcontextprotocol/serverInfo']['websiteUrl'] | Should -Be 'https://example.com'
        (Test-McpSpecShape -Definition 'DiscoverResult' -Instance $result).IsValid | Should -BeTrue
    }

    It 'omits serverInfo with -NoServerInfo' {
        $server = New-McpServer -Name 'demo' -Version '0.1.0' -NoServerInfo
        $result = Invoke-McpInModule { param($s) Get-McpDiscoverResult -Server $s } $server
        $result.Contains('_meta') | Should -BeFalse
        (Test-McpSpecShape -Definition 'DiscoverResult' -Instance $result).IsValid | Should -BeTrue
    }
}

Describe 'tools/list' {
    BeforeAll {
        $script:server = New-McpServer -Name 'demo' -Version '0.1.0' -PageSize 2
        foreach ($name in 'a', 'b', 'c', 'd', 'e') {
            Register-McpTool -Name $name -ScriptBlock { 1 } -Server $script:server
        }
    }

    It 'pages deterministically with opaque cursors and matches the specification schema' {
        $first = Invoke-McpInModule { param($s) Get-McpToolListResult -Server $s -Cursor $null } $script:server
        @($first['tools'] | ForEach-Object { $_['name'] }) | Should -Be @('a', 'b')
        $first['nextCursor'] | Should -Not -BeNullOrEmpty
        $first['ttlMs'] | Should -Be 0
        $first['cacheScope'] | Should -Be 'public'
        (Test-McpSpecShape -Definition 'ListToolsResult' -Instance $first).IsValid | Should -BeTrue
        $second = Invoke-McpInModule { param($s, $c) Get-McpToolListResult -Server $s -Cursor $c } $script:server $first['nextCursor']
        @($second['tools'] | ForEach-Object { $_['name'] }) | Should -Be @('c', 'd')
        $third = Invoke-McpInModule { param($s, $c) Get-McpToolListResult -Server $s -Cursor $c } $script:server $second['nextCursor']
        @($third['tools'] | ForEach-Object { $_['name'] }) | Should -Be @('e')
        $third.Contains('nextCursor') | Should -BeFalse
    }

    It 'rejects invalid cursors with -32602' {
        $exception = $null
        try { Invoke-McpInModule { param($s) Get-McpToolListResult -Server $s -Cursor 'nonsense' } $script:server } catch { $exception = $_.Exception }
        $exception.Code | Should -Be -32602
        try { Invoke-McpInModule { param($s) Get-McpToolListResult -Server $s -Cursor 12 } $script:server } catch { $exception = $_.Exception }
        $exception.Code | Should -Be -32602
    }

    It 'returns everything in one page when the page size is large enough' {
        $server = New-McpServer -Name 'demo' -Version '0.1.0'
        Register-McpTool -Name 'only' -ScriptBlock { 1 } -Server $server
        $result = Invoke-McpInModule { param($s) Get-McpToolListResult -Server $s -Cursor $null } $server
        @($result['tools']).Count | Should -Be 1
        $result.Contains('nextCursor') | Should -BeFalse
    }
}
