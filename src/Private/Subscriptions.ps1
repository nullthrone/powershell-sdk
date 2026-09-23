# subscriptions/listen on the server: listeners (one per open listen request), the acknowledgement that opens
# every stream, the fan-out of list-changed and resource-updated notifications to the listeners whose filter
# asked for them (tagged with the subscription id), and the teardown (client cancel, disconnect, graceful
# close on shutdown). Listen requests never reach the worker pool.

$script:McpListenFilterFlags = [ordered]@{
    toolsListChanged     = 'notifications/tools/list_changed'
    promptsListChanged   = 'notifications/prompts/list_changed'
    resourcesListChanged = 'notifications/resources/list_changed'
}

function Get-McpHonouredSubscription {
    <#
    .SYNOPSIS
        Validates a SubscriptionFilter and returns the subset of it the server honours (the types it can deliver).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [AllowNull()]
        [object] $Filter
    )

    if ($Filter -isnot [System.Collections.IDictionary]) {
        throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "subscriptions/listen requires an object parameter 'notifications'.")
    }
    $capabilities = Get-McpServerCapability -Server $Server
    $honoured = [ordered]@{}
    foreach ($flag in $script:McpListenFilterFlags.Keys) {
        if (-not $Filter.Contains($flag)) { continue }
        if ($Filter[$flag] -isnot [bool]) {
            throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "The subscription filter member '$flag' must be a boolean.")
        }
        $capability = $capabilities[$flag.Substring(0, $flag.Length - 'ListChanged'.Length)]
        if ($Filter[$flag] -and $capability -is [System.Collections.IDictionary] -and $capability['listChanged']) { $honoured[$flag] = $true }
    }
    if ($Filter.Contains('resourceSubscriptions')) {
        $uris = $Filter['resourceSubscriptions']
        if ($uris -isnot [System.Collections.IList] -or @($uris | Where-Object { $_ -isnot [string] }).Count -gt 0) {
            throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "The subscription filter member 'resourceSubscriptions' must be an array of URIs.")
        }
        $resources = $capabilities['resources']
        if ($uris.Count -gt 0 -and $resources -is [System.Collections.IDictionary] -and $resources['subscribe']) {
            $honoured['resourceSubscriptions'] = [string[]] @($uris)
        }
    }
    $honoured
}

function Test-McpListenerMatch {
    <#
    .SYNOPSIS
        Whether a listener's honoured filter asks for a notification.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Honoured,

        [Parameter(Mandatory)]
        [string] $Method,

        [AllowNull()]
        [System.Collections.IDictionary] $Params
    )

    foreach ($flag in $script:McpListenFilterFlags.Keys) {
        if ($script:McpListenFilterFlags[$flag] -ceq $Method) { return [bool] $Honoured[$flag] }
    }
    if ($Method -ceq 'notifications/resources/updated' -and $Honoured.Contains('resourceSubscriptions') -and $null -ne $Params) {
        $uri = [string] $Params['uri']
        foreach ($subscribed in $Honoured['resourceSubscriptions']) {
            # A sub-resource of a subscribed URI (subscribed/...) is delivered too.
            if ($uri -ceq $subscribed -or $uri.StartsWith($subscribed.TrimEnd('/') + '/', [System.StringComparison]::Ordinal)) { return $true }
        }
    }
    $false
}

function Start-McpListener {
    <#
    .SYNOPSIS
        Opens a subscriptions/listen stream: sends the acknowledgement as its first message and registers the listener.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal subscription bookkeeping.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [object] $Id,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Params,

        [AllowNull()]
        [hashtable] $Channel
    )

    $honoured = Get-McpHonouredSubscription -Server $State.Server -Filter $(if ($Params.Contains('notifications')) { $Params['notifications'] } else { $null })
    $meta = [ordered]@{}
    $meta[$script:McpMetaKey.SubscriptionId] = $Id
    $notification = New-McpNotification -Method 'notifications/subscriptions/acknowledged' -Params ([ordered]@{ notifications = $honoured; _meta = $meta })
    $json = ConvertTo-McpJson -InputObject $notification
    if ($null -ne $Channel -and $Channel.Kind -eq 'Http') {
        if (-not (Start-McpHttpSse -State $State -Channel $Channel)) { return }
        if (-not (Write-McpSseChunk -State $State -Channel $Channel -Text "event: message`ndata: $json`n`n")) { return }
    } else {
        Send-McpTransportLine -Transport $State.Transport -Line $json
    }
    $key = Get-McpRequestKey -Id $Id
    $State.Listeners[$key] = @{
        Id       = $Id
        Key      = $key
        Honoured = $honoured
        Channel  = $Channel
        Opened   = [datetime]::UtcNow
    }
    Write-McpStderr -Level Info -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Subscription $Id opened ($(if ($honoured.Count -gt 0) { @($honoured.Keys) -join ', ' } else { 'nothing honoured' }))."
}

function Remove-McpListener {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal subscription bookkeeping.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [string] $Key,

        [string] $Reason = 'closed'
    )

    if (-not $State.Listeners.ContainsKey($Key)) { return }
    $listener = $State.Listeners[$Key]
    $State.Listeners.Remove($Key)
    if ($null -ne $listener.Channel -and $listener.Channel.Kind -eq 'Http') {
        Close-McpHttpChannel -State $State -Channel $listener.Channel -Abort
    }
    Write-McpStderr -Level Info -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Subscription $($listener.Id) $Reason."
}

function Send-McpListenerNotification {
    <#
    .SYNOPSIS
        Delivers a notification to every listener whose filter asks for it, tagged with the listener's subscription id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [string] $Method,

        [AllowNull()]
        [System.Collections.IDictionary] $Params
    )

    foreach ($listener in @($State.Listeners.Values)) {
        if (-not (Test-McpListenerMatch -Honoured $listener.Honoured -Method $Method -Params $Params)) { continue }
        $tagged = [ordered]@{}
        if ($null -ne $Params) {
            foreach ($key in $Params.Keys) { if ([string] $key -ne '_meta') { $tagged[$key] = $Params[$key] } }
        }
        $meta = [ordered]@{}
        if ($null -ne $Params -and $Params['_meta'] -is [System.Collections.IDictionary]) {
            foreach ($key in $Params['_meta'].Keys) { $meta[$key] = $Params['_meta'][$key] }
        }
        $meta[$script:McpMetaKey.SubscriptionId] = $listener.Id
        $tagged['_meta'] = $meta
        $json = ConvertTo-McpJson -InputObject (New-McpNotification -Method $Method -Params $tagged)
        Write-McpStderr -Level Debug -Threshold $State.LogLevel -Logger $State.Server.Name -Message "-> $Method on subscription $($listener.Id)"
        if ($null -ne $listener.Channel -and $listener.Channel.Kind -eq 'Http') {
            if (-not (Write-McpSseChunk -State $State -Channel $listener.Channel -Text "event: message`ndata: $json`n`n")) {
                Remove-McpListener -State $State -Key $listener.Key -Reason 'ended: the client closed the stream'
            }
            continue
        }
        try {
            Send-McpTransportLine -Transport $State.Transport -Line $json
        } catch [System.IO.IOException] {
            Write-McpStderr -Level Warning -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Writing to the transport failed: $($_.Exception.Message)"
            $State.Stopping = $true
            return
        }
    }
}

function Close-McpAllListener {
    <#
    .SYNOPSIS
        Ends every subscription gracefully: the SubscriptionsListenResult with the subscription id answers each listen request.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal subscription bookkeeping.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    foreach ($listener in @($State.Listeners.Values)) {
        $State.Listeners.Remove($listener.Key)
        $meta = [ordered]@{}
        $meta[$script:McpMetaKey.SubscriptionId] = $listener.Id
        $result = Add-McpResultMeta -Result ([ordered]@{ resultType = 'complete'; _meta = $meta }) -Server $State.Server
        try {
            Send-McpDispatcherMessage -State $State -Channel $listener.Channel -Message (New-McpResultResponse -Id $listener.Id -Result $result)
        } catch {
            Write-Debug "Closing subscription $($listener.Id) failed: $($_.Exception.Message)"
        }
        Write-McpStderr -Level Info -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Subscription $($listener.Id) closed by the server."
    }
}

function Send-McpServerNotification {
    <#
    .SYNOPSIS
        Queues a notification for the listeners of a running server, from a handler (its context) or from any runspace (the server object).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Method,

        [System.Collections.IDictionary] $Params,

        [AllowNull()]
        [object] $Context,

        [AllowNull()]
        [object] $Server
    )

    $sink = $null
    if ($null -ne $Context -and $Context.PSObject.Properties['Sink'] -and $null -ne $Context.Sink) {
        $sink = $Context.Sink
    } else {
        $target = Resolve-McpServer -Server $Server
        if ($target.State.ContainsKey('Sink')) { $sink = $target.State.Sink }
    }
    if ($null -eq $sink) {
        Write-Verbose "The server is not running; '$Method' is not sent."
        return $false
    }
    $paramsJson = if ($null -ne $Params) { ConvertTo-McpJson -InputObject $Params } else { $null }
    $sink.Queue.Enqueue(@{ Kind = 'Broadcast'; RequestId = $null; Method = $Method; ParamsJson = $paramsJson })
    $null = $sink.Signal.Set()
    $true
}
