[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force

    function script:New-ListenServer {
        param([string] $Name = 'listen')
        $server = New-McpServer -Name $Name -Version '1.0.0' -RequestTimeoutSeconds 10
        Register-McpTool -Name 'trigger-tools' -Description 'Announces a tool list change.' -ScriptBlock { param($Context) Send-McpToolListChanged -Context $Context; 'ok' } -Server $server
        Register-McpTool -Name 'touch' -Description 'Announces a resource update.' -ScriptBlock { param([string] $Uri, $Context) Send-McpResourceUpdated -Context $Context -Uri $Uri; 'touched' } -Server $server
        Register-McpResource -Uri 'test://doc' -Name 'doc' -Description 'A document.' -Content 'v1' -TtlMs 60000 -Server $server
        Register-McpPrompt -Name 'p' -Description 'A prompt.' -ScriptBlock { 'hi' } -Server $server
        $server
    }
    $script:meta = [ordered]@{ 'io.modelcontextprotocol/protocolVersion' = '2026-07-28'; 'io.modelcontextprotocol/clientCapabilities' = [ordered]@{} }
    $script:subscriptionKey = 'io.modelcontextprotocol/subscriptionId'
}

Describe 'subscriptions/listen on the wire' -Tag 'Integration' {
    BeforeAll {
        $script:rawServer = New-ListenServer -Name 'raw-listen'
        $script:pair = Invoke-McpInModule { New-McpInMemoryTransportPair }
        $script:background = Invoke-McpInModule { param($s, $e) Start-McpBackgroundServer -Server $s -Endpoint $e } -Parameters @{ s = $script:rawServer; e = $script:pair.Server }
        function script:Send-Raw {
            param([object] $Id, [string] $Method, [System.Collections.IDictionary] $Params = [ordered]@{})
            $all = [ordered]@{ _meta = $script:meta }
            foreach ($key in $Params.Keys) { $all[$key] = $Params[$key] }
            $message = [ordered]@{ jsonrpc = '2.0' }
            if ($null -ne $Id) { $message['id'] = $Id }
            $message['method'] = $Method
            $message['params'] = $all
            $line = Invoke-McpInModule { param($m) ConvertTo-McpJson -InputObject $m } -Parameters @{ m = $message }
            Invoke-McpInModule { param($t, $l) Send-McpTransportLine -Transport $t -Line $l } -Parameters @{ t = $script:pair.Client; l = $line }
        }
        function script:Receive-Raw {
            param([int] $TimeoutMs = 5000)
            $received = Invoke-McpInModule { param($t, $ms) Receive-McpTransportLine -Transport $t -TimeoutMs $ms } -Parameters @{ t = $script:pair.Client; ms = $TimeoutMs }
            if ($received.Status -ne 'Line') { return $null }
            Invoke-McpInModule { param($l) ConvertFrom-McpJson $l } -Parameters @{ l = $received.Line }
        }
    }

    AfterAll {
        Invoke-McpInModule { param($t) Close-McpTransport -Transport $t } -Parameters @{ t = $script:pair.Client }
        Invoke-McpInModule { param($b) Stop-McpBackgroundServer -Background $b } -Parameters @{ b = $script:background }
    }

    It 'acknowledges first, with the honoured filter and the subscription id' {
        Send-Raw -Id 'L1' -Method 'subscriptions/listen' -Params ([ordered]@{ notifications = [ordered]@{ toolsListChanged = $true; resourceSubscriptions = @('test://doc') } })
        $ack = Receive-Raw
        (Test-McpSpecShape -Definition 'SubscriptionsAcknowledgedNotification' -Instance $ack).IsValid | Should -BeTrue
        $ack['method'] | Should -Be 'notifications/subscriptions/acknowledged'
        $ack['params']['_meta'][$script:subscriptionKey] | Should -Be 'L1'
        $ack['params']['notifications']['toolsListChanged'] | Should -BeTrue
        $ack['params']['notifications']['resourceSubscriptions'] | Should -Be @('test://doc')
    }

    It 'delivers only what the filter asked for, tagged with the subscription id' {
        Send-Raw -Id 1 -Method 'tools/call' -Params ([ordered]@{ name = 'trigger-tools'; arguments = @{} })
        Send-Raw -Id 2 -Method 'tools/call' -Params ([ordered]@{ name = 'touch'; arguments = @{ Uri = 'test://doc/part' } })
        Send-Raw -Id 3 -Method 'tools/call' -Params ([ordered]@{ name = 'touch'; arguments = @{ Uri = 'test://other' } })
        $null = Send-McpPromptListChanged -Server $script:rawServer
        $messages = @(for ($i = 0; $i -lt 5; $i++) { Receive-Raw })
        $notifications = @($messages | Where-Object { $_.Contains('method') })
        @($notifications | ForEach-Object { $_['method'] }) | Should -Be @('notifications/tools/list_changed', 'notifications/resources/updated')
        foreach ($notification in $notifications) { $notification['params']['_meta'][$script:subscriptionKey] | Should -Be 'L1' }
        $notifications[1]['params']['uri'] | Should -Be 'test://doc/part'
        @($messages | Where-Object { $_.Contains('result') }).Count | Should -Be 3
        Receive-Raw -TimeoutMs 300 | Should -BeNullOrEmpty
    }

    It 'announces tools registered while the server runs, which are callable at once' {
        Register-McpTool -Name 'late' -Description 'Registered late.' -ScriptBlock { 'late ok' } -Server $script:rawServer
        (Receive-Raw)['method'] | Should -Be 'notifications/tools/list_changed'
        Send-Raw -Id 4 -Method 'tools/call' -Params ([ordered]@{ name = 'late'; arguments = @{} })
        (Receive-Raw)['result']['content'][0]['text'] | Should -Be 'late ok'
        Unregister-McpTool -Name 'late' -Server $script:rawServer -Confirm:$false
        (Receive-Raw)['method'] | Should -Be 'notifications/tools/list_changed'
    }

    It 'rejects a filter that is not an object and duplicate request ids' {
        Send-Raw -Id 'bad' -Method 'subscriptions/listen' -Params ([ordered]@{ notifications = 'all' })
        (Receive-Raw)['error']['code'] | Should -Be -32602
        Send-Raw -Id 'L1' -Method 'subscriptions/listen' -Params ([ordered]@{ notifications = [ordered]@{ toolsListChanged = $true } })
        (Receive-Raw)['error']['code'] | Should -Be -32600
    }

    It 'ends a subscription on notifications/cancelled without a response' {
        Send-Raw -Method 'notifications/cancelled' -Params ([ordered]@{ requestId = 'L1' })
        Start-Sleep -Milliseconds 200
        $null = Send-McpToolListChanged -Server $script:rawServer
        Receive-Raw -TimeoutMs 500 | Should -BeNullOrEmpty
    }

    It 'closes open subscriptions gracefully when the server stops' {
        Send-Raw -Id 'L2' -Method 'subscriptions/listen' -Params ([ordered]@{ notifications = [ordered]@{ promptsListChanged = $true } })
        (Receive-Raw)['params']['notifications']['promptsListChanged'] | Should -BeTrue
        Stop-McpServer -Server $script:rawServer
        $final = Receive-Raw
        (Test-McpSpecShape -Definition 'SubscriptionsListenResultResponse' -Instance $final).IsValid | Should -BeTrue
        $final['id'] | Should -Be 'L2'
        $final['result']['resultType'] | Should -Be 'complete'
        $final['result']['_meta'][$script:subscriptionKey] | Should -Be 'L2'
        $final['result']['_meta']['io.modelcontextprotocol/serverInfo']['name'] | Should -Be 'raw-listen'
    }
}

Describe 'Register-McpSubscription in memory' -Tag 'Integration' {
    BeforeAll {
        $script:memoryServer = New-ListenServer -Name 'memory-listen'
        $script:session = Connect-McpServer -Server $script:memoryServer
    }

    AfterAll {
        if ($script:session) { Disconnect-McpServer -Session $script:session }
    }

    It 'opens a subscription with the honoured subset' {
        $script:subscription = Register-McpSubscription -ToolsListChanged -ResourceUri 'test://doc' -Session $script:session
        $script:subscription.PSObject.TypeNames | Should -Contain 'Mcp.Subscription'
        $script:subscription.State | Should -Be 'Open'
        @($script:subscription.Honoured.Keys) | Should -Be @('toolsListChanged', 'resourceSubscriptions')
    }

    It 'receives notifications and invalidates the cache' {
        (Read-McpResource -Uri 'test://doc' -Session $script:session).Text | Should -Be 'v1'
        $script:session.Cache.ContainsKey('resources/read test://doc') | Should -BeTrue
        $null = Invoke-McpTool -Name 'touch' -Arguments @{ Uri = 'test://doc' } -Session $script:session
        $notifications = @(Receive-McpNotification -Subscription $script:subscription -TimeoutSeconds 5)
        $notifications.Count | Should -Be 1
        $notifications[0].PSObject.TypeNames | Should -Contain 'Mcp.Notification'
        $notifications[0].Method | Should -Be 'notifications/resources/updated'
        $notifications[0].Uri | Should -Be 'test://doc'
        $notifications[0].SubscriptionId | Should -Be $script:subscription.Id
        $script:session.Cache.ContainsKey('resources/read test://doc') | Should -BeFalse
    }

    It 'returns nothing when nothing arrived' {
        @(Receive-McpNotification -Session $script:session).Count | Should -Be 0
    }

    It 'runs -Action for each notification in the caller''s runspace' {
        $seen = [System.Collections.Generic.List[string]]::new()
        $withAction = Register-McpSubscription -ToolsListChanged -Action { param($Notification) $seen.Add($Notification.Method) } -Session $script:session
        Register-McpTool -Name 'dynamic' -Description 'Registered while subscribed.' -ScriptBlock { 'dynamic ok' } -Server $script:memoryServer
        $null = Receive-McpNotification -Subscription $withAction -TimeoutSeconds 2
        @($seen) | Should -Be @('notifications/tools/list_changed')
        (Invoke-McpTool -Name 'dynamic' -Session $script:session).Text | Should -Be 'dynamic ok'
        @(Get-McpTool -Session $script:session | ForEach-Object Name) | Should -Contain 'dynamic'
        Unregister-McpSubscription -Subscription $withAction
        $withAction.State | Should -Be 'Closed'
        # The other subscription got the change as well.
        @(Receive-McpNotification -Subscription $script:subscription -TimeoutSeconds 2 | ForEach-Object Method) | Should -Be @('notifications/tools/list_changed')
    }

    It 'ends subscriptions with Unregister-McpSubscription and on Disconnect-McpServer' {
        $other = Register-McpSubscription -PromptsListChanged -Session $script:session
        Unregister-McpSubscription -Subscription $script:subscription
        $script:subscription.State | Should -Be 'Closed'
        $null = Invoke-McpTool -Name 'trigger-tools' -Session $script:session
        @(Receive-McpNotification -Subscription $script:subscription -TimeoutSeconds 1).Count | Should -Be 0
        Disconnect-McpServer -Session $script:session
        $other.State | Should -Be 'Closed'
        $script:session = $null
    }

    It 'requires at least one notification type' {
        $session = Connect-McpServer -Server (New-ListenServer)
        try {
            { Register-McpSubscription -Session $session } | Should -Throw -ExpectedMessage '*at least one*'
        } finally {
            Disconnect-McpServer -Session $session
        }
    }
}

Describe 'subscriptions/listen over Streamable HTTP' -Tag 'Integration' {
    BeforeAll {
        $script:httpServer = New-ListenServer -Name 'http-listen'
        $script:handle = Start-McpTestHttpServer -Server $script:httpServer -Parameters @{ KeepAliveSeconds = 1 }
        function script:Open-RawListen {
            param([object] $Id, [System.Collections.IDictionary] $Filter)
            $handler = [System.Net.Http.SocketsHttpHandler]::new()
            $handler.UseProxy = $false
            $client = [System.Net.Http.HttpClient]::new($handler)
            $body = Invoke-McpInModule { param($m) ConvertTo-McpJson -InputObject $m } -Parameters @{ m = [ordered]@{ jsonrpc = '2.0'; id = $Id; method = 'subscriptions/listen'; params = [ordered]@{ _meta = $script:meta; notifications = $Filter } } }
            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $script:handle.Url)
            $request.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
            $null = $request.Headers.TryAddWithoutValidation('Accept', 'application/json, text/event-stream')
            $null = $request.Headers.TryAddWithoutValidation('MCP-Protocol-Version', '2026-07-28')
            $null = $request.Headers.TryAddWithoutValidation('Mcp-Method', 'subscriptions/listen')
            $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $sse = Invoke-McpInModule { param($s) New-McpSseReader -Stream $s } -Parameters @{ s = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult() }
            @{ Client = $client; Response = $response; Sse = $sse }
        }
        function script:Receive-RawEvent {
            param([hashtable] $Stream, [int] $TimeoutMs = 5000)
            $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
            while ([datetime]::UtcNow -lt $deadline) {
                $received = Invoke-McpInModule { param($s) Receive-McpSseEvent -Sse $s -TimeoutMs 250 } -Parameters @{ s = $Stream.Sse }
                if ($received.Status -eq 'Eof') { return $null }
                if ($received.Status -eq 'Event' -and $received.Data) { return Invoke-McpInModule { param($d) ConvertFrom-McpJson $d } -Parameters @{ d = $received.Data } }
            }
            $null
        }
        function script:Close-RawListen {
            param([hashtable] $Stream)
            $Stream.Response.Dispose()
            $Stream.Client.Dispose()
        }
    }

    AfterAll {
        if ($script:handle) { Stop-McpTestHttpServer -Handle $script:handle }
    }

    It 'answers with an SSE stream whose first event is the acknowledgement' {
        $stream = Open-RawListen -Id 7 -Filter ([ordered]@{ toolsListChanged = $true })
        try {
            $stream.Response.StatusCode | Should -Be 200
            $stream.Response.Content.Headers.ContentType.MediaType | Should -Be 'text/event-stream'
            $ack = Receive-RawEvent -Stream $stream
            $ack['method'] | Should -Be 'notifications/subscriptions/acknowledged'
            $ack['params']['_meta'][$script:subscriptionKey] | Should -Be 7
        } finally {
            Close-RawListen -Stream $stream
        }
    }

    It 'serves several parallel streams and drops the ones the client closed' {
        $first = Open-RawListen -Id 'a' -Filter ([ordered]@{ toolsListChanged = $true })
        $second = Open-RawListen -Id 'b' -Filter ([ordered]@{ toolsListChanged = $true })
        try {
            $null = Receive-RawEvent -Stream $first
            $null = Receive-RawEvent -Stream $second
            Close-RawListen -Stream $first
            $null = Send-McpToolListChanged -Server $script:httpServer
            $notification = Receive-RawEvent -Stream $second
            $notification['method'] | Should -Be 'notifications/tools/list_changed'
            $notification['params']['_meta'][$script:subscriptionKey] | Should -Be 'b'
            # The keep-alive (1 s) notices the closed stream.
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            while ($script:httpServer.State.Listeners.ContainsKey('s:a') -and $stopwatch.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 100 }
            $script:httpServer.State.Listeners.ContainsKey('s:a') | Should -BeFalse
        } finally {
            Close-RawListen -Stream $second
        }
    }

    It 'works through the client and ends gracefully when the server stops' {
        $session = Connect-McpServer -Url $script:handle.Url
        try {
            $subscription = Register-McpSubscription -ToolsListChanged -PromptsListChanged -Session $session
            $subscription.State | Should -Be 'Open'
            $null = Invoke-McpTool -Name 'trigger-tools' -Session $session
            @(Receive-McpNotification -Subscription $subscription -TimeoutSeconds 5 | ForEach-Object Method) | Should -Be @('notifications/tools/list_changed')
            Stop-McpTestHttpServer -Handle $script:handle
            $script:handle = $null
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            while ($subscription.State -eq 'Open' -and $stopwatch.Elapsed.TotalSeconds -lt 5) { $null = Receive-McpNotification -Session $session -TimeoutSeconds 0.2 }
            $subscription.State | Should -Be 'Closed'
            $subscription.Reconnects | Should -Be 0
        } finally {
            Disconnect-McpServer -Session $session
        }
    }
}
