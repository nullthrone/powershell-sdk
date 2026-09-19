[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'A fixture tool writes to the host on purpose to prove that host output never reaches the client.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force

    $script:server = New-McpServer -Name 'memory' -Version '1.2.3' -Title 'In memory' -Instructions 'Test server.' -PageSize 2 -RequestTimeoutSeconds 5
    Register-McpTool -Name 'echo' -Description 'Echoes.' -ScriptBlock { param([Parameter(Mandatory)][string] $Text) $Text } -Server $script:server
    Register-McpTool -Name 'add' -ScriptBlock { param([int] $A, [int] $B) [pscustomobject]@{ sum = $A + $B } } -OutputSchema @{ type = 'object'; properties = @{ sum = @{ type = 'integer' } }; required = @('sum') } -Server $script:server
    Register-McpTool -Name 'count' -ScriptBlock {
        param([int] $To = 3, [int] $DelayMs = 20, $Context)
        for ($i = 1; $i -le $To; $i++) {
            if ($Context.CancellationToken.IsCancellationRequested) { return "cancelled at $i" }
            Write-McpProgress -Context $Context -Progress $i -Total $To -Message "step $i"
            Write-McpLog -Context $Context -Level info -Message "log $i" -Logger 'counter'
            Start-Sleep -Milliseconds $DelayMs
        }
        "counted to $To"
    } -Server $script:server
    Register-McpTool -Name 'fail' -ScriptBlock { throw 'nope' } -Server $script:server
    Register-McpTool -Name 'context' -ScriptBlock { param($Context) [pscustomobject]@{ id = $Context.RequestId; version = $Context.ProtocolVersion; client = $Context.ClientInfo['name']; elicitation = (Test-McpClientCapability -Context $Context -Path 'elicitation.form') } } -Server $script:server
    Register-McpTool -Name 'host' -ScriptBlock { Write-Host 'to the host'; Write-Warning 'warned'; Write-Verbose 'verbose'; 'clean' } -Server $script:server
    $script:session = Connect-McpServer -Server $script:server -ClientInfo @{ name = 'pester'; version = '1' } -Capabilities @{ elicitation = @{ form = @{} } }
}

AfterAll {
    if ($script:session) { Disconnect-McpServer -Session $script:session }
}

Describe 'Connect-McpServer over the in-memory transport' {
    It 'probes server/discover and exposes the server info' {
        $script:session.PSObject.TypeNames | Should -Contain 'Mcp.Session'
        $script:session.Kind | Should -Be 'InMemory'
        $script:session.ProtocolVersion | Should -Be '2026-07-28'
        $script:session.Name | Should -Be 'memory'
        $info = Get-McpServerInfo -Session $script:session
        $info.PSObject.TypeNames | Should -Contain 'Mcp.ServerInfo'
        $info.Name | Should -Be 'memory'
        $info.Version | Should -Be '1.2.3'
        $info.Title | Should -Be 'In memory'
        $info.Instructions | Should -Be 'Test server.'
        $info.SupportedVersions | Should -Be @('2026-07-28')
        $info.Capabilities['tools']['listChanged'] | Should -BeTrue
        (Get-McpServerInfo -Session $script:session -Refresh).Name | Should -Be 'memory'
    }

    It 'is the default session' {
        (Get-McpServerInfo).Name | Should -Be 'memory'
    }

    It 'lists tools across pages' {
        $tools = Get-McpTool -Session $script:session
        @($tools | ForEach-Object Name) | Should -Be @('echo', 'add', 'count', 'fail', 'context', 'host')
        $tools[0].PSObject.TypeNames | Should -Contain 'Mcp.Tool'
        $tools[0].Description | Should -Be 'Echoes.'
        $tools[0].InputSchema['required'] | Should -Be @('Text')
        (Get-McpTool -Name 'add' -Session $script:session).OutputSchema['required'] | Should -Be @('sum')
        { Get-McpTool -Name 'missing' -Session $script:session } | Should -Throw -ExpectedMessage '*no tool named*'
    }

    It 'calls a tool and returns text' {
        $result = Invoke-McpTool -Name 'echo' -Arguments @{ Text = 'héllo 😀' } -Session $script:session
        $result.PSObject.TypeNames | Should -Contain 'Mcp.ToolResult'
        $result.IsError | Should -BeFalse
        $result.Text | Should -Be 'héllo 😀'
        $result.Content[0].type | Should -Be 'text'
        $result.ResultType | Should -Be 'complete'
        $result.Meta['io.modelcontextprotocol/serverInfo']['name'] | Should -Be 'memory'
    }

    It 'returns structured content validated against the output schema' {
        $result = Invoke-McpTool -Name 'add' -Arguments @{ A = 2; B = 3 } -Session $script:session
        $result.StructuredContent['sum'] | Should -Be 5
        $result.Text | Should -Be '{"sum":5}'
    }

    It 'delivers progress and log notifications while a call runs' {
        $progress = [System.Collections.Generic.List[object]]::new()
        $script:session.Log.Clear()
        $result = Invoke-McpTool -Name 'count' -Arguments @{ To = 3 } -OnProgress { param($p) $progress.Add($p) } -LogLevel info -Session $script:session
        $result.Text | Should -Be 'counted to 3'
        @($progress | ForEach-Object Progress) | Should -Be @(1, 2, 3)
        $progress[0].Total | Should -Be 3
        $progress[2].Message | Should -Be 'step 3'
        $script:session.Log.Count | Should -Be 3
        $script:session.Log[0].Level | Should -Be 'info'
        $script:session.Log[0].Logger | Should -Be 'counter'
        $script:session.Log[0].Data | Should -Be 'log 1'
    }

    It 'does not send log notifications without a log level' {
        $script:session.Log.Clear()
        $null = Invoke-McpTool -Name 'count' -Arguments @{ To = 1 } -Session $script:session
        $script:session.Log.Count | Should -Be 0
    }

    It 'passes the request context to handlers' {
        $result = Invoke-McpTool -Name 'context' -Session $script:session
        $result.StructuredContent['version'] | Should -Be '2026-07-28'
        $result.StructuredContent['client'] | Should -Be 'pester'
        $result.StructuredContent['elicitation'] | Should -BeTrue
        $result.StructuredContent['id'] | Should -BeGreaterThan 0
    }

    It 'returns tool execution errors as results with IsError' {
        $result = Invoke-McpTool -Name 'fail' -Session $script:session
        $result.IsError | Should -BeTrue
        $result.Text | Should -Be 'Error: nope'
    }

    It 'throws protocol errors for unknown tools and invalid arguments' {
        $exception = $null
        try { Invoke-McpTool -Name 'missing' -Session $script:session } catch { $exception = $_.Exception }
        $exception | Should -BeOfType [McpProtocolException]
        $exception.Code | Should -Be -32602
        try { Invoke-McpTool -Name 'echo' -Arguments @{ Text = 5 } -Session $script:session } catch { $exception = $_.Exception }
        $exception.Code | Should -Be -32602
        $exception.Data['errors'] | Should -Not -BeNullOrEmpty
    }

    It 'keeps host and stream output of handlers away from the client' {
        $result = Invoke-McpTool -Name 'host' -Session $script:session
        $result.Text | Should -Be 'clean'
        $result.IsError | Should -BeFalse
        $result.Content.Count | Should -Be 1
    }

    It 'cancels a call on timeout and the session stays usable' {
        { Invoke-McpTool -Name 'count' -Arguments @{ To = 100; DelayMs = 100 } -TimeoutSeconds 1 -Session $script:session } | Should -Throw -ExceptionType ([System.TimeoutException])
        (Invoke-McpTool -Name 'echo' -Arguments @{ Text = 'alive' } -Session $script:session).Text | Should -Be 'alive'
    }

    It 'enforces the server-side request timeout' {
        $slow = New-McpServer -Name 'slow' -Version '1' -RequestTimeoutSeconds 1
        Register-McpTool -Name 'sleep' -ScriptBlock { Start-Sleep -Seconds 30; 'late' } -Server $slow
        $session = Connect-McpServer -Server $slow
        try {
            $exception = $null
            try { Invoke-McpTool -Name 'sleep' -Session $session } catch { $exception = $_.Exception }
            $exception | Should -BeOfType [McpProtocolException]
            $exception.Code | Should -Be -32603
            $exception.Message | Should -Match 'timed out'
        } finally {
            Disconnect-McpServer -Session $session
        }
    }

    It 'runs handlers concurrently up to MaxConcurrency' {
        $parallel = New-McpServer -Name 'parallel' -Version '1' -MaxConcurrency 4
        Register-McpTool -Name 'sleep' -ScriptBlock { param([int] $Ms) Start-Sleep -Milliseconds $Ms; 'ok' } -Server $parallel
        $pair = Invoke-McpInModule { New-McpInMemoryTransportPair }
        $background = Invoke-McpInModule { param($s, $e) Start-McpBackgroundServer -Server $s -Endpoint $e } $parallel $pair.Server
        try {
            $meta = '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            foreach ($n in 1..4) {
                Invoke-McpInModule { param($t, $l) Send-McpTransportLine -Transport $t -Line $l } $pair.Client "{`"jsonrpc`":`"2.0`",`"id`":$n,`"method`":`"tools/call`",`"params`":{$meta,`"name`":`"sleep`",`"arguments`":{`"Ms`":400}}}"
            }
            $responses = foreach ($n in 1..4) {
                $received = Invoke-McpInModule { param($t) Receive-McpTransportLine -Transport $t -TimeoutMs 10000 } $pair.Client
                $received.Status | Should -Be 'Line'
                Invoke-McpInModule { param($l) ConvertFrom-McpJson $l } $received.Line
            }
            $stopwatch.Stop()
            @($responses | ForEach-Object { $_['result']['content'][0]['text'] }) | Should -Be @('ok', 'ok', 'ok', 'ok')
            $stopwatch.ElapsedMilliseconds | Should -BeLessThan 1500
        } finally {
            Invoke-McpInModule { param($t) Close-McpTransport -Transport $t } $pair.Client
            Invoke-McpInModule { param($b) Stop-McpBackgroundServer -Background $b } $background
        }
    }

    It 'answers raw protocol violations like the specification requires' {
        $raw = New-McpServer -Name 'raw' -Version '1'
        Register-McpTool -Name 'echo' -ScriptBlock { param([string] $Text) $Text } -Server $raw
        $pair = Invoke-McpInModule { New-McpInMemoryTransportPair }
        $background = Invoke-McpInModule { param($s, $e) Start-McpBackgroundServer -Server $s -Endpoint $e } $raw $pair.Server
        try {
            $send = { param($line) Invoke-McpInModule { param($t, $l) Send-McpTransportLine -Transport $t -Line $l } $pair.Client $line }
            $receive = {
                $received = Invoke-McpInModule { param($t) Receive-McpTransportLine -Transport $t -TimeoutMs 10000 } $pair.Client
                $received.Status | Should -Be 'Line'
                Invoke-McpInModule { param($l) ConvertFrom-McpJson $l } $received.Line
            }
            & $send 'not json'
            $parseError = & $receive
            $parseError['id'] | Should -BeNull
            $parseError['error']['code'] | Should -Be -32700
            & $send '{"jsonrpc":"2.0","id":null,"method":"tools/list"}'
            (& $receive)['error']['code'] | Should -Be -32600
            & $send '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
            (& $receive)['error']['code'] | Should -Be -32602
            & $send '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1999-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}'
            $version = & $receive
            $version['error']['code'] | Should -Be -32022
            $version['error']['data']['supported'] | Should -Be @('2026-07-28')
            & $send '{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"legacy","version":"1"}}}'
            $legacy = & $receive
            $legacy['error']['code'] | Should -Be -32601
            $legacy['error']['message'] | Should -Match '2026-07-28'
            & $send '{"jsonrpc":"2.0","id":4,"method":"nothing/here","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
            (& $receive)['error']['code'] | Should -Be -32601
            & $send '{"jsonrpc":"2.0","id":"s-1","method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}},"name":"echo","arguments":{"Text":"id kept"}}}'
            $response = & $receive
            $response['id'] | Should -BeOfType [string]
            $response['id'] | Should -Be 's-1'
            $response['result']['content'][0]['text'] | Should -Be 'id kept'
            (Test-McpSpecShape -Definition 'CallToolResult' -Instance $response['result']).IsValid | Should -BeTrue
            & $send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"never-sent"}}'
            & $send '{"jsonrpc":"2.0","id":5,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
            $discover = & $receive
            $discover['id'] | Should -Be 5
            (Test-McpSpecShape -Definition 'DiscoverResult' -Instance $discover['result']).IsValid | Should -BeTrue
        } finally {
            Invoke-McpInModule { param($t) Close-McpTransport -Transport $t } $pair.Client
            Invoke-McpInModule { param($b) Stop-McpBackgroundServer -Background $b } $background
        }
    }

    It 'stops the background server on disconnect' {
        $server = New-McpServer -Name 'short' -Version '1'
        $session = Connect-McpServer -Server $server
        $server.State.Started | Should -BeTrue
        Disconnect-McpServer -Session $session
        $session.Closed | Should -BeTrue
        $server.State.Started | Should -BeFalse
        { Get-McpServerInfo -Session $session } | Should -Throw -ExpectedMessage '*closed*'
    }
}
