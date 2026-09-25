[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

# The client against servers of the legacy revisions: era detection, the initialize handshake, answers to
# server-initiated requests through the callbacks, session-wide logging, unsolicited notifications, the session
# lifecycle over Streamable HTTP (session id, re-initialization after expiry, DELETE), resumption of an
# interrupted response stream, and the compatibility matrix of the versioning page.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force

    function script:New-TestServer {
        param([string[]] $SupportedVersions, [string] $Name = 'legacy-target')
        $server = New-McpServer -Name $Name -Version '3.1.0' -Instructions 'Legacy target.' -SupportedVersions $SupportedVersions -RequestTimeoutSeconds 30
        Register-McpTool -Name 'echo' -ScriptBlock { param([string] $Text) $Text } -Server $server
        Register-McpTool -Name 'ask' -ScriptBlock {
            param($Context)
            $answer = Request-McpElicitation -Context $Context -Key 'name' -Message 'Your name?' -Schema @{ name = @{ type = 'string' } }
            if ($answer.Accepted) { "Hello, $($answer.Content.name)!" } else { $answer.Action }
        } -Server $server
        Register-McpTool -Name 'sample' -ScriptBlock {
            param($Context)
            "model: $((Request-McpSampling -Context $Context -Key 's' -Messages 'hi' -MaxTokens 5).Text)"
        } -Server $server
        Register-McpTool -Name 'roots' -ScriptBlock { param($Context) @(Request-McpRoot -Context $Context -Key 'r' | ForEach-Object Uri) -join ',' } -Server $server
        Register-McpTool -Name 'chatty' -ScriptBlock {
            param($Context)
            Write-McpLog -Context $Context -Level debug -Message 'debug line'
            Write-McpLog -Context $Context -Level warning -Message 'warning line'
            'done'
        } -Server $server
        Register-McpTool -Name 'touch' -ScriptBlock { param([string] $Uri, $Context) Send-McpResourceUpdated -Context $Context -Uri $Uri; 'touched' } -Server $server
        Register-McpResource -Uri 'test://doc' -Name 'doc' -Content 'document' -Server $server
        Register-McpPrompt -Name 'greet' -Description 'Greets.' -ScriptBlock { param([string] $Who = 'you') "Hi $Who" } -Server $server
        $server
    }

    $script:callbacks = @{
        OnElicitation = { param($Request) @{ name = "legacy-$($Request.Mode)" } }
        OnSampling    = { 'sampled' }
        OnRoots       = { @('file:///one', 'file:///two') }
    }
}

Describe 'Legacy sessions of the client in memory' -Tag 'Integration' {
    BeforeAll {
        $script:legacyServer = New-TestServer -SupportedVersions '2025-11-25', '2025-06-18'
        $script:session = Connect-McpServer -Server $script:legacyServer @script:callbacks -ConnectTimeoutSeconds 10
    }

    AfterAll {
        if ($script:session) { Disconnect-McpServer -Session $script:session }
    }

    It 'detects the legacy server and negotiates with initialize' {
        $script:session.Era | Should -Be 'Legacy'
        $script:session.ProtocolVersion | Should -Be '2025-11-25'
        $info = Get-McpServerInfo -Session $script:session
        $info.Name | Should -Be 'legacy-target'
        $info.Version | Should -Be '3.1.0'
        $info.Instructions | Should -Be 'Legacy target.'
        $info.SupportedVersions | Should -Be @('2025-11-25')
        $info.Capabilities.Contains('logging') | Should -BeTrue
    }

    It 'lists and calls tools, reads resources and renders prompts' {
        @(Get-McpTool -Session $script:session | ForEach-Object Name) | Should -Contain 'echo'
        $result = Invoke-McpTool -Name 'echo' -Arguments @{ Text = 'legacy wire' } -Session $script:session
        $result.Text | Should -Be 'legacy wire'
        $result.ResultType | Should -Be 'complete'
        (Read-McpResource -Uri 'test://doc' -Session $script:session).Text | Should -Be 'document'
        Read-McpResource -Uri 'test://none' -Session $script:session -ErrorAction SilentlyContinue -ErrorVariable missing | Should -BeNullOrEmpty
        # -ErrorVariable also collects the errors the module catches internally; the reported one is ObjectNotFound.
        $notFound = @($missing | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -and $_.CategoryInfo.Category -eq 'ObjectNotFound' })
        $notFound.Count | Should -Be 1
        $notFound[0].Exception.InnerException.Code | Should -Be -32002
        (Invoke-McpPrompt -Name 'greet' -Arguments @{ Who = 'Ada' } -Session $script:session).Text | Should -Be 'Hi Ada'
    }

    It 'answers the elicitation, sampling and roots requests of the server with the callbacks' {
        (Invoke-McpTool -Name 'ask' -Session $script:session).Text | Should -Be 'Hello, legacy-form!'
        (Invoke-McpTool -Name 'sample' -Session $script:session).Text | Should -Be 'model: sampled'
        (Invoke-McpTool -Name 'roots' -Session $script:session).Text | Should -Be 'file:///one,file:///two'
    }

    It 'sets the log level with logging/setLevel and receives the log notifications' {
        $script:session.Log.Clear()
        $null = Invoke-McpTool -Name 'chatty' -Session $script:session
        $script:session.Log.Count | Should -Be 0
        Set-McpLogLevel -Level warning -Session $script:session
        $script:session.LegacyLogLevel | Should -Be 'warning'
        $null = Invoke-McpTool -Name 'chatty' -Session $script:session
        @($script:session.Log | ForEach-Object Data) | Should -Be @('warning line')
        $null = Invoke-McpTool -Name 'chatty' -Session $script:session -LogLevel debug
        $script:session.LegacyLogLevel | Should -Be 'debug'
        @($script:session.Log | ForEach-Object Data) | Should -Contain 'debug line'
    }

    It 'delivers list changes and resource updates to subscriptions and invalidates the cache' {
        $subscription = Register-McpSubscription -ToolsListChanged -ResourceUri 'test://doc' -Session $script:session
        try {
            $subscription.State | Should -Be 'Open'
            $subscription.Honoured['toolsListChanged'] | Should -BeTrue
            $null = Get-McpTool -Session $script:session
            $null = Send-McpToolListChanged -Server $script:legacyServer
            $changed = Receive-McpNotification -Subscription $subscription -TimeoutSeconds 10
            $changed.Method | Should -Be 'notifications/tools/list_changed'
            $script:session.Cache.ContainsKey('tools/list') | Should -BeFalse
            $null = Invoke-McpTool -Name 'touch' -Arguments @{ Uri = 'test://doc' } -Session $script:session
            $updated = Receive-McpNotification -Subscription $subscription -TimeoutSeconds 10
            $updated.Uri | Should -Be 'test://doc'
        } finally {
            Unregister-McpSubscription -Subscription $subscription -Confirm:$false
        }
    }
}

Describe 'Compatibility matrix' -Tag 'Integration' {
    It 'client <ClientEra> against a <ServerKind> server: <Expected>' -ForEach @(
        @{ ClientEra = 'Auto'; ServerKind = 'modern-only'; Expected = 'Modern' }
        @{ ClientEra = 'Auto'; ServerKind = 'legacy-only'; Expected = 'Legacy' }
        @{ ClientEra = 'Auto'; ServerKind = 'dual-era'; Expected = 'Modern' }
        @{ ClientEra = 'Modern'; ServerKind = 'modern-only'; Expected = 'Modern' }
        @{ ClientEra = 'Modern'; ServerKind = 'legacy-only'; Expected = 'fails' }
        @{ ClientEra = 'Modern'; ServerKind = 'dual-era'; Expected = 'Modern' }
        @{ ClientEra = 'Legacy'; ServerKind = 'modern-only'; Expected = 'fails' }
        @{ ClientEra = 'Legacy'; ServerKind = 'legacy-only'; Expected = 'Legacy' }
        @{ ClientEra = 'Legacy'; ServerKind = 'dual-era'; Expected = 'Legacy' }
    ) {
        $versions = switch ($ServerKind) {
            'modern-only' { @('2026-07-28') }
            'legacy-only' { @('2025-11-25', '2025-06-18') }
            default { @('2026-07-28', '2025-11-25', '2025-06-18') }
        }
        $server = New-TestServer -SupportedVersions $versions -Name "matrix-$ServerKind"
        if ($Expected -eq 'fails') {
            { Connect-McpServer -Server $server -Era $ClientEra -ConnectTimeoutSeconds 10 } | Should -Throw
            return
        }
        $session = Connect-McpServer -Server $server -Era $ClientEra -ConnectTimeoutSeconds 10
        try {
            $session.Era | Should -Be $Expected
            (Invoke-McpTool -Name 'echo' -Arguments @{ Text = 'matrix' } -Session $session).Text | Should -Be 'matrix'
        } finally {
            Disconnect-McpServer -Session $session
        }
    }

    It 'names the versions of a modern-only server when a legacy client is refused' {
        $server = New-TestServer -SupportedVersions '2026-07-28' -Name 'refusing'
        try {
            $null = Connect-McpServer -Server $server -Era Legacy -ConnectTimeoutSeconds 10
            throw 'expected a failure'
        } catch [McpProtocolException] {
            $_.Exception.Code | Should -Be -32022
            $_.Exception.Data['supported'] | Should -Be @('2026-07-28')
        }
    }

    It 'requests a legacy version given with -ProtocolVersion' {
        $server = New-TestServer -SupportedVersions '2026-07-28', '2025-11-25', '2025-06-18' -Name 'versioned'
        $session = Connect-McpServer -Server $server -Era Legacy -ProtocolVersion '2025-06-18' -ConnectTimeoutSeconds 10
        try {
            $session.ProtocolVersion | Should -Be '2025-06-18'
        } finally {
            Disconnect-McpServer -Session $session
        }
        { Connect-McpServer -Server $server -Era Modern -ProtocolVersion '2025-06-18' } | Should -Throw -ExpectedMessage '*legacy revision*'
    }
}

Describe 'Legacy sessions of the client over Streamable HTTP' -Tag 'Integration' {
    BeforeAll {
        $script:httpServer = New-TestServer -SupportedVersions '2025-11-25' -Name 'legacy-http'
        $script:handle = Start-McpTestHttpServer -Server $script:httpServer -Parameters @{ KeepAliveSeconds = 1 }
    }

    AfterAll {
        if ($script:handle) { Stop-McpTestHttpServer -Handle $script:handle }
    }

    It 'detects the legacy server, keeps the session id and answers requests on the response stream' {
        $session = Connect-McpServer -Url $script:handle.Url @script:callbacks -ConnectTimeoutSeconds 10
        try {
            $session.Era | Should -Be 'Legacy'
            $session.SessionId | Should -Not -BeNullOrEmpty
            (Invoke-McpTool -Name 'echo' -Arguments @{ Text = 'over http' } -Session $session).Text | Should -Be 'over http'
            (Invoke-McpTool -Name 'ask' -Session $session).Text | Should -Be 'Hello, legacy-form!'
            $null = Invoke-McpTool -Name 'chatty' -Session $session -LogLevel warning
            @($session.Log | ForEach-Object Data) | Should -Be @('warning line')
        } finally {
            Disconnect-McpServer -Session $session
        }
        # DELETE ended the session on the server.
        $gone = Invoke-McpRawHttp -Url $script:handle.Url -Body '{"jsonrpc":"2.0","id":1,"method":"ping"}' -Headers @{ 'Mcp-Session-Id' = $session.SessionId }
        $gone.Status | Should -Be 404
    }

    It 'receives notifications on the GET stream of the session' {
        $session = Connect-McpServer -Url $script:handle.Url -ConnectTimeoutSeconds 10
        try {
            # The session opened its GET stream after initialize.
            $subscription = Register-McpSubscription -ToolsListChanged -Session $session
            $deadline = [datetime]::UtcNow.AddSeconds(10)
            while ($session.LegacyStream.Status -ne 'Open' -and [datetime]::UtcNow -lt $deadline) {
                Invoke-McpInModule { param($s) Invoke-McpLegacyInbox -Session $s } $session
                Start-Sleep -Milliseconds 50
            }
            $session.LegacyStream.Status | Should -Be 'Open'
            $null = Send-McpToolListChanged -Server $script:httpServer
            (Receive-McpNotification -Subscription $subscription -TimeoutSeconds 10).Method | Should -Be 'notifications/tools/list_changed'
        } finally {
            Disconnect-McpServer -Session $session
        }
    }

    It 'initializes a new session when the server ended the old one' {
        $session = Connect-McpServer -Url $script:handle.Url -ConnectTimeoutSeconds 10
        try {
            $first = $session.SessionId
            # The server ends the session (as after an expiry): the next request gets 404.
            (Invoke-McpRawHttp -Url $script:handle.Url -Method DELETE -Body $null -Headers @{ 'Mcp-Session-Id' = $first }).Status | Should -Be 200
            (Invoke-McpTool -Name 'echo' -Arguments @{ Text = 'again' } -Session $session).Text | Should -Be 'again'
            $session.SessionId | Should -Not -Be $first
        } finally {
            Disconnect-McpServer -Session $session
        }
    }

    It 'remembers the era of the endpoint for the next connection' {
        $cached = Invoke-McpInModule { param($u) $v = $null; $null = $script:McpClientEraCache.TryGetValue($u, [ref] $v); $v } ([uri] $script:handle.Url).AbsoluteUri
        $cached | Should -Be 'Legacy'
    }
}

Describe 'Resumption of an interrupted response stream' -Tag 'Integration' {
    It 'reconnects with GET and Last-Event-ID after the announced retry time and reads the response there' {
        $port = Get-McpFreeTcpPort
        $prefix = "http://127.0.0.1:$port/"
        $log = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $stop = [System.Collections.Concurrent.ConcurrentDictionary[string, bool]]::new()
        $mock = Start-ThreadJob -ScriptBlock {
            $listener = [System.Net.HttpListener]::new()
            $listener.Prefixes.Add($using:prefix)
            $listener.Start()
            $log = $using:log
            $stop = $using:stop
            $pendingId = $null
            try {
                $task = $null
                while (-not $stop.ContainsKey('stop')) {
                    if ($null -eq $task) { $task = $listener.GetContextAsync() }
                    if (-not $task.Wait(200)) { continue }
                    $context = $task.Result
                    $task = $null
                    $request = $context.Request
                    $response = $context.Response
                    $body = if ($request.HasEntityBody) { [System.IO.StreamReader]::new($request.InputStream).ReadToEnd() } else { '' }
                    $log.Enqueue("$($request.HttpMethod) $($request.Headers['Last-Event-ID']) $body")
                    $write = {
                        param($status, $type, $text, $headers)
                        $response.StatusCode = $status
                        if ($headers) { foreach ($key in $headers.Keys) { $response.AddHeader($key, $headers[$key]) } }
                        if ($type) { $response.ContentType = $type }
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
                        $response.ContentLength64 = $bytes.Length
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $response.Close()
                    }
                    if ($request.HttpMethod -eq 'GET') {
                        if ($request.Headers['Last-Event-ID'] -ne 'ev-1') { & $write 405 $null '' $null; continue }
                        & $write 200 'text/event-stream' "id: ev-2`ndata: {`"jsonrpc`":`"2.0`",`"id`":$pendingId,`"result`":{`"content`":[{`"type`":`"text`",`"text`":`"resumed`"}]}}`n`n" $null
                        continue
                    }
                    if ($request.HttpMethod -eq 'DELETE') { & $write 405 $null '' $null; continue }
                    $message = $body | ConvertFrom-Json -AsHashtable
                    switch ($message['method']) {
                        'initialize' {
                            & $write 200 'application/json' "{`"jsonrpc`":`"2.0`",`"id`":$($message['id']),`"result`":{`"protocolVersion`":`"2025-03-26`",`"capabilities`":{`"tools`":{}},`"serverInfo`":{`"name`":`"mock`",`"version`":`"1`"}}}" @{ 'Mcp-Session-Id' = 'mock-session' }
                        }
                        'tools/call' {
                            $pendingId = $message['id']
                            # A priming event with an id and a retry time, then the stream ends without the response.
                            & $write 200 'text/event-stream' "id: ev-1`nretry: 300`ndata:`n`n" $null
                        }
                        { $null -eq $message['id'] } { & $write 202 $null '' $null }
                        default {
                            & $write 400 'application/json' "{`"jsonrpc`":`"2.0`",`"id`":$($message['id']),`"error`":{`"code`":-32600,`"message`":`"not initialized`"}}" $null
                        }
                    }
                }
            } finally {
                $listener.Stop()
                $listener.Close()
            }
        }
        try {
            Start-Sleep -Milliseconds 300
            $session = Connect-McpServer -Url $prefix -ConnectTimeoutSeconds 10
            try {
                $session.Era | Should -Be 'Legacy'
                $session.ProtocolVersion | Should -Be '2025-03-26'
                $session.SessionId | Should -Be 'mock-session'
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                (Invoke-McpTool -Name 'anything' -Session $session -TimeoutSeconds 10).Text | Should -Be 'resumed'
                $watch.ElapsedMilliseconds | Should -BeGreaterOrEqual 250
            } finally {
                Disconnect-McpServer -Session $session
            }
            $entries = @($log.ToArray())
            @($entries | Where-Object { $_ -like 'GET ev-1*' }).Count | Should -Be 1
        } finally {
            $stop['stop'] = $true
            $null = Wait-Job -Job $mock -Timeout 10
            Remove-Job -Job $mock -Force
        }
    }
}

Describe 'Legacy session over stdio' -Tag 'Integration' {
    It 'speaks the initialize handshake with the example server when asked to' {
        $script = Join-Path (Get-McpRepositoryRoot) 'examples' 'echo-server.ps1'
        $environment = @{ MCP_MODULE_MANIFEST = (Get-McpBuiltModuleManifest) }
        $session = Connect-McpServer -Command (Get-McpPowerShellPath) -Arguments '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script -Environment $environment -Era Legacy -ConnectTimeoutSeconds 30
        try {
            $session.Era | Should -Be 'Legacy'
            $session.ProtocolVersion | Should -Be '2025-11-25'
            @(Get-McpTool -Session $session).Count | Should -BeGreaterThan 0
        } finally {
            Disconnect-McpServer -Session $session
        }
    }
}
