BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force
    $script:supported = @('2026-07-28')
}

Describe 'Get-McpRequestMeta' {
    It 'returns the fields of a valid _meta' {
        $params = Invoke-McpInModule { ConvertFrom-McpJson '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"elicitation":{"form":{}}},"io.modelcontextprotocol/clientInfo":{"name":"c","version":"1"},"io.modelcontextprotocol/logLevel":"info","progressToken":"p1"},"name":"x"}' }
        $meta = Invoke-McpInModule { param($p, $v) Get-McpRequestMeta -Params $p -SupportedVersions $v } $params $script:supported
        $meta.ProtocolVersion | Should -Be '2026-07-28'
        $meta.ClientCapabilities['elicitation']['form'] | Should -Not -BeNull
        $meta.ClientInfo['name'] | Should -Be 'c'
        $meta.LogLevel | Should -Be 'info'
        $meta.ProgressToken | Should -Be 'p1'
    }

    It 'leaves optional fields null' {
        $params = Invoke-McpInModule { ConvertFrom-McpJson '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}' }
        $meta = Invoke-McpInModule { param($p, $v) Get-McpRequestMeta -Params $p -SupportedVersions $v } $params $script:supported
        $meta.ClientInfo | Should -BeNull
        $meta.LogLevel | Should -BeNull
        $meta.ProgressToken | Should -BeNull
    }

    It 'rejects <Case> with -32602' -ForEach @(
        @{ Case = 'missing params'; Json = 'null' }
        @{ Case = 'missing _meta'; Json = '{"name":"x"}' }
        @{ Case = 'missing protocolVersion'; Json = '{"_meta":{"io.modelcontextprotocol/clientCapabilities":{}}}' }
        @{ Case = 'missing clientCapabilities'; Json = '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}' }
        @{ Case = 'non-object clientCapabilities'; Json = '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":"x"}}' }
        @{ Case = 'clientInfo without version'; Json = '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"c"}}}' }
        @{ Case = 'unknown logLevel'; Json = '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/logLevel":"loud"}}' }
        @{ Case = 'object progressToken'; Json = '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"progressToken":{}}}' }
    ) {
        $params = Invoke-McpInModule { param($j) ConvertFrom-McpJson $j } $Json
        $exception = $null
        try { Invoke-McpInModule { param($p, $v) Get-McpRequestMeta -Params $p -SupportedVersions $v } $params $script:supported } catch { $exception = $_.Exception }
        $exception | Should -Not -BeNull
        $exception.Code | Should -Be -32602
    }

    It 'rejects an unsupported protocol version with -32022 and lists the supported ones' {
        $params = Invoke-McpInModule { ConvertFrom-McpJson '{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01","io.modelcontextprotocol/clientCapabilities":{}}}' }
        $exception = $null
        try { Invoke-McpInModule { param($p, $v) Get-McpRequestMeta -Params $p -SupportedVersions $v } $params @('2026-07-28', '2025-11-25') } catch { $exception = $_.Exception }
        $exception.Code | Should -Be -32022
        $exception.Data['supported'] | Should -Be @('2026-07-28', '2025-11-25')
        $exception.Data['requested'] | Should -Be '1900-01-01'
    }
}

Describe 'Test-McpCapabilityPath' {
    It 'resolves dotted paths and extension identifiers' {
        $capabilities = Invoke-McpInModule { ConvertFrom-McpJson '{"elicitation":{"form":{}},"extensions":{"io.modelcontextprotocol/tasks":{"requests":{}}},"roots":{}}' }
        Invoke-McpInModule { param($c) Test-McpCapabilityPath -Capabilities $c -Path 'elicitation.form' } $capabilities | Should -BeTrue
        Invoke-McpInModule { param($c) Test-McpCapabilityPath -Capabilities $c -Path 'elicitation.url' } $capabilities | Should -BeFalse
        Invoke-McpInModule { param($c) Test-McpCapabilityPath -Capabilities $c -Path 'extensions.io.modelcontextprotocol/tasks' } $capabilities | Should -BeTrue
        Invoke-McpInModule { param($c) Test-McpCapabilityPath -Capabilities $c -Path 'extensions.io.modelcontextprotocol/tasks.requests' } $capabilities | Should -BeTrue
        Invoke-McpInModule { param($c) Test-McpCapabilityPath -Capabilities $c -Path 'roots' } $capabilities | Should -BeTrue
        Invoke-McpInModule { param($c) Test-McpCapabilityPath -Capabilities $c -Path 'sampling' } $capabilities | Should -BeFalse
        Invoke-McpInModule { Test-McpCapabilityPath -Capabilities $null -Path 'roots' } | Should -BeFalse
    }
}
