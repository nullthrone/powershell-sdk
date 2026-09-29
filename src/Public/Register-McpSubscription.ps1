function Register-McpSubscription {
    <#
    .SYNOPSIS
        Opens a subscriptions/listen stream: list-changed notifications of tools, prompts and resources and updates of resources.
    .DESCRIPTION
        The server acknowledges the subscription with the subset of the requested notification types it honours
        (the Honoured property); requested types the server does not support are dropped silently. Received
        notifications invalidate the session's result cache (a list-changed notification the cached list,
        a resource update the cached contents of the resource and its sub-resources) and are either queued for
        Receive-McpNotification or, with -Action, passed to the script block.

        Notifications are read in the background; the script block runs in the caller's runspace whenever a
        client command of this module runs on the session (Receive-McpNotification waits for them). Over
        Streamable HTTP each subscription is its own long-lived POST with an SSE response; an abruptly closed
        stream is reopened with a new request id (backoff 1, 2, 4, 8, 16 seconds; see -NoReconnect). Over stdio
        the subscription shares the server's output stream with the requests.

        The subscription ends with Unregister-McpSubscription, Disconnect-McpServer or when the server closes it
        (State Closed).

        In a legacy session (a server of revision 2025-11-25 or earlier) there is no listen request: the server
        sends list changes unsolicited and resource updates after resources/subscribe, which this command sends
        for -ResourceUri (Unregister-McpSubscription sends resources/unsubscribe). Over Streamable HTTP they arrive
        on the session's GET stream, which the session opens after initialize.
    .PARAMETER ToolsListChanged
        Subscribe to notifications/tools/list_changed.
    .PARAMETER PromptsListChanged
        Subscribe to notifications/prompts/list_changed.
    .PARAMETER ResourcesListChanged
        Subscribe to notifications/resources/list_changed.
    .PARAMETER ResourceUri
        Subscribe to notifications/resources/updated of these resources (and their sub-resources).
    .PARAMETER Action
        A script block invoked with each notification (Mcp.Notification: Method, Uri, SubscriptionId, Params,
        Received) instead of queueing it for Receive-McpNotification.
    .PARAMETER NoReconnect
        Over Streamable HTTP, do not reopen a stream that closed abruptly; the subscription ends instead.
    .PARAMETER TimeoutSeconds
        How long to wait for the server's acknowledgement (default: 30).
    .PARAMETER Session
        The session; defaults to the default session.
    .EXAMPLE
        $subscription = Register-McpSubscription -ToolsListChanged -ResourceUri 'file:///var/log/app.log'
        Receive-McpNotification -Subscription $subscription -TimeoutSeconds 60
    .EXAMPLE
        Register-McpSubscription -ToolsListChanged -Action { param($Notification) Write-Host "Tools changed: $($Notification.Method)" }
    .OUTPUTS
        Mcp.Subscription
    #>
    [CmdletBinding()]
    [OutputType('Mcp.Subscription')]
    param(
        [switch] $ToolsListChanged,

        [switch] $PromptsListChanged,

        [switch] $ResourcesListChanged,

        [ValidateNotNullOrEmpty()]
        [string[]] $ResourceUri,

        [scriptblock] $Action,

        [switch] $NoReconnect,

        [ValidateRange(1, 3600)]
        [int] $TimeoutSeconds = 30,

        [object] $Session
    )

    $target = Resolve-McpSession -Session $Session
    $filter = [ordered]@{}
    if ($ToolsListChanged) { $filter['toolsListChanged'] = $true }
    if ($PromptsListChanged) { $filter['promptsListChanged'] = $true }
    if ($ResourcesListChanged) { $filter['resourcesListChanged'] = $true }
    if ($ResourceUri) { $filter['resourceSubscriptions'] = [string[]] @($ResourceUri) }
    if ($filter.Count -eq 0) {
        throw [System.ArgumentException]::new('Subscribe to at least one notification type: -ToolsListChanged, -PromptsListChanged, -ResourcesListChanged or -ResourceUri.')
    }

    $id = [int] $target.NextId
    $target.NextId = $id + 1
    $subscription = [pscustomobject]@{
        PSTypeName    = 'Mcp.Subscription'
        Id            = $id
        CurrentId     = $id
        State         = 'Opening'
        Requested     = $filter
        Honoured      = $null
        Reconnects    = 0
        Error         = $null
        Action        = $Action
        Notifications = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        NoReconnect   = [bool] $NoReconnect
        StopRequested = $false
        Cts           = $null
        Reader        = $null
        Session       = $target
        Legacy        = $target.Era -eq 'Legacy'
    }
    if ($subscription.Legacy) {
        # A legacy server sends list changes unsolicited and resource updates after resources/subscribe; the
        # subscription filters what it sees from them.
        $capabilities = $target.InitializeResult['capabilities']
        $honoured = [ordered]@{}
        foreach ($flag in 'toolsListChanged', 'promptsListChanged', 'resourcesListChanged') {
            if ($filter.Contains($flag) -and (Get-McpWireValue -Object (Get-McpWireValue -Object $capabilities -Key $flag.Substring(0, $flag.Length - 'ListChanged'.Length)) -Key 'listChanged')) { $honoured[$flag] = $true }
        }
        if ($filter.Contains('resourceSubscriptions') -and (Get-McpWireValue -Object (Get-McpWireValue -Object $capabilities -Key 'resources') -Key 'subscribe')) {
            foreach ($uri in $filter['resourceSubscriptions']) {
                $null = Invoke-McpClientRequest -Session $target -Method 'resources/subscribe' -Params ([ordered]@{ uri = $uri })
            }
            $honoured['resourceSubscriptions'] = $filter['resourceSubscriptions']
        }
        $subscription.Honoured = $honoured
        $subscription.State = 'Open'
        $target.Subscriptions[[string] $id] = $subscription
        if ($target.Kind -eq 'Http') { Start-McpLegacyClientStream -Session $target } else { Start-McpTransportPump -Transport $target.Transport }
        return $subscription
    }
    $target.Subscriptions[[string] $id] = $subscription
    $target.SubscriptionIds[[string] $id] = $subscription

    try {
        if ($target.Kind -eq 'Http') {
            $subscription.Cts = [System.Threading.CancellationTokenSource]::new()
            $subscription.Reader = New-McpClientBackgroundRunspace -FunctionName 'Invoke-McpHttpListenLoop' -Parameters @{ Session = $target; Subscription = $subscription }
        } else {
            Start-McpTransportPump -Transport $target.Transport
            $params = [ordered]@{ _meta = (New-McpClientRequestMeta -Session $target); notifications = $filter }
            Send-McpTransportLine -Transport $target.Transport -Line (ConvertTo-McpJson -InputObject (New-McpRequest -Id $id -Method 'subscriptions/listen' -Params $params))
        }
        $acknowledged = Wait-McpClientEvent -Session $target -Condition { $subscription.State -ne 'Opening' } -TimeoutMs ($TimeoutSeconds * 1000)
    } catch {
        Close-McpClientSubscription -Session $target -Subscription $subscription
        throw
    }
    if (-not $acknowledged) {
        Close-McpClientSubscription -Session $target -Subscription $subscription
        throw [System.TimeoutException]::new("The server did not acknowledge the subscription (id $id) within $TimeoutSeconds s.")
    }
    if ($subscription.State -ne 'Open') {
        Close-McpClientSubscription -Session $target -Subscription $subscription
        if ($subscription.Error -is [System.Exception]) { throw $subscription.Error }
        $reason = if ($subscription.Error) { ": $($subscription.Error)" } else { '.' }
        throw [System.InvalidOperationException]::new("The server ended the subscription (id $id) before acknowledging it$reason")
    }
    $subscription
}
