# Client side of subscriptions/listen. Notifications arrive while no request is in progress, so they are read
# in the background: over stdio and in memory a pump runspace moves every line of the transport into an inbox
# (the request path then reads from the inbox); over Streamable HTTP each subscription has its own POST whose
# SSE stream a reader runspace reads, reconnecting after an abrupt close. User callbacks (-Action) and cache
# invalidation run in the caller's runspace whenever a client command pumps the inbox.

function New-McpClientBackgroundRunspace {
    <#
    .SYNOPSIS
        Starts a module function in a new runspace (with this module imported); returns the handles.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal background reader.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $FunctionName,

        [Parameter(Mandatory)]
        [hashtable] $Parameters
    )

    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    if ($IsWindows) { $sessionState.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass }
    $sessionState.ImportPSModule([string[]] @($script:McpModuleManifestPath))
    $runspace = [runspacefactory]::CreateRunspace($sessionState)
    $runspace.Open()
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace
    $null = $powershell.AddScript('param($Name, $Parameters) & (Get-Module -Name ModelContextProtocol) { param($n, $p) & $n @p } $Name $Parameters').AddArgument($FunctionName).AddArgument($Parameters)
    @{
        PowerShell = $powershell
        Handle     = $powershell.BeginInvoke()
        Runspace   = $runspace
    }
}

function Stop-McpClientBackgroundRunspace {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal background reader.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [hashtable] $Background,

        [int] $TimeoutMs = 5000
    )

    if ($null -eq $Background) { return }
    try {
        if (-not $Background.Handle.AsyncWaitHandle.WaitOne($TimeoutMs)) { $null = $Background.PowerShell.BeginStop($null, $null) }
    } catch {
        Write-Debug 'Stopping a background reader failed.'
    }
    try { $Background.PowerShell.Dispose() } catch { Write-Debug 'Disposing a background reader failed.' }
    try { $Background.Runspace.Dispose() } catch { Write-Debug 'Disposing a background runspace failed.' }
}

function Invoke-McpTransportPump {
    <#
    .SYNOPSIS
        Background loop: moves every line of a line transport into its inbox until end of stream or stop.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Transport
    )

    $inbox = $Transport.LineInbox
    try {
        while (-not $Transport.PumpStop) {
            $task = Read-McpTransportLineAsync -Transport $Transport
            $done = $false
            try { $done = $task.Wait(250) } catch [System.AggregateException] { $done = $true }
            if (-not $done) { continue }
            $line = $null
            try { $line = Complete-McpTransportRead -Transport $Transport -Task $task } catch { $line = $null }
            if ($null -eq $line) { break }
            $inbox.Add($line)
        }
    } finally {
        $inbox.CompleteAdding()
    }
}

function Start-McpTransportPump {
    <#
    .SYNOPSIS
        Switches a stdio or in-memory session to background reading: from now on requests read their responses from the inbox.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal background reader.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Transport
    )

    if ($Transport.ContainsKey('LineInbox') -and $null -ne $Transport.LineInbox) { return }
    $Transport.PumpStop = $false
    $Transport.LineInbox = [System.Collections.Concurrent.BlockingCollection[string]]::new()
    $Transport.Pump = New-McpClientBackgroundRunspace -FunctionName 'Invoke-McpTransportPump' -Parameters @{ Transport = $Transport }
}

function Stop-McpTransportPump {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal background reader.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Transport
    )

    if (-not $Transport.ContainsKey('Pump') -or $null -eq $Transport.Pump) { return }
    $Transport.PumpStop = $true
    Stop-McpClientBackgroundRunspace -Background $Transport.Pump -TimeoutMs 2000
    $Transport.Pump = $null
}

function Invoke-McpHttpListenLoop {
    <#
    .SYNOPSIS
        Background loop of one HTTP subscription: posts subscriptions/listen, reads the SSE stream into the session inbox and reconnects after an abrupt close.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [pscustomobject] $Subscription
    )

    $inbox = $Session.Inbox
    $push = { param($item) $item['Subscription'] = $Subscription.Id; $inbox.Enqueue($item) }
    $attempt = 0
    while (-not $Subscription.StopRequested) {
        $id = $Subscription.CurrentId
        $params = [ordered]@{ _meta = (New-McpClientRequestMeta -Session $Session); notifications = $Subscription.Requested }
        $json = ConvertTo-McpJson -InputObject (New-McpRequest -Id $id -Method 'subscriptions/listen' -Params $params)
        $message = New-McpHttpRequestMessage -Session $Session -Method 'subscriptions/listen' -Params $params -Json $json
        $response = $null
        $closed = $false
        $failed = $null
        try {
            $sendTask = $Session.Transport.Client.SendAsync($message, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $Subscription.Cts.Token)
            while (-not $sendTask.IsCompleted -and -not $Subscription.StopRequested) { $null = $sendTask.Wait(250) }
            if ($Subscription.StopRequested) { break }
            $failure = Get-McpTaskFailure -Task $sendTask
            if ($null -ne $failure) { throw $failure }
            $response = $sendTask.Result
            $mediaType = if ($null -ne $response.Content.Headers.ContentType) { $response.Content.Headers.ContentType.MediaType } else { $null }
            if ($mediaType -ne 'text/event-stream') {
                # A JSON answer ends the subscription: an error (for example -32601) or an immediate result.
                & $push @{ Kind = 'Message'; Json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
                $closed = $true
            } else {
                $sse = New-McpSseReader -Stream ($response.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
                try {
                    while (-not $Subscription.StopRequested) {
                        $received = Receive-McpSseEvent -Sse $sse -TimeoutMs 250
                        if ($received.Status -eq 'Timeout') { continue }
                        if ($received.Status -eq 'Eof') { break }
                        if ($null -ne $received.Event -and $received.Event -ne 'message') { continue }
                        $attempt = 0
                        & $push @{ Kind = 'Message'; Json = $received.Data }
                        # The final response of the listen request is the graceful close.
                        if ($received.Data -match '"result"\s*:' -or $received.Data -match '"error"\s*:') {
                            $parsed = $null
                            try { $parsed = ConvertFrom-McpJson -Json $received.Data } catch { $parsed = $null }
                            if ($parsed -is [System.Collections.IDictionary] -and $parsed.Contains('id') -and [string] $parsed['id'] -ceq [string] $id) { $closed = $true; break }
                        }
                    }
                } finally {
                    try { $sse.Reader.Dispose() } catch { Write-Debug 'Disposing the SSE reader failed.' }
                }
            }
        } catch {
            $failed = $_.Exception
        } finally {
            if ($null -ne $response) { try { $response.Dispose() } catch { Write-Debug 'Disposing the listen response failed.' } }
            $message.Dispose()
        }
        if ($closed -or $Subscription.StopRequested) { break }
        $attempt++
        if ($Subscription.NoReconnect -or $attempt -gt 5) {
            & $push @{ Kind = 'Closed'; Reason = if ($null -ne $failed) { $failed.Message } else { 'The server closed the stream.' } }
            break
        }
        $delay = [math]::Min(16, [math]::Pow(2, $attempt - 1))
        $until = [datetime]::UtcNow.AddSeconds($delay)
        while ([datetime]::UtcNow -lt $until -and -not $Subscription.StopRequested) { Start-Sleep -Milliseconds 100 }
        if ($Subscription.StopRequested) { break }
        $newId = "$($Subscription.Id)-r$($Subscription.Reconnects + 1)"
        & $push @{ Kind = 'Reconnect'; NewId = $newId }
        $Subscription.CurrentId = $newId
    }
}

function Receive-McpSubscriptionNotification {
    <#
    .SYNOPSIS
        Handles a notification tagged with a subscription id: the acknowledgement opens the subscription; list-changed and resource-updated notifications invalidate the cache and are queued for the subscription.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [pscustomobject] $Subscription,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Message
    )

    $method = [string] $Message['method']
    $params = if ($Message['params'] -is [System.Collections.IDictionary]) { $Message['params'] } else { [ordered]@{} }
    switch ($method) {
        'notifications/subscriptions/acknowledged' {
            $Subscription.Honoured = if ($params['notifications'] -is [System.Collections.IDictionary]) { $params['notifications'] } else { [ordered]@{} }
            $Subscription.State = 'Open'
            return
        }
        'notifications/tools/list_changed' { $Session.Cache.Remove('tools/list') }
        'notifications/prompts/list_changed' { $Session.Cache.Remove('prompts/list') }
        'notifications/resources/list_changed' { $Session.Cache.Remove('resources/list'); $Session.Cache.Remove('resources/templates/list') }
        'notifications/resources/updated' {
            $uri = [string] $params['uri']
            foreach ($key in @($Session.Cache.Keys)) {
                if ($key -ceq "resources/read $uri" -or $key.StartsWith("resources/read $uri/", [System.StringComparison]::Ordinal)) { $Session.Cache.Remove($key) }
            }
        }
    }
    $notification = [pscustomobject]@{
        PSTypeName     = 'Mcp.Notification'
        Method         = $method
        Uri            = if ($method -eq 'notifications/resources/updated') { [string] $params['uri'] } else { $null }
        SubscriptionId = $Subscription.Id
        Params         = $params
        Received       = [datetime]::UtcNow
    }
    if ($null -ne $Subscription.Action) {
        $Session.PendingEvents.Add(@{ Subscription = $Subscription; Notification = $notification })
    } else {
        $Subscription.Notifications.Enqueue($notification)
    }
}

function Get-McpClientSubscriptionById {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [AllowNull()]
        [object] $Id
    )

    if ($null -eq $Id -or -not $Session.PSObject.Properties['SubscriptionIds']) { return $null }
    $key = [string] $Id
    if ($Session.SubscriptionIds.ContainsKey($key)) { return $Session.SubscriptionIds[$key] }
    $null
}

function Invoke-McpClientStrayMessage {
    <#
    .SYNOPSIS
        Handles a message that answers no pending request: the final response (or error) of a listen request, or a notification.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Message
    )

    $kind = Get-McpMessageKind -Message $Message
    if ($kind -eq 'Notification') {
        Invoke-McpClientNotificationHandler -Session $Session -Message $Message
        return
    }
    if ($kind -notin @('Response', 'ErrorResponse')) { return }
    $subscription = Get-McpClientSubscriptionById -Session $Session -Id $(if ($Message.Contains('id')) { $Message['id'] } else { $null })
    if ($null -eq $subscription) {
        Write-Debug "Ignoring a response with id $($Message['id'])."
        return
    }
    if ($kind -eq 'ErrorResponse') {
        $errorObject = $Message['error']
        $subscription.Error = [McpProtocolException]::new([int] $errorObject['code'], [string] $errorObject['message'], $(if ($errorObject.Contains('data')) { $errorObject['data'] } else { $null }))
        $subscription.State = 'Failed'
    } else {
        $subscription.State = 'Closed'
    }
    Remove-McpClientSubscriptionId -Session $Session -Subscription $subscription
}

function Remove-McpClientSubscriptionId {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal subscription bookkeeping.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [pscustomobject] $Subscription
    )

    foreach ($key in @($Session.SubscriptionIds.Keys)) {
        if ([object]::ReferenceEquals($Session.SubscriptionIds[$key], $Subscription)) { $Session.SubscriptionIds.Remove($key) }
    }
}

function Invoke-McpClientEventPump {
    <#
    .SYNOPSIS
        Processes what the background readers received and runs the -Action callbacks of subscriptions, in the caller's runspace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session
    )

    if (-not $Session.PSObject.Properties['Inbox'] -or $Session.Closed) { return }
    $transport = $Session.Transport
    if ($transport.ContainsKey('LineInbox') -and $null -ne $transport.LineInbox) {
        $line = $null
        while ($transport.LineInbox.TryTake([ref] $line, 0)) {
            $message = $null
            try { $message = ConvertFrom-McpJson -Json $line } catch { continue }
            if ($message -is [System.Collections.IDictionary]) { Invoke-McpClientStrayMessage -Session $Session -Message $message }
        }
        if ($transport.LineInbox.IsCompleted) {
            foreach ($subscription in @($Session.Subscriptions.Values)) {
                if ($subscription.State -in @('Opening', 'Open')) { $subscription.State = 'Closed' }
            }
        }
    }
    $item = $null
    while ($Session.Inbox.TryDequeue([ref] $item)) {
        $subscription = $Session.Subscriptions[[string] $item.Subscription]
        if ($null -eq $subscription) { continue }
        switch ($item.Kind) {
            'Message' {
                $message = $null
                try { $message = ConvertFrom-McpJson -Json $item.Json } catch { $message = $null }
                if ($message -is [System.Collections.IDictionary]) { Invoke-McpClientStrayMessage -Session $Session -Message $message }
            }
            'Reconnect' {
                $subscription.Reconnects++
                $subscription.State = 'Reconnecting'
                $Session.SubscriptionIds[[string] $item.NewId] = $subscription
            }
            'Closed' {
                $subscription.State = 'Closed'
                $subscription.Error = $item.Reason
                Remove-McpClientSubscriptionId -Session $Session -Subscription $subscription
            }
        }
    }
    while ($Session.PendingEvents.Count -gt 0) {
        $pending = $Session.PendingEvents[0]
        $Session.PendingEvents.RemoveAt(0)
        try {
            $null = & $pending.Subscription.Action $pending.Notification
        } catch {
            Write-Warning "The subscription action failed: $($_.Exception.Message)"
        }
    }
}

function Close-McpClientSubscription {
    <#
    .SYNOPSIS
        Ends a subscription: cancels the listen request on stdio, closes the stream over HTTP, and stops its reader.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The caller owns the ShouldProcess decision.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [pscustomobject] $Subscription
    )

    $Subscription.StopRequested = $true
    if ($Session.Kind -eq 'Http') {
        try { $Subscription.Cts.Cancel() } catch { Write-Debug 'Cancelling the listen request failed.' }
        Stop-McpClientBackgroundRunspace -Background $Subscription.Reader -TimeoutMs 5000
        $Subscription.Reader = $null
        try { $Subscription.Cts.Dispose() } catch { Write-Debug 'Disposing the token source failed.' }
    } elseif ($Subscription.State -in @('Opening', 'Open') -and -not $Session.Closed) {
        try {
            Send-McpClientNotification -Session $Session -Method 'notifications/cancelled' -Params ([ordered]@{ requestId = $Subscription.CurrentId; reason = 'unsubscribed' })
        } catch {
            Write-Debug 'Cancelling the listen request failed.'
        }
    }
    if ($Subscription.State -ne 'Failed') { $Subscription.State = 'Closed' }
    Remove-McpClientSubscriptionId -Session $Session -Subscription $Subscription
    $Session.Subscriptions.Remove([string] $Subscription.Id)
}

function Wait-McpClientEvent {
    <#
    .SYNOPSIS
        Pumps the session's background input until a condition holds or a timeout passes; returns whether the condition holds.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [scriptblock] $Condition,

        [int] $TimeoutMs = 0
    )

    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        Invoke-McpClientEventPump -Session $Session
        if (& $Condition) { return $true }
        $remaining = ($deadline - [datetime]::UtcNow).TotalMilliseconds
        if ($remaining -le 0 -or $Session.Closed) { return $false }
        $slice = [int] [math]::Max(1, [math]::Min(100, $remaining))
        $transport = $Session.Transport
        if ($transport.ContainsKey('LineInbox') -and $null -ne $transport.LineInbox) {
            $received = Receive-McpTransportLine -Transport $transport -TimeoutMs $slice
            if ($received.Status -eq 'Line') {
                $message = $null
                try { $message = ConvertFrom-McpJson -Json $received.Line } catch { $message = $null }
                if ($message -is [System.Collections.IDictionary]) { Invoke-McpClientStrayMessage -Session $Session -Message $message }
            } elseif ($received.Status -eq 'Eof') {
                Invoke-McpClientEventPump -Session $Session
                return [bool] (& $Condition)
            }
        } else {
            Start-Sleep -Milliseconds $slice
        }
    }
}
