[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force

    $script:server = New-McpServer -Name 'http' -Version '2.0.0' -Title 'HTTP test server' -Instructions 'Test server over Streamable HTTP.' -RequestTimeoutSeconds 30
    Register-McpTool -Name 'echo' -Description 'Echoes.' -ScriptBlock { param([Parameter(Mandatory)][string] $Text) $Text } -Server $script:server
    Register-McpTool -Name 'add' -Description 'Adds.' -ScriptBlock { param([int] $A, [int] $B) [pscustomobject]@{ sum = $A + $B } } -OutputSchema @{ type = 'object'; properties = @{ sum = @{ type = 'integer' } }; required = @('sum') } -Server $script:server
    Register-McpTool -Name 'count' -Description 'Counts with progress; a marker file records where it stopped.' -ScriptBlock {
        param([int] $To = 3, [int] $DelayMs = 20, [string] $MarkerPath = '', $Context)
        $i = 0
        try {
            for ($i = 1; $i -le $To; $i++) {
                if ($Context.CancellationToken.IsCancellationRequested) { return "cancelled at $i" }
                Write-McpProgress -Context $Context -Progress $i -Total $To -Message "step $i"
                Write-McpLog -Context $Context -Level info -Message "log $i" -Logger 'counter'
                Start-Sleep -Milliseconds $DelayMs
            }
            "counted to $To"
        } finally {
            # Runs when the pipeline is stopped, too; cmdlets cannot be called then, .NET methods can.
            if ($MarkerPath) { [System.IO.File]::WriteAllText($MarkerPath, "stopped at $i of $To") }
        }
    } -Server $script:server
    Register-McpTool -Name 'fail' -Description 'Fails.' -ScriptBlock { throw 'nope' } -Server $script:server
    Register-McpTool -Name 'region' -Description 'Mirrors parameters into headers.' -ScriptBlock { param([Parameter(Mandatory)][string] $Region, [int] $Priority = 1, [string] $Query = '') "$Region/$Priority/$Query" } -Header @{ Region = 'Region'; Priority = 'Priority' } -Server $script:server
    Register-McpTool -Name 'needs_sampling' -Description 'Requires the sampling capability.' -ScriptBlock {
        param($Context)
        if (-not (Test-McpClientCapability -Context $Context -Path 'sampling')) {
            throw [McpProtocolException]::new(-32021, 'This tool requires the sampling capability.', @{ requiredCapabilities = @{ sampling = @{} } })
        }
        'sampled'
    } -Server $script:server
    Register-McpResource -Uri 'test://doc' -Name 'doc' -Content 'document' -Server $script:server
    Register-McpPrompt -Name 'hello' -Description 'Says hello.' -ScriptBlock { param([string] $Name = 'world') "Hello, $Name!" } -Server $script:server
    $script:handle = Start-McpTestHttpServer -Server $script:server -Parameters @{ KeepAliveSeconds = 1 }
    $script:url = $script:handle.Url
    $script:meta = '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'
    $script:session = Connect-McpServer -Url $script:url -Capabilities @{ elicitation = @{ form = @{} } }
}

AfterAll {
    if ($script:session) { Disconnect-McpServer -Session $script:session }
    if ($script:handle) { Stop-McpTestHttpServer -Handle $script:handle }
}

Describe 'Connect-McpServer over Streamable HTTP' -Tag 'Integration' {
    It 'connects, discovers and lists the tools with their header annotations' {
        $script:session.Kind | Should -Be 'Http'
        $script:session.Endpoint | Should -Be $script:url
        $script:session.Name | Should -Be 'http'
        $script:session.ProtocolVersion | Should -Be '2026-07-28'
        (Get-McpServerInfo -Session $script:session).Title | Should -Be 'HTTP test server'
        @(Get-McpTool -Session $script:session | ForEach-Object Name) | Should -Be @('echo', 'add', 'count', 'fail', 'region', 'needs_sampling')
        @($script:session.ToolHeaders['region'] | ForEach-Object { $_.Header }) | Should -Be @('Region', 'Priority')
        $script:session.ToolHeaders['echo'].Count | Should -Be 0
    }

    It 'round-trips text, structured content and tool errors' {
        (Invoke-McpTool -Name 'echo' -Arguments @{ Text = 'héllo 😀 日本' } -Session $script:session).Text | Should -Be 'héllo 😀 日本'
        $big = 'x' * 1MB
        (Invoke-McpTool -Name 'echo' -Arguments @{ Text = $big } -Session $script:session).Text.Length | Should -Be 1MB
        $result = Invoke-McpTool -Name 'add' -Arguments @{ A = 2; B = 40 } -Session $script:session
        $result.StructuredContent['sum'] | Should -Be 42
        $result.Meta['io.modelcontextprotocol/serverInfo']['name'] | Should -Be 'http'
        $failed = Invoke-McpTool -Name 'fail' -Session $script:session
        $failed.IsError | Should -BeTrue
        $failed.Text | Should -Be 'Error: nope'
    }

    It 'streams progress and log notifications on the response stream' {
        $progress = [System.Collections.Generic.List[object]]::new()
        $script:session.Log.Clear()
        $result = Invoke-McpTool -Name 'count' -Arguments @{ To = 3 } -OnProgress { param($p) $progress.Add($p.Progress) } -LogLevel info -Session $script:session
        $result.Text | Should -Be 'counted to 3'
        @($progress) | Should -Be @(1, 2, 3)
        $script:session.Log.Count | Should -Be 3
        $script:session.Log[0].Logger | Should -Be 'counter'
    }

    It 'mirrors annotated parameters into Mcp-Param headers that the server validates' {
        (Invoke-McpTool -Name 'region' -Arguments @{ Region = 'Hello, 世界'; Priority = 42; Query = 'q' } -Session $script:session).Text | Should -Be 'Hello, 世界/42/q'
        (Invoke-McpTool -Name 'region' -Arguments @{ Region = ' padded ' } -Session $script:session).Text | Should -Be ' padded /1/'
    }

    It 'surfaces protocol errors as McpProtocolException' {
        $exception = $null
        try { Invoke-McpTool -Name 'needs_sampling' -Session $script:session } catch { $exception = $_.Exception }
        $exception | Should -BeOfType [McpProtocolException]
        $exception.Code | Should -Be -32021
        $exception.Data['requiredCapabilities'].Contains('sampling') | Should -BeTrue
        try { Invoke-McpTool -Name 'missing' -Session $script:session } catch { $exception = $_.Exception }
        $exception.Code | Should -Be -32602
        try { Invoke-McpTool -Name 'echo' -Arguments @{ Text = 5 } -Session $script:session } catch { $exception = $_.Exception }
        $exception.Code | Should -Be -32602
    }

    It 'stops the handler when the client closes the connection on timeout' {
        $marker = Join-Path ([System.IO.Path]::GetTempPath()) ('mcp-cancel-' + [guid]::NewGuid().ToString('n') + '.txt')
        try {
            # 200 x 50 ms = 10 s of work; the client gives up after 1 s, the server notices through the
            # keep-alive (1 s interval in this fixture) and stops the handler long before it would finish.
            { Invoke-McpTool -Name 'count' -Arguments @{ To = 200; DelayMs = 50; MarkerPath = $marker } -TimeoutSeconds 1 -Session $script:session } | Should -Throw -ExceptionType ([System.TimeoutException])
            (Invoke-McpTool -Name 'echo' -Arguments @{ Text = 'alive' } -Session $script:session).Text | Should -Be 'alive'
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -Path $marker) -and $stopwatch.Elapsed.TotalSeconds -lt 8) { Start-Sleep -Milliseconds 100 }
            Test-Path -Path $marker | Should -BeTrue
            $text = [System.IO.File]::ReadAllText($marker)
            $text | Should -Match '^stopped at (\d+) of 200$'
            [int] ($text -replace '^stopped at (\d+) of 200$', '$1') | Should -BeLessThan 150
        } finally {
            Remove-Item -Path $marker -ErrorAction SilentlyContinue
        }
    }

    It 'answers 20 calls in well under a second each' {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        1..20 | ForEach-Object { $null = Invoke-McpTool -Name 'echo' -Arguments @{ Text = "x$_" } -Session $script:session }
        ($stopwatch.ElapsedMilliseconds / 20) | Should -BeLessThan 1000
    }
}

Describe 'Raw Streamable HTTP behaviour' -Tag 'Integration' {
    BeforeAll {
        function script:Send-Raw {
            param([string] $Body, [hashtable] $Headers = @{}, [string] $Method = 'POST', [switch] $NoVersion)
            $all = @{}
            if (-not $NoVersion) { $all['MCP-Protocol-Version'] = '2026-07-28' }
            foreach ($key in $Headers.Keys) { $all[$key] = $Headers[$key] }
            Invoke-McpRawHttp -Url ($script:url.TrimEnd('/')) -Body $(if ($Method -eq 'POST') { $Body } else { $null }) -Headers $all -Method $Method
        }
        $script:listCall = "{`"jsonrpc`":`"2.0`",`"id`":1,`"method`":`"tools/list`",`"params`":{$($script:meta)}}"
        $script:echoCall = "{`"jsonrpc`":`"2.0`",`"id`":10,`"method`":`"tools/call`",`"params`":{$($script:meta),`"name`":`"echo`",`"arguments`":{`"Text`":`"hi`"}}}"
        $script:regionCall = "{`"jsonrpc`":`"2.0`",`"id`":11,`"method`":`"tools/call`",`"params`":{$($script:meta),`"name`":`"region`",`"arguments`":{`"Region`":`"Hello`",`"Query`":`"q`",`"Priority`":42}}}"
    }

    It 'answers GET and DELETE with 405 and an Allow header' {
        foreach ($method in 'GET', 'DELETE') {
            $response = Send-Raw -Method $method
            $response.Status | Should -Be 405
            $response.Headers['Allow'] | Should -Be 'POST'
            $response.Json['error']['code'] | Should -Be -32600
            $response.Json.ContainsKey('id') | Should -BeFalse
        }
    }

    It 'rejects foreign origins with 403 and accepts loopback origins' {
        (Send-Raw -Body $script:listCall -Headers @{ Origin = 'http://evil.example.com'; 'Mcp-Method' = 'tools/list' }).Status | Should -Be 403
        (Send-Raw -Body $script:listCall -Headers @{ Origin = 'http://localhost:5173'; 'Mcp-Method' = 'tools/list' }).Status | Should -Be 200
    }

    It 'rejects other hosts and ports (DNS rebinding) with 404 and unsupported media types with 415' {
        (Send-Raw -Body $script:listCall -Headers @{ Host = 'evil.example.com'; 'Mcp-Method' = 'tools/list' }).Status | Should -Be 404
        (Send-Raw -Body $script:listCall -Headers @{ Host = "evil.example.com:$(([uri] $script:url).Port)"; 'Mcp-Method' = 'tools/list' }).Status | Should -Be 404
        (Send-Raw -Body $script:listCall -Headers @{ Host = '127.0.0.1:1'; 'Mcp-Method' = 'tools/list' }).Status | Should -Be 404
        (Send-Raw -Body $script:listCall -Headers @{ Host = ([uri] $script:url).Authority; 'Mcp-Method' = 'tools/list' }).Status | Should -Be 200
        (Invoke-McpRawHttp -Url $script:url -Body 'text' -ContentType 'text/plain' -Headers @{ 'MCP-Protocol-Version' = '2026-07-28'; 'Mcp-Method' = 'x' }).Status | Should -Be 415
    }

    It 'answers parse errors with 400 and an id-less error, notifications with 202 and responses with 400' {
        $parse = Send-Raw -Body '{not json' -Headers @{ 'Mcp-Method' = 'x' }
        $parse.Status | Should -Be 400
        $parse.Json['error']['code'] | Should -Be -32700
        $parse.Json.ContainsKey('id') | Should -BeFalse
        (Test-McpSpecShape -Definition 'JSONRPCErrorResponse' -Instance $parse.Json).IsValid | Should -BeTrue
        $notification = Send-Raw -Body '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}'
        $notification.Status | Should -Be 202
        $notification.Body | Should -BeNullOrEmpty
        (Send-Raw -Body '{"jsonrpc":"2.0","id":1,"result":{}}').Status | Should -Be 400
        (Send-Raw -Body '{"jsonrpc":"2.0","id":null,"method":"tools/list"}' -Headers @{ 'Mcp-Method' = 'tools/list' }).Json['error']['code'] | Should -Be -32600
    }

    It 'validates the standard headers (<Name>)' -TestCases @(
        @{ Name = 'missing Mcp-Method'; Headers = @{}; Status = 400; Code = -32020 }
        @{ Name = 'mismatched Mcp-Method'; Headers = @{ 'Mcp-Method' = 'prompts/list' }; Status = 400; Code = -32020 }
        @{ Name = 'case-mismatched Mcp-Method value'; Headers = @{ 'Mcp-Method' = 'TOOLS/LIST' }; Status = 400; Code = -32020 }
        @{ Name = 'lowercase header name'; Headers = @{ 'mcp-method' = 'tools/list' }; Status = 200; Code = $null }
        @{ Name = 'uppercase header name'; Headers = @{ 'MCP-METHOD' = 'tools/list' }; Status = 200; Code = $null }
        @{ Name = 'whitespace around the value'; Headers = @{ 'Mcp-Method' = '  tools/list  ' }; Status = 200; Code = $null }
    ) {
        $response = Send-Raw -Body $script:listCall -Headers $Headers
        $response.Status | Should -Be $Status
        if ($null -ne $Code) {
            $response.Json['error']['code'] | Should -Be $Code
            $response.Json['id'] | Should -Be 1
        } else {
            $response.Json['result']['tools'].Count | Should -BeGreaterThan 0
        }
    }

    It 'validates the protocol version header against _meta and the supported versions' {
        $missing = Send-Raw -Body $script:listCall -Headers @{ 'Mcp-Method' = 'tools/list' } -NoVersion
        $missing.Status | Should -Be 400
        $missing.Json['error']['code'] | Should -Be -32020
        $body = "{`"jsonrpc`":`"2.0`",`"id`":2,`"method`":`"tools/list`",`"params`":{`"_meta`":{`"io.modelcontextprotocol/protocolVersion`":`"v999.0.0`",`"io.modelcontextprotocol/clientCapabilities`":{}}}}"
        $mismatch = Send-Raw -Body $body -Headers @{ 'Mcp-Method' = 'tools/list' }
        $mismatch.Status | Should -Be 400
        $mismatch.Json['error']['code'] | Should -Be -32020
        $unsupported = Send-Raw -Body $body -Headers @{ 'Mcp-Method' = 'tools/list'; 'MCP-Protocol-Version' = 'v999.0.0' }
        $unsupported.Status | Should -Be 400
        $unsupported.Json['error']['code'] | Should -Be -32022
        $unsupported.Json['error']['data']['supported'] | Should -Be @('2026-07-28')
        $unsupported.Json['error']['data']['requested'] | Should -Be 'v999.0.0'
        $unsupported.Json['id'] | Should -Be 2
    }

    It 'answers missing _meta with 400 and -32602, removed and unknown methods with 404 and -32601' {
        $noMeta = Send-Raw -Body '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}' -Headers @{ 'Mcp-Method' = 'tools/list' }
        $noMeta.Status | Should -Be 400
        $noMeta.Json['error']['code'] | Should -Be -32602
        $noMeta.Json['id'] | Should -Be 3
        # Methods of the legacy revisions exist only in a legacy session: a modern request (with _meta) for them,
        # initialize included, is a request for a removed method.
        foreach ($method in 'initialize', 'ping', 'logging/setLevel', 'resources/subscribe', 'nothing/here') {
            $response = Send-Raw -Body "{`"jsonrpc`":`"2.0`",`"id`":4,`"method`":`"$method`",`"params`":{$($script:meta)}}" -Headers @{ 'Mcp-Method' = $method }
            $response.Status | Should -Be 404
            $response.Json['error']['code'] | Should -Be -32601
            $response.Json['id'] | Should -Be 4
        }
    }

    It 'validates Mcp-Name for tools/call including whitespace and the Base64 sentinel' {
        (Send-Raw -Body $script:echoCall -Headers @{ 'Mcp-Method' = 'tools/call' }).Json['error']['code'] | Should -Be -32020
        (Send-Raw -Body $script:echoCall -Headers @{ 'Mcp-Method' = 'tools/call'; 'Mcp-Name' = 'other' }).Status | Should -Be 400
        (Send-Raw -Body $script:echoCall -Headers @{ 'Mcp-Method' = 'tools/call'; 'Mcp-Name' = '  echo  ' }).Json['result']['content'][0]['text'] | Should -Be 'hi'
        (Send-Raw -Body $script:echoCall -Headers @{ 'Mcp-Method' = 'tools/call'; 'Mcp-Name' = '=?base64?ZWNobw==?=' }).Status | Should -Be 200
    }

    It 'validates Mcp-Name for resources/read and prompts/get and answers unknown resources with 400 and the URI' {
        $read = "{`"jsonrpc`":`"2.0`",`"id`":30,`"method`":`"resources/read`",`"params`":{$($script:meta),`"uri`":`"test://doc`"}}"
        $ok = Send-Raw -Body $read -Headers @{ 'Mcp-Method' = 'resources/read'; 'Mcp-Name' = 'test://doc' }
        $ok.Status | Should -Be 200
        $ok.Json['result']['contents'][0]['text'] | Should -Be 'document'
        (Test-McpSpecShape -Definition 'ReadResourceResult' -Instance $ok.Json['result']).IsValid | Should -BeTrue
        $mismatch = Send-Raw -Body $read -Headers @{ 'Mcp-Method' = 'resources/read'; 'Mcp-Name' = 'test://other' }
        $mismatch.Status | Should -Be 400
        $mismatch.Json['error']['code'] | Should -Be -32020
        (Send-Raw -Body $read -Headers @{ 'Mcp-Method' = 'resources/read' }).Status | Should -Be 400
        $missing = "{`"jsonrpc`":`"2.0`",`"id`":31,`"method`":`"resources/read`",`"params`":{$($script:meta),`"uri`":`"test://missing`"}}"
        $notFound = Send-Raw -Body $missing -Headers @{ 'Mcp-Method' = 'resources/read'; 'Mcp-Name' = 'test://missing' }
        $notFound.Status | Should -Be 400
        $notFound.Json['error']['code'] | Should -Be -32602
        $notFound.Json['error']['data']['uri'] | Should -Be 'test://missing'
        $prompt = "{`"jsonrpc`":`"2.0`",`"id`":32,`"method`":`"prompts/get`",`"params`":{$($script:meta),`"name`":`"hello`",`"arguments`":{`"Name`":`"HTTP`"}}}"
        (Send-Raw -Body $prompt -Headers @{ 'Mcp-Method' = 'prompts/get'; 'Mcp-Name' = 'hello' }).Json['result']['messages'][0]['content']['text'] | Should -Be 'Hello, HTTP!'
        (Send-Raw -Body $prompt -Headers @{ 'Mcp-Method' = 'prompts/get'; 'Mcp-Name' = 'bye' }).Json['error']['code'] | Should -Be -32020
    }

    It 'serves resources and prompts to the HTTP client' {
        (Read-McpResource -Uri 'test://doc' -Session $script:session).Text | Should -Be 'document'
        (Invoke-McpPrompt -Name 'hello' -Session $script:session).Text | Should -Be 'Hello, world!'
    }

    It 'validates Mcp-Param headers (<Name>)' -TestCases @(
        @{ Name = 'plain value'; Headers = @{ 'Mcp-Param-Region' = 'Hello'; 'Mcp-Param-Priority' = '42' }; Status = 200 }
        @{ Name = 'Base64 sentinel'; Headers = @{ 'Mcp-Param-Region' = '=?base64?SGVsbG8=?='; 'Mcp-Param-Priority' = '42.0' }; Status = 200 }
        @{ Name = 'invalid Base64 padding'; Headers = @{ 'Mcp-Param-Region' = '=?base64?SGVsbG8?='; 'Mcp-Param-Priority' = '42' }; Status = 400 }
        @{ Name = 'invalid Base64 characters'; Headers = @{ 'Mcp-Param-Region' = '=?base64?SGVs!!!bG8=?='; 'Mcp-Param-Priority' = '42' }; Status = 400 }
        @{ Name = 'missing header with a body value'; Headers = @{ 'Mcp-Param-Priority' = '42' }; Status = 400 }
        @{ Name = 'mismatched value'; Headers = @{ 'Mcp-Param-Region' = 'World'; 'Mcp-Param-Priority' = '42' }; Status = 400 }
        @{ Name = 'mismatched integer'; Headers = @{ 'Mcp-Param-Region' = 'Hello'; 'Mcp-Param-Priority' = '41' }; Status = 400 }
    ) {
        $all = @{ 'Mcp-Method' = 'tools/call'; 'Mcp-Name' = 'region' }
        foreach ($key in $Headers.Keys) { $all[$key] = $Headers[$key] }
        $response = Send-Raw -Body $script:regionCall -Headers $all
        $response.Status | Should -Be $Status
        if ($Status -eq 400) { $response.Json['error']['code'] | Should -Be -32020 } else { $response.Json['result']['content'][0]['text'] | Should -Be 'Hello/42/q' }
    }

    It 'accepts a request id again as soon as its response was sent' {
        # The worker of an answered request may still be winding down; its id must be free nonetheless.
        $headers = @{ 'Mcp-Method' = 'tools/call'; 'Mcp-Name' = 'echo' }
        $statuses = @(1..50 | ForEach-Object { (Send-Raw -Body $script:echoCall -Headers $headers).Status })
        @($statuses | Where-Object { $_ -ne 200 }).Count | Should -Be 0
    }

    It 'treats values without the full sentinel as literals' {
        $body = "{`"jsonrpc`":`"2.0`",`"id`":12,`"method`":`"tools/call`",`"params`":{$($script:meta),`"name`":`"region`",`"arguments`":{`"Region`":`"=?base64?SGVsbG8=`",`"Query`":`"q`"}}}"
        (Send-Raw -Body $body -Headers @{ 'Mcp-Method' = 'tools/call'; 'Mcp-Name' = 'region'; 'Mcp-Param-Region' = '=?base64?SGVsbG8=' }).Json['result']['content'][0]['text'] | Should -Be '=?base64?SGVsbG8=/1/q'
    }

    It 'streams SSE events for a request with a progress token and validates the wire shapes' {
        $body = "{`"jsonrpc`":`"2.0`",`"id`":13,`"method`":`"tools/call`",`"params`":{`"_meta`":{`"io.modelcontextprotocol/protocolVersion`":`"2026-07-28`",`"io.modelcontextprotocol/clientCapabilities`":{},`"progressToken`":`"progress-test-1`"},`"name`":`"count`",`"arguments`":{`"To`":3,`"DelayMs`":10}}}"
        $response = Send-Raw -Body $body -Headers @{ 'Mcp-Method' = 'tools/call'; 'Mcp-Name' = 'count' }
        $response.Status | Should -Be 200
        $response.ContentType | Should -Be 'text/event-stream'
        $response.Headers['X-Accel-Buffering'] | Should -Be 'no'
        $events = @($response.Body -split "`n`n" | Where-Object { $_ -match 'data:' })
        $events.Count | Should -Be 4
        $messages = @($events | ForEach-Object { ($_ -split "`n" | Where-Object { $_ -like 'data:*' }) -replace '^data:\s*', '' } | ForEach-Object { ConvertFrom-Json -InputObject $_ -AsHashtable })
        @($messages[0..2] | ForEach-Object { $_['params']['progress'] }) | Should -Be @(1, 2, 3)
        $messages[0]['params']['progressToken'] | Should -Be 'progress-test-1'
        $messages[3]['id'] | Should -Be 13
        $messages[3]['result']['content'][0]['text'] | Should -Be 'counted to 3'
        (Test-McpSpecShape -Definition 'ProgressNotification' -Instance $messages[0]).IsValid | Should -BeTrue
        (Test-McpSpecShape -Definition 'CallToolResult' -Instance $messages[3]['result']).IsValid | Should -BeTrue
        $response.Body | Should -Not -Match 'notifications/message'
    }

    It 'answers -32021 from a handler with 400 and the required capabilities' {
        $body = "{`"jsonrpc`":`"2.0`",`"id`":14,`"method`":`"tools/call`",`"params`":{$($script:meta),`"name`":`"needs_sampling`",`"arguments`":{}}}"
        $response = Send-Raw -Body $body -Headers @{ 'Mcp-Method' = 'tools/call'; 'Mcp-Name' = 'needs_sampling' }
        $response.Status | Should -Be 400
        $response.Json['error']['code'] | Should -Be -32021
        $response.Json['error']['data']['requiredCapabilities'].ContainsKey('sampling') | Should -BeTrue
        $response.Json['id'] | Should -Be 14
    }
}

Describe 'Start-McpServer -Transport Http' -Tag 'Integration' {
    It 'fails clearly when the port is in use' {
        $blocker = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $blocker.Start()
        try {
            $port = $blocker.LocalEndpoint.Port
            $server = New-McpServer -Name 'busy' -Version '1'
            { Start-McpServer -Server $server -Transport Http -Url "http://127.0.0.1:$port/mcp/" } | Should -Throw -ExpectedMessage '*Cannot listen*'
            $server.State.Started | Should -BeFalse
        } finally {
            $blocker.Stop()
        }
    }

    It 'rejects URLs that are not absolute http or https' {
        $server = New-McpServer -Name 'bad' -Version '1'
        { Start-McpServer -Server $server -Transport Http -Url 'ftp://127.0.0.1/mcp' } | Should -Throw -ExpectedMessage '*http or https*'
    }

    It 'stops on Stop-McpServer and refuses connections afterwards' {
        $server = New-McpServer -Name 'short' -Version '1'
        Register-McpTool -Name 'echo' -ScriptBlock { param([string] $Text) $Text } -Server $server
        $handle = Start-McpTestHttpServer -Server $server
        $session = Connect-McpServer -Url $handle.Url
        (Invoke-McpTool -Name 'echo' -Arguments @{ Text = 'x' } -Session $session).Text | Should -Be 'x'
        Disconnect-McpServer -Session $session
        Stop-McpTestHttpServer -Handle $handle
        $server.State.Started | Should -BeFalse
        { Invoke-McpRawHttp -Url $handle.Url -Body '{}' -TimeoutSeconds 5 } | Should -Throw
    }
}
