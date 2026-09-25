[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force
}

Describe 'Era selection' {
    BeforeAll {
        $script:modernMeta = [ordered]@{ _meta = [ordered]@{ 'io.modelcontextprotocol/protocolVersion' = '2026-07-28'; 'io.modelcontextprotocol/clientCapabilities' = [ordered]@{} } }
    }

    It 'chooses <Expected> for <Method> (session: <HasSession>, line session: <HasLineSession>, HTTP: <Http>, modern _meta: <Modern>)' -ForEach @(
        @{ Method = 'initialize'; HasSession = $false; HasLineSession = $false; Http = $false; Modern = $false; Expected = 'Legacy' }
        @{ Method = 'initialize'; HasSession = $false; HasLineSession = $false; Http = $true; Modern = $true; Expected = 'Legacy' }
        @{ Method = 'tools/list'; HasSession = $false; HasLineSession = $false; Http = $false; Modern = $true; Expected = 'Modern' }
        @{ Method = 'tools/list'; HasSession = $false; HasLineSession = $false; Http = $false; Modern = $false; Expected = 'Modern' }
        @{ Method = 'tools/list'; HasSession = $false; HasLineSession = $true; Http = $false; Modern = $false; Expected = 'Legacy' }
        @{ Method = 'tools/list'; HasSession = $false; HasLineSession = $true; Http = $false; Modern = $true; Expected = 'Modern' }
        @{ Method = 'tools/list'; HasSession = $true; HasLineSession = $false; Http = $true; Modern = $false; Expected = 'Legacy' }
        @{ Method = 'tools/list'; HasSession = $false; HasLineSession = $false; Http = $true; Modern = $false; Expected = 'Modern' }
        @{ Method = 'ping'; HasSession = $false; HasLineSession = $false; Http = $true; Modern = $true; Expected = 'Modern' }
    ) {
        $state = @{ LineSession = if ($HasLineSession) { @{ KeyPrefix = 'legacy|' } } else { $null } }
        $parameters = @{
            s = $state
            m = $Method
            p = if ($Modern) { $script:modernMeta } else { [ordered]@{} }
            x = if ($HasSession) { @{ KeyPrefix = 'legacy:1|' } } else { $null }
            h = $Http
        }
        Invoke-McpInModule { param($s, $m, $p, $x, $h) Get-McpMessageEra -State $s -Method $m -Params $p -Session $x -Http:$h } -Parameters $parameters | Should -Be $Expected
    }

    It 'splits the supported versions by era and accepts 2025-03-26 with any legacy revision' {
        $dual = New-McpServer -Name 'd' -Version '1'
        Invoke-McpInModule { param($s) Get-McpServerVersion -Server $s -Era Modern } $dual | Should -Be @('2026-07-28')
        Invoke-McpInModule { param($s) Get-McpServerVersion -Server $s -Era Legacy } $dual | Should -Be @('2025-11-25', '2025-06-18')
        Invoke-McpInModule { param($s) Get-McpServerVersion -Server $s -Era Legacy -Accepted } $dual | Should -Be @('2025-11-25', '2025-06-18', '2025-03-26')
        $modern = New-McpServer -Name 'm' -Version '1' -SupportedVersions '2026-07-28'
        @(Invoke-McpInModule { param($s) Get-McpServerVersion -Server $s -Era Legacy -Accepted } $modern).Count | Should -Be 0
    }
}

Describe 'Era-aware serialization' {
    It 'removes the modern-only members from legacy results' {
        $result = [ordered]@{ resultType = 'complete'; tools = @(); ttlMs = 0; cacheScope = 'public'; nextCursor = 'x'; _meta = [ordered]@{ 'io.modelcontextprotocol/serverInfo' = @{ name = 's' }; 'example.com/keep' = 1 } }
        $converted = Invoke-McpInModule { param($r) ConvertTo-McpLegacyResult -Result $r } -Parameters @{ r = $result }
        @($converted.Keys) | Should -Be @('tools', 'nextCursor', '_meta')
        @($converted['_meta'].Keys) | Should -Be @('example.com/keep')
        $bare = Invoke-McpInModule { param($r) ConvertTo-McpLegacyResult -Result $r } -Parameters @{ r = [ordered]@{ resultType = 'complete'; _meta = [ordered]@{ 'io.modelcontextprotocol/serverInfo' = @{} } } }
        $bare.Count | Should -Be 0
    }

    It 'leaves modern messages unchanged' {
        $message = [ordered]@{ jsonrpc = '2.0'; id = 1; result = [ordered]@{ resultType = 'complete' } }
        (Invoke-McpInModule { param($m) ConvertTo-McpEraMessage -Message $m -Era Modern } -Parameters @{ m = $message })['result']['resultType'] | Should -Be 'complete'
    }

    It 'maps errors: unknown resources to -32002 and the modern codes to -32600' {
        $notFound = Invoke-McpInModule { ConvertTo-McpErrorObject -Exception (New-McpResourceNotFoundException -Uri 'test://x') -Era Legacy }
        $notFound['code'] | Should -Be -32002
        $notFound['data']['uri'] | Should -Be 'test://x'
        (Invoke-McpInModule { ConvertTo-McpErrorObject -Exception (New-McpResourceNotFoundException -Uri 'test://x') })['code'] | Should -Be -32602
        foreach ($code in -32020, -32021, -32022) {
            (Invoke-McpInModule { param($c) ConvertTo-McpErrorObject -Exception ([McpProtocolException]::new($c, 'm')) -Era Legacy } $code)['code'] | Should -Be -32600
        }
        (Invoke-McpInModule { ConvertTo-McpErrorObject -Exception ([McpProtocolException]::new(-32601, 'm')) -Era Legacy })['code'] | Should -Be -32601
    }
}

Describe 'Legacy sessions' {
    BeforeAll {
        $script:server = New-McpServer -Name 's' -Version '1'
        Register-McpResource -Uri 'test://doc' -Name 'doc' -Content 'x' -Server $script:server
    }

    It 'validates initialize and answers a modern-only server with -32022' {
        $params = [ordered]@{ protocolVersion = '2025-06-18'; capabilities = [ordered]@{ sampling = [ordered]@{} }; clientInfo = [ordered]@{ name = 'c'; version = '1' } }
        $session = Invoke-McpInModule { param($s, $p) Invoke-McpLegacyInitialize -Server $s -Params $p -SessionId 'abc' } -Parameters @{ s = $script:server; p = $params }
        $session.ProtocolVersion | Should -Be '2025-06-18'
        $session.KeyPrefix | Should -Be 'legacy:abc|'
        $session.ClientCapabilities.Contains('sampling') | Should -BeTrue
        foreach ($bad in @([ordered]@{ capabilities = @{}; clientInfo = @{ name = 'c'; version = '1' } }, [ordered]@{ protocolVersion = '2025-11-25'; clientInfo = @{ name = 'c'; version = '1' } }, [ordered]@{ protocolVersion = '2025-11-25'; capabilities = @{}; clientInfo = @{ name = 'c' } })) {
            { Invoke-McpInModule { param($s, $p) Invoke-McpLegacyInitialize -Server $s -Params $p } -Parameters @{ s = $script:server; p = $bad } } | Should -Throw -ExceptionType ([McpProtocolException])
        }
        $modernOnly = New-McpServer -Name 'm' -Version '1' -SupportedVersions '2026-07-28'
        try {
            Invoke-McpInModule { param($s, $p) Invoke-McpLegacyInitialize -Server $s -Params $p } -Parameters @{ s = $modernOnly; p = $params }
            throw 'expected an exception'
        } catch [McpProtocolException] {
            $_.Exception.Code | Should -Be -32022
            $_.Exception.Data['supported'] | Should -Be @('2026-07-28')
            $_.Exception.Data['requested'] | Should -Be '2025-06-18'
        }
    }

    It 'keeps the log level and the resource subscriptions of a session' {
        $session = Invoke-McpInModule { New-McpLegacySession -ProtocolVersion '2025-11-25' }
        $session.KeyPrefix | Should -Be 'legacy|'
        $null = Invoke-McpInModule { param($s, $x) Invoke-McpLegacyMethod -Server $s -Session $x -Method 'logging/setLevel' -Params ([ordered]@{ level = 'warning' }) } $script:server $session
        $session.LogLevel | Should -Be 'warning'
        (Invoke-McpInModule { param($x) Get-McpLegacyRequestMeta -Session $x -Params ([ordered]@{ _meta = [ordered]@{ progressToken = 't' } }) } $session).ProgressToken | Should -Be 't'
        $null = Invoke-McpInModule { param($s, $x) Invoke-McpLegacyMethod -Server $s -Session $x -Method 'resources/subscribe' -Params ([ordered]@{ uri = 'test://doc' }) } $script:server $session
        $session.Initialized = $true
        Invoke-McpInModule { param($x) Test-McpLegacyNotificationMatch -Session $x -Method 'notifications/resources/updated' -Params ([ordered]@{ uri = 'test://doc/a' }) } $session | Should -BeTrue
        Invoke-McpInModule { param($x) Test-McpLegacyNotificationMatch -Session $x -Method 'notifications/resources/updated' -Params ([ordered]@{ uri = 'test://docx' }) } $session | Should -BeFalse
        Invoke-McpInModule { param($x) Test-McpLegacyNotificationMatch -Session $x -Method 'notifications/prompts/list_changed' -Params $null } $session | Should -BeTrue
        $null = Invoke-McpInModule { param($s, $x) Invoke-McpLegacyMethod -Server $s -Session $x -Method 'resources/unsubscribe' -Params ([ordered]@{ uri = 'test://doc' }) } $script:server $session
        Invoke-McpInModule { param($x) Test-McpLegacyNotificationMatch -Session $x -Method 'notifications/resources/updated' -Params ([ordered]@{ uri = 'test://doc' }) } $session | Should -BeFalse
        Invoke-McpInModule { param($s, $x) Invoke-McpLegacyMethod -Server $s -Session $x -Method 'tools/list' -Params $null } $script:server $session | Should -BeNullOrEmpty
    }
}
