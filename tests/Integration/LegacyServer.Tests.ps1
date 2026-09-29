[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

# The legacy session of a dual-era server on the wire, over the in-memory transport (the same dispatcher path as
# stdio): the initialize handshake, the legacy-only methods, the legacy result shapes, server-initiated requests,
# session-wide logging and the unsolicited notifications.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force

    function Connect-LegacyWire {
        param([pscustomobject] $Server)
        $pair = Invoke-McpInModule { New-McpInMemoryTransportPair }
        $background = Invoke-McpInModule { param($s, $e) Start-McpBackgroundServer -Server $s -Endpoint $e } $Server $pair.Server
        @{ Pair = $pair; Background = $background }
    }

    function Disconnect-LegacyWire {
        param([hashtable] $Wire)
        Invoke-McpInModule { param($t) Close-McpTransport -Transport $t } $Wire.Pair.Client
        Invoke-McpInModule { param($b) Stop-McpBackgroundServer -Background $b } $Wire.Background
    }

    function Send-Line {
        param([hashtable] $Wire, [string] $Line)
        Invoke-McpInModule { param($t, $l) Send-McpTransportLine -Transport $t -Line $l } $Wire.Pair.Client $Line
    }

    function Receive-Message {
        param([hashtable] $Wire)
        $received = Invoke-McpInModule { param($t) Receive-McpTransportLine -Transport $t -TimeoutMs 10000 } $Wire.Pair.Client
        $received.Status | Should -Be 'Line'
        Invoke-McpInModule { param($l) ConvertFrom-McpJson $l } $received.Line
    }

    function Send-Json {
        param([hashtable] $Wire, [object] $Message)
        Send-Line -Wire $Wire -Line (Invoke-McpInModule { param($m) ConvertTo-McpJson -InputObject $m } -Parameters @{ m = $Message })
    }

    function Initialize-Legacy {
        param([hashtable] $Wire, [string] $Version = '2025-11-25', [hashtable] $Capabilities = @{})
        Send-Json -Wire $Wire -Message ([ordered]@{ jsonrpc = '2.0'; id = 0; method = 'initialize'; params = [ordered]@{ protocolVersion = $Version; capabilities = $Capabilities; clientInfo = [ordered]@{ name = 'legacy-test'; version = '1.0' } } })
        $answer = Receive-Message -Wire $Wire
        Send-Line -Wire $Wire -Line '{"jsonrpc":"2.0","method":"notifications/initialized"}'
        $answer
    }

    $script:server = New-McpServer -Name 'legacy' -Version '1.0.0' -Title 'Legacy test' -Description 'Only 2025-11-25 knows descriptions.' -Instructions 'Legacy instructions.' -RequestTimeoutSeconds 30
    Register-McpTool -Name 'echo' -ScriptBlock { param([string] $Text) $Text } -Server $script:server
    Register-McpTool -Name 'ask' -ScriptBlock {
        param($Context)
        $answer = Request-McpElicitation -Context $Context -Key 'name' -Message 'Your name?' -Schema @{ name = @{ type = 'string' } } -Required name
        if ($answer.Accepted) { "Hello, $($answer.Content.name)!" } else { "no: $($answer.Action)" }
    } -Server $script:server
    Register-McpTool -Name 'sample' -ScriptBlock {
        param($Context)
        $reply = Request-McpSampling -Context $Context -Key 'llm' -Messages 'Say hi' -MaxTokens 10
        "model said: $($reply.Text)"
    } -Server $script:server
    Register-McpTool -Name 'roots' -ScriptBlock {
        param($Context)
        $roots = Request-McpRoot -Context $Context -Key 'roots'
        @($roots | ForEach-Object Uri) -join ','
    } -Server $script:server
    Register-McpTool -Name 'chatty' -ScriptBlock {
        param($Context)
        Write-McpLog -Context $Context -Level debug -Message 'one'
        Write-McpLog -Context $Context -Level info -Message 'two'
        Write-McpLog -Context $Context -Level error -Message 'three'
        'logged'
    } -Server $script:server
    Register-McpTool -Name 'touch' -ScriptBlock { param([string] $Uri, $Context) Send-McpResourceUpdated -Context $Context -Uri $Uri; 'touched' } -Server $script:server
    Register-McpResource -Uri 'test://doc' -Name 'doc' -Content 'document' -Server $script:server
}

Describe 'Legacy session over the line transports' -Tag 'Integration' {
    It 'negotiates the version and answers initialize with an InitializeResult of the requested revision' {
        foreach ($case in @(@{ Requested = '2025-11-25'; Expected = '2025-11-25' }, @{ Requested = '2025-06-18'; Expected = '2025-06-18' }, @{ Requested = '2025-03-26'; Expected = '2025-03-26' }, @{ Requested = '2099-01-01'; Expected = '2025-11-25' })) {
            $wire = Connect-LegacyWire -Server $script:server
            try {
                $answer = Initialize-Legacy -Wire $wire -Version $case.Requested
                $answer['id'] | Should -Be 0
                $result = $answer['result']
                $result['protocolVersion'] | Should -Be $case.Expected
                $result['serverInfo']['name'] | Should -Be 'legacy'
                $result['instructions'] | Should -Be 'Legacy instructions.'
                $result['capabilities']['tools']['listChanged'] | Should -BeTrue
                $result['capabilities']['resources']['subscribe'] | Should -BeTrue
                $result['capabilities'].Contains('logging') | Should -BeTrue
                $result.Contains('resultType') | Should -BeFalse
                if ($case.Expected -eq '2025-11-25') {
                    $result['serverInfo']['description'] | Should -Be 'Only 2025-11-25 knows descriptions.'
                    (Test-McpSpecShape -Revision '2025-11-25' -Definition 'InitializeResult' -Instance $result).IsValid | Should -BeTrue
                } else {
                    $result['serverInfo'].Contains('description') | Should -BeFalse
                }
                if ($case.Expected -eq '2025-06-18') {
                    (Test-McpSpecShape -Revision '2025-06-18' -Definition 'InitializeResult' -Instance $result).IsValid | Should -BeTrue
                }
            } finally {
                Disconnect-LegacyWire -Wire $wire
            }
        }
    }

    It 'serves ping, logging/setLevel, lists, calls and reads in the legacy shapes' {
        $wire = Connect-LegacyWire -Server $script:server
        try {
            $null = Initialize-Legacy -Wire $wire
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":1,"method":"ping"}'
            $ping = Receive-Message -Wire $wire
            $ping['id'] | Should -Be 1
            $ping['result'].Count | Should -Be 0

            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
            $list = (Receive-Message -Wire $wire)['result']
            @($list['tools'] | ForEach-Object { $_['name'] }) | Should -Contain 'echo'
            foreach ($name in 'resultType', 'ttlMs', 'cacheScope', '_meta') { $list.Contains($name) | Should -BeFalse }
            (Test-McpSpecShape -Revision '2025-11-25' -Definition 'ListToolsResult' -Instance $list).IsValid | Should -BeTrue

            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":"c","method":"tools/call","params":{"name":"echo","arguments":{"Text":"legacy"}}}'
            $call = Receive-Message -Wire $wire
            $call['id'] | Should -Be 'c'
            $call['result']['content'][0]['text'] | Should -Be 'legacy'
            $call['result'].Contains('resultType') | Should -BeFalse
            $call['result'].Contains('_meta') | Should -BeFalse
            (Test-McpSpecShape -Revision '2025-11-25' -Definition 'CallToolResult' -Instance $call['result']).IsValid | Should -BeTrue

            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"test://doc"}}'
            $read = (Receive-Message -Wire $wire)['result']
            $read['contents'][0]['text'] | Should -Be 'document'
            $read.Contains('ttlMs') | Should -BeFalse

            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"test://missing"}}'
            $missing = Receive-Message -Wire $wire
            $missing['error']['code'] | Should -Be -32002
            $missing['error']['data']['uri'] | Should -Be 'test://missing'

            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":5,"method":"server/discover"}'
            (Receive-Message -Wire $wire)['error']['code'] | Should -Be -32601
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":6,"method":"logging/setLevel","params":{"level":"loud"}}'
            (Receive-Message -Wire $wire)['error']['code'] | Should -Be -32602
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"again","version":"1"}}}'
            (Receive-Message -Wire $wire)['error']['code'] | Should -Be -32600
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"nope"}}'
            (Receive-Message -Wire $wire)['error']['code'] | Should -Be -32602

            # A modern request on the same line is still served statelessly.
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":9,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
            $discover = (Receive-Message -Wire $wire)['result']
            $discover['resultType'] | Should -Be 'complete'
            $discover['supportedVersions'] | Should -Be @('2026-07-28')
        } finally {
            Disconnect-LegacyWire -Wire $wire
        }
    }

    It 'sends elicitation, sampling and roots requests to the client and hands the answers to the handler' {
        $wire = Connect-LegacyWire -Server $script:server
        try {
            $null = Initialize-Legacy -Wire $wire -Capabilities @{ elicitation = @{}; sampling = @{}; roots = @{ listChanged = $true } }

            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"ask"}}'
            $request = Receive-Message -Wire $wire
            $request['method'] | Should -Be 'elicitation/create'
            $request['params']['message'] | Should -Be 'Your name?'
            $request['params']['requestedSchema']['properties']['name']['type'] | Should -Be 'string'
            (Test-McpSpecShape -Revision '2025-11-25' -Definition 'ElicitRequest' -Instance $request).IsValid | Should -BeTrue
            Send-Json -Wire $wire -Message ([ordered]@{ jsonrpc = '2.0'; id = $request['id']; result = [ordered]@{ action = 'accept'; content = [ordered]@{ name = 'Ada' } } })
            $call = Receive-Message -Wire $wire
            $call['id'] | Should -Be 10
            $call['result']['content'][0]['text'] | Should -Be 'Hello, Ada!'

            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"sample"}}'
            $request = Receive-Message -Wire $wire
            $request['method'] | Should -Be 'sampling/createMessage'
            (Test-McpSpecShape -Revision '2025-11-25' -Definition 'CreateMessageRequest' -Instance $request).IsValid | Should -BeTrue
            Send-Json -Wire $wire -Message ([ordered]@{ jsonrpc = '2.0'; id = $request['id']; result = [ordered]@{ role = 'assistant'; model = 'm'; content = [ordered]@{ type = 'text'; text = 'hi' } } })
            (Receive-Message -Wire $wire)['result']['content'][0]['text'] | Should -Be 'model said: hi'

            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"roots"}}'
            $request = Receive-Message -Wire $wire
            $request['method'] | Should -Be 'roots/list'
            Send-Json -Wire $wire -Message ([ordered]@{ jsonrpc = '2.0'; id = $request['id']; result = [ordered]@{ roots = @([ordered]@{ uri = 'file:///a' }, [ordered]@{ uri = 'file:///b' }) } })
            (Receive-Message -Wire $wire)['result']['content'][0]['text'] | Should -Be 'file:///a,file:///b'

            # An error from the client fails the call; an answer that does not fit the request is rejected.
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"ask"}}'
            $request = Receive-Message -Wire $wire
            Send-Json -Wire $wire -Message ([ordered]@{ jsonrpc = '2.0'; id = $request['id']; error = [ordered]@{ code = -32601; message = 'no' } })
            (Receive-Message -Wire $wire)['error']['code'] | Should -Be -32603
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"ask"}}'
            $request = Receive-Message -Wire $wire
            Send-Json -Wire $wire -Message ([ordered]@{ jsonrpc = '2.0'; id = $request['id']; result = [ordered]@{ action = 'accept'; content = [ordered]@{ name = 42 } } })
            (Receive-Message -Wire $wire)['error']['code'] | Should -Be -32602

            # Cancelling a call that waits for the client ends it without a response.
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"ask"}}'
            $null = Receive-Message -Wire $wire
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":15}}'
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":16,"method":"ping"}'
            (Receive-Message -Wire $wire)['id'] | Should -Be 16
        } finally {
            Disconnect-LegacyWire -Wire $wire
        }
    }

    It 'refuses input requests the client did not declare' {
        $wire = Connect-LegacyWire -Server $script:server
        try {
            $null = Initialize-Legacy -Wire $wire -Version '2025-06-18'
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ask"}}'
            $answer = Receive-Message -Wire $wire
            $answer['error']['code'] | Should -Be -32600
            $answer['error']['message'] | Should -Match 'elicitation'
        } finally {
            Disconnect-LegacyWire -Wire $wire
        }
    }

    It 'sends log notifications after logging/setLevel and unsolicited list and resource notifications' {
        $wire = Connect-LegacyWire -Server $script:server
        try {
            $null = Initialize-Legacy -Wire $wire
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chatty"}}'
            (Receive-Message -Wire $wire)['result']['content'][0]['text'] | Should -Be 'logged'

            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":2,"method":"logging/setLevel","params":{"level":"info"}}'
            (Receive-Message -Wire $wire)['id'] | Should -Be 2
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"chatty"}}'
            $messages = @(Receive-Message -Wire $wire; Receive-Message -Wire $wire; Receive-Message -Wire $wire)
            @($messages[0..1] | ForEach-Object { $_['params']['data'] }) | Should -Be @('two', 'three')
            (Test-McpSpecShape -Revision '2025-11-25' -Definition 'LoggingMessageNotification' -Instance $messages[0]).IsValid | Should -BeTrue
            $messages[2]['id'] | Should -Be 3

            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":4,"method":"resources/subscribe","params":{"uri":"test://doc"}}'
            (Receive-Message -Wire $wire)['id'] | Should -Be 4
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"touch","arguments":{"Uri":"test://other"}}}'
            (Receive-Message -Wire $wire)['id'] | Should -Be 5
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"touch","arguments":{"Uri":"test://doc/part"}}}'
            $both = @(Receive-Message -Wire $wire; Receive-Message -Wire $wire)
            $updated = $both | Where-Object { $_['method'] -eq 'notifications/resources/updated' }
            $updated['params']['uri'] | Should -Be 'test://doc/part'
            $updated['params'].Contains('_meta') | Should -BeFalse
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":7,"method":"resources/unsubscribe","params":{"uri":"test://doc"}}'
            (Receive-Message -Wire $wire)['id'] | Should -Be 7
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"touch","arguments":{"Uri":"test://doc"}}}'
            (Receive-Message -Wire $wire)['id'] | Should -Be 8

            $null = Send-McpToolListChanged -Server $script:server
            $changed = Receive-Message -Wire $wire
            $changed['method'] | Should -Be 'notifications/tools/list_changed'
            $changed.Contains('params') | Should -BeFalse
        } finally {
            Disconnect-LegacyWire -Wire $wire
        }
    }

    It 'answers requests before initialize on a legacy-only server with an error that is not a modern one' {
        $legacyOnly = New-McpServer -Name 'old' -Version '1' -SupportedVersions '2025-11-25'
        Register-McpTool -Name 'echo' -ScriptBlock { param([string] $Text) $Text } -Server $legacyOnly
        $wire = Connect-LegacyWire -Server $legacyOnly
        try {
            Send-Line -Wire $wire -Line '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
            (Receive-Message -Wire $wire)['error']['code'] | Should -Be -32600
            (Initialize-Legacy -Wire $wire)['result']['protocolVersion'] | Should -Be '2025-11-25'
        } finally {
            Disconnect-LegacyWire -Wire $wire
        }
    }
}
