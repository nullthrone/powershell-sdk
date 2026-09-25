[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

# Legacy sessions of a dual-era server over Streamable HTTP, on the wire: Mcp-Session-Id, the GET stream, DELETE,
# server-initiated requests on the POST stream, era-aware status codes, session limits and expiry, and modern
# requests next to legacy sessions on the same endpoint.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force

    $script:server = New-McpServer -Name 'legacy-http' -Version '1.0.0' -RequestTimeoutSeconds 30
    Register-McpTool -Name 'echo' -ScriptBlock { param([string] $Text) $Text } -Server $script:server
    Register-McpTool -Name 'slow' -ScriptBlock { param([string] $Text) Start-Sleep -Milliseconds 700; $Text } -Server $script:server
    Register-McpTool -Name 'ask' -ScriptBlock {
        param($Context)
        $answer = Request-McpElicitation -Context $Context -Key 'name' -Message 'Your name?' -Schema @{ name = @{ type = 'string' } }
        "Hello, $($answer.Content.name)!"
    } -Server $script:server
    Register-McpTool -Name 'chatty' -ScriptBlock {
        param($Context)
        Write-McpLog -Context $Context -Level info -Message 'one'
        Write-McpLog -Context $Context -Level warning -Message 'two'
        'logged'
    } -Server $script:server
    Register-McpResource -Uri 'test://watched' -Name 'watched' -Content 'w' -Server $script:server
    $script:handle = Start-McpTestHttpServer -Server $script:server -Parameters @{ KeepAliveSeconds = 1 }
    $script:url = $script:handle.Url

    function script:Send-Legacy {
        param([string] $Body, [string] $SessionId, [hashtable] $Headers = @{}, [string] $Method = 'POST', [string] $Url = $script:url)
        $all = @{ 'Accept' = 'application/json, text/event-stream' }
        if ($SessionId) { $all['Mcp-Session-Id'] = $SessionId; $all['MCP-Protocol-Version'] = '2025-11-25' }
        foreach ($key in $Headers.Keys) {
            if ($null -eq $Headers[$key]) { $all.Remove($key) } else { $all[$key] = $Headers[$key] }
        }
        Invoke-McpRawHttp -Url $Url -Body $Body -Headers $all -Method $Method
    }

    function script:Open-Legacy {
        param([string] $Url = $script:url, [string] $Version = '2025-11-25', [string] $Capabilities = '{}')
        $answer = Send-Legacy -Url $Url -Body "{`"jsonrpc`":`"2.0`",`"id`":0,`"method`":`"initialize`",`"params`":{`"protocolVersion`":`"$Version`",`"capabilities`":$Capabilities,`"clientInfo`":{`"name`":`"raw`",`"version`":`"1`"}}}"
        $answer.Status | Should -Be 200
        $sessionId = $answer.Headers['Mcp-Session-Id']
        $sessionId | Should -Not -BeNullOrEmpty
        (Send-Legacy -Url $Url -SessionId $sessionId -Body '{"jsonrpc":"2.0","method":"notifications/initialized"}').Status | Should -Be 202
        @{ Id = $sessionId; Result = $answer.Json['result'] }
    }

    function script:Open-Stream {
        param([string] $Method, [string] $SessionId, [string] $Body, [string] $Url = $script:url)
        $handler = [System.Net.Http.SocketsHttpHandler]::new()
        $handler.UseProxy = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Url)
        if ($Body) { $request.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, 'application/json') }
        $null = $request.Headers.TryAddWithoutValidation('Accept', $(if ($Method -eq 'GET') { 'text/event-stream' } else { 'application/json, text/event-stream' }))
        $null = $request.Headers.TryAddWithoutValidation('Mcp-Session-Id', $SessionId)
        $null = $request.Headers.TryAddWithoutValidation('MCP-Protocol-Version', '2025-11-25')
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $sse = $null
        if ($response.Content.Headers.ContentType -and $response.Content.Headers.ContentType.MediaType -eq 'text/event-stream') {
            $sse = Invoke-McpInModule { param($s) New-McpSseReader -Stream $s } -Parameters @{ s = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult() }
        }
        @{ Client = $client; Response = $response; Sse = $sse; Status = [int] $response.StatusCode }
    }

    function script:Receive-StreamMessage {
        param([hashtable] $Stream, [int] $TimeoutMs = 10000)
        $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ([datetime]::UtcNow -lt $deadline) {
            $received = Invoke-McpInModule { param($s) Receive-McpSseEvent -Sse $s -TimeoutMs 250 } -Parameters @{ s = $Stream.Sse }
            if ($received.Status -eq 'Eof') { return $null }
            if ($received.Status -eq 'Event' -and $received.Data) { return Invoke-McpInModule { param($d) ConvertFrom-McpJson $d } -Parameters @{ d = $received.Data } }
        }
        $null
    }

    function script:Close-Stream {
        param([hashtable] $Stream)
        $Stream.Response.Dispose()
        $Stream.Client.Dispose()
    }
}

AfterAll {
    if ($script:handle) { Stop-McpTestHttpServer -Handle $script:handle }
}

Describe 'Legacy sessions over Streamable HTTP' -Tag 'Integration' {
    It 'mints a session id on initialize and serves the session in the legacy shapes' {
        $session = Open-Legacy
        $session.Id | Should -Match '^[\x21-\x7E]+$'
        $session.Result['protocolVersion'] | Should -Be '2025-11-25'
        (Test-McpSpecShape -Revision '2025-11-25' -Definition 'InitializeResult' -Instance $session.Result).IsValid | Should -BeTrue

        $list = Send-Legacy -SessionId $session.Id -Body '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
        $list.Status | Should -Be 200
        $list.Json['result'].Contains('resultType') | Should -BeFalse
        @($list.Json['result']['tools'] | ForEach-Object { $_['name'] }) | Should -Contain 'echo'

        $call = Send-Legacy -SessionId $session.Id -Body '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"Text":"hi"}}}'
        $call.Json['result']['content'][0]['text'] | Should -Be 'hi'
        $call.Json['result'].Contains('resultType') | Should -BeFalse

        # Errors of a session are JSON-RPC responses with status 200: 404 would tell the client its session is gone.
        $unknown = Send-Legacy -SessionId $session.Id -Body '{"jsonrpc":"2.0","id":3,"method":"nothing/here"}'
        $unknown.Status | Should -Be 200
        $unknown.Json['error']['code'] | Should -Be -32601
        $missing = Send-Legacy -SessionId $session.Id -Body '{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"test://nope"}}'
        $missing.Status | Should -Be 200
        $missing.Json['error']['code'] | Should -Be -32002

        $ping = Send-Legacy -SessionId $session.Id -Body '{"jsonrpc":"2.0","id":5,"method":"ping"}' -Headers @{ 'MCP-Protocol-Version' = $null }
        $ping.Json['result'].Count | Should -Be 0
        (Send-Legacy -SessionId $session.Id -Body '{"jsonrpc":"2.0","id":6,"method":"ping"}' -Headers @{ 'MCP-Protocol-Version' = '1999-01-01' }).Status | Should -Be 400
        $unknownSession = Send-Legacy -SessionId 'no-such-session' -Body '{"jsonrpc":"2.0","id":7,"method":"ping"}'
        $unknownSession.Status | Should -Be 404
        $unknownSession.Json['id'] | Should -Be 7
        # Without the session id the request is a modern one and fails the header validation of 2026-07-28.
        (Send-Legacy -Body '{"jsonrpc":"2.0","id":8,"method":"tools/list"}').Status | Should -Be 400
    }

    It 'opens the GET stream of a session and delivers list changes and resource updates on it' {
        $session = Open-Legacy
        $stream = Open-Stream -Method GET -SessionId $session.Id
        try {
            $stream.Status | Should -Be 200
            $second = Open-Stream -Method GET -SessionId $session.Id
            $second.Status | Should -Be 409
            Close-Stream -Stream $second

            $null = Send-McpToolListChanged -Server $script:server
            $changed = Receive-StreamMessage -Stream $stream
            $changed['method'] | Should -Be 'notifications/tools/list_changed'

            (Send-Legacy -SessionId $session.Id -Body '{"jsonrpc":"2.0","id":1,"method":"resources/subscribe","params":{"uri":"test://watched"}}').Json['result'].Count | Should -Be 0
            $null = Send-McpResourceUpdated -Server $script:server -Uri 'test://watched'
            $updated = Receive-StreamMessage -Stream $stream
            $updated['method'] | Should -Be 'notifications/resources/updated'
            $updated['params']['uri'] | Should -Be 'test://watched'
            (Test-McpSpecShape -Revision '2025-11-25' -Definition 'ResourceUpdatedNotification' -Instance $updated).IsValid | Should -BeTrue
        } finally {
            Close-Stream -Stream $stream
        }
        (Send-Legacy -SessionId $session.Id -Method DELETE -Body $null).Status | Should -Be 200
    }

    It 'sends server-initiated requests and log notifications on the POST stream and accepts the response with 202' {
        $session = Open-Legacy -Capabilities '{"elicitation":{}}'
        $stream = Open-Stream -Method POST -SessionId $session.Id -Body '{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"ask"}}'
        try {
            $stream.Status | Should -Be 200
            $request = Receive-StreamMessage -Stream $stream
            $request['method'] | Should -Be 'elicitation/create'
            $answer = Invoke-McpInModule { param($m) ConvertTo-McpJson -InputObject $m } -Parameters @{ m = [ordered]@{ jsonrpc = '2.0'; id = $request['id']; result = [ordered]@{ action = 'accept'; content = [ordered]@{ name = 'Grace' } } } }
            (Send-Legacy -SessionId $session.Id -Body $answer).Status | Should -Be 202
            $final = Receive-StreamMessage -Stream $stream
            $final['id'] | Should -Be 'a'
            $final['result']['content'][0]['text'] | Should -Be 'Hello, Grace!'
        } finally {
            Close-Stream -Stream $stream
        }

        (Send-Legacy -SessionId $session.Id -Body '{"jsonrpc":"2.0","id":1,"method":"logging/setLevel","params":{"level":"info"}}').Status | Should -Be 200
        $stream = Open-Stream -Method POST -SessionId $session.Id -Body '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chatty"}}'
        try {
            $messages = @(Receive-StreamMessage -Stream $stream; Receive-StreamMessage -Stream $stream; Receive-StreamMessage -Stream $stream)
            @($messages[0..1] | ForEach-Object { $_['params']['data'] }) | Should -Be @('one', 'two')
            $messages[2]['result']['content'][0]['text'] | Should -Be 'logged'
        } finally {
            Close-Stream -Stream $stream
        }
    }

    It 'ends a session on DELETE and answers its requests with 404 afterwards' {
        $session = Open-Legacy
        $stream = Open-Stream -Method GET -SessionId $session.Id
        try {
            (Send-Legacy -SessionId $session.Id -Method DELETE -Body $null).Status | Should -Be 200
            Receive-StreamMessage -Stream $stream -TimeoutMs 3000 | Should -BeNullOrEmpty
        } finally {
            Close-Stream -Stream $stream
        }
        (Send-Legacy -SessionId $session.Id -Body '{"jsonrpc":"2.0","id":1,"method":"ping"}').Status | Should -Be 404
        (Send-Legacy -SessionId $session.Id -Method GET -Body $null).Status | Should -Be 404
        (Send-Legacy -SessionId $session.Id -Method DELETE -Body $null).Status | Should -Be 404
        # Without a session id GET and DELETE stay 405.
        (Invoke-McpRawHttp -Url $script:url -Method GET -Body $null -Headers @{ Accept = 'text/event-stream' }).Status | Should -Be 405
    }

    It 'keeps request ids apart between sessions and the stateless core' {
        $first = Open-Legacy
        $second = Open-Legacy
        $jobs = foreach ($target in @($first.Id, $second.Id, $null)) {
            $body = if ($target) { '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"slow","arguments":{"Text":"' + $target + '"}}}' } else { '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}},"name":"slow","arguments":{"Text":"modern"}}}' }
            $headers = if ($target) { @{ Accept = 'application/json, text/event-stream'; 'Mcp-Session-Id' = $target } } else { @{ Accept = 'application/json, text/event-stream'; 'MCP-Protocol-Version' = '2026-07-28'; 'Mcp-Method' = 'tools/call'; 'Mcp-Name' = 'slow' } }
            $support = Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1'
            $manifest = Get-McpBuiltModuleManifest
            $url = $script:url
            Start-ThreadJob -ScriptBlock {
                Import-Module $using:support
                Import-Module $using:manifest
                Invoke-McpRawHttp -Url $using:url -Body $using:body -Headers $using:headers
            }
        }
        $answers = @($jobs | Wait-Job -Timeout 30 | Receive-Job)
        $jobs | Remove-Job -Force
        $answers.Count | Should -Be 3
        @($answers | ForEach-Object { $_.Status }) | Should -Be @(200, 200, 200)
        $texts = @($answers | ForEach-Object { $_.Json['result']['content'][0]['text'] })
        $texts | Should -Contain $first.Id
        $texts | Should -Contain $second.Id
        $texts | Should -Contain 'modern'
    }
}

Describe 'Session limits' -Tag 'Integration' {
    It 'refuses sessions beyond -MaxSessions and ends idle sessions after -SessionIdleTimeoutSeconds' {
        $server = New-McpServer -Name 'limits' -Version '1'
        Register-McpTool -Name 'echo' -ScriptBlock { param([string] $Text) $Text } -Server $server
        $handle = Start-McpTestHttpServer -Server $server -Parameters @{ MaxSessions = 1; SessionIdleTimeoutSeconds = 1 }
        try {
            $session = Open-Legacy -Url $handle.Url
            $refused = Send-Legacy -Url $handle.Url -Body '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"raw","version":"1"}}}'
            $refused.Status | Should -Be 503
            Start-Sleep -Seconds 3
            (Send-Legacy -Url $handle.Url -SessionId $session.Id -Body '{"jsonrpc":"2.0","id":1,"method":"ping"}').Status | Should -Be 404
            $null = Open-Legacy -Url $handle.Url
        } finally {
            Stop-McpTestHttpServer -Handle $handle
        }
    }

    It 'keeps a modern-only server free of sessions' {
        $server = New-McpServer -Name 'modern' -Version '1' -SupportedVersions '2026-07-28'
        $handle = Start-McpTestHttpServer -Server $server
        try {
            $answer = Send-Legacy -Url $handle.Url -Body '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"raw","version":"1"}}}'
            $answer.Status | Should -Be 400
            $answer.Json['error']['code'] | Should -Be -32022
            $answer.Json['error']['data']['supported'] | Should -Be @('2026-07-28')
            $answer.Headers.ContainsKey('Mcp-Session-Id') | Should -BeFalse
            (Invoke-McpRawHttp -Url $handle.Url -Method GET -Body $null -Headers @{ Accept = 'text/event-stream'; 'Mcp-Session-Id' = 'x' }).Status | Should -Be 405
            (Invoke-McpRawHttp -Url $handle.Url -Method DELETE -Body $null -Headers @{ 'Mcp-Session-Id' = 'x' }).Status | Should -Be 405
        } finally {
            Stop-McpTestHttpServer -Handle $handle
        }
    }
}
