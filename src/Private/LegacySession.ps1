# Legacy sessions (revisions 2025-11-25, 2025-06-18 and 2025-03-26 as a version string) of a dual-era server:
# the initialize handshake with version and capability negotiation, the methods only these revisions have
# (ping, logging/setLevel, resources/subscribe and resources/unsubscribe), server-initiated requests (a worker
# blocks until the dispatcher correlates the client's response), and the unsolicited list-changed and
# resource-updated notifications. The stateless 2026-07-28 core does not depend on anything here.
#
# A session is a hashtable owned by the dispatcher; the members workers touch (Pending, a concurrent table of
# the open server-initiated requests) are thread-safe. Over stdio and in memory there is one process-wide
# session ($State.LineSession); over Streamable HTTP one per Mcp-Session-Id ($State.Sessions).

$script:McpLegacyOnlyMethods = @('ping', 'logging/setLevel', 'resources/subscribe', 'resources/unsubscribe')

function New-McpLegacySession {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # The Mcp-Session-Id over Streamable HTTP; none over the line transports.
        [AllowNull()]
        [string] $Id,

        [Parameter(Mandatory)]
        [string] $ProtocolVersion,

        [AllowNull()]
        [System.Collections.IDictionary] $ClientCapabilities,

        [AllowNull()]
        [System.Collections.IDictionary] $ClientInfo
    )

    $now = [datetime]::UtcNow
    @{
        Id                    = $Id
        # Prefix of the in-flight keys of the session's requests: request ids are unique per session only.
        KeyPrefix             = if ($Id) { "legacy:$Id|" } else { 'legacy|' }
        ProtocolVersion       = $ProtocolVersion
        ClientCapabilities    = if ($null -ne $ClientCapabilities) { $ClientCapabilities } else { [ordered]@{} }
        ClientInfo            = $ClientInfo
        Initialized           = $false
        LogLevel              = $null
        ResourceSubscriptions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        Pending               = [System.Collections.Concurrent.ConcurrentDictionary[string, hashtable]]::new([System.StringComparer]::Ordinal)
        GetChannel            = $null
        Created               = $now
        LastSeen              = $now
        Closed                = $false
    }
}

function Get-McpLegacySession {
    <#
    .SYNOPSIS
        The open legacy sessions of a dispatcher: the process-wide one of a line transport, or the HTTP sessions.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    if ($null -ne $State.LineSession) { $State.LineSession }
    if ($null -ne $State.Sessions) {
        foreach ($session in @($State.Sessions.Values)) { $session }
    }
}

function Get-McpLegacyServerCapability {
    <#
    .SYNOPSIS
        The capabilities of an InitializeResult: those of server/discover plus logging (logging/setLevel).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server
    )

    $capabilities = Get-McpServerCapability -Server $Server
    $capabilities['logging'] = [ordered]@{}
    $capabilities
}

function Get-McpLegacyServerInfo {
    <#
    .SYNOPSIS
        serverInfo of an InitializeResult: 2025-06-18 and earlier know name, version and title only.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [Parameter(Mandatory)]
        [string] $ProtocolVersion
    )

    $info = Get-McpServerInfoObject -Server $Server
    if ($ProtocolVersion -ne '2025-11-25') {
        foreach ($name in 'description', 'websiteUrl', 'icons') {
            if ($info.Contains($name)) { $info.Remove($name) }
        }
    }
    $info
}

function Invoke-McpLegacyInitialize {
    <#
    .SYNOPSIS
        Answers initialize: negotiates the version, opens the legacy session and returns it (the caller registers it).
    .DESCRIPTION
        A requested version the server speaks is echoed; otherwise the server answers with its newest legacy
        version and the client decides whether it can speak it. A server without legacy revisions answers
        -32022 with the versions it supports, as the specification recommends for modern-only servers.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [AllowNull()]
        [object] $Params,

        # The Mcp-Session-Id to assign over Streamable HTTP.
        [AllowNull()]
        [string] $SessionId
    )

    $requested = if ($Params -is [System.Collections.IDictionary] -and $Params['protocolVersion'] -is [string]) { [string] $Params['protocolVersion'] } else { $null }
    $legacy = @(Get-McpServerVersion -Server $Server -Era Legacy -Accepted)
    if ($legacy.Count -eq 0) {
        $modern = @(Get-McpServerVersion -Server $Server -Era Modern)
        $data = [ordered]@{ supported = $modern; requested = if ($null -ne $requested) { $requested } else { '' } }
        throw [McpProtocolException]::new($script:McpErrorCode.UnsupportedProtocolVersion, "This server speaks the stateless lifecycle of protocol version(s) $($modern -join ', ') without the initialize handshake; send server/discover and per-request _meta instead.", $data)
    }
    $invalidParams = $script:McpErrorCode.InvalidParams
    if ($null -eq $requested) {
        throw [McpProtocolException]::new($invalidParams, "initialize requires a string parameter 'protocolVersion'.")
    }
    $capabilities = $Params['capabilities']
    if ($capabilities -isnot [System.Collections.IDictionary]) {
        throw [McpProtocolException]::new($invalidParams, "initialize requires an object parameter 'capabilities'.")
    }
    $clientInfo = $Params['clientInfo']
    if ($clientInfo -isnot [System.Collections.IDictionary] -or $clientInfo['name'] -isnot [string] -or $clientInfo['version'] -isnot [string]) {
        throw [McpProtocolException]::new($invalidParams, "initialize requires a parameter 'clientInfo' with string members 'name' and 'version'.")
    }
    $version = if ($requested -in $legacy) { $requested } else { $legacy[0] }
    New-McpLegacySession -Id $SessionId -ProtocolVersion $version -ClientCapabilities $capabilities -ClientInfo $clientInfo
}

function Get-McpLegacyInitializeResult {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [Parameter(Mandatory)]
        [hashtable] $Session
    )

    $result = [ordered]@{
        protocolVersion = $Session.ProtocolVersion
        capabilities    = Get-McpLegacyServerCapability -Server $Server
        serverInfo      = Get-McpLegacyServerInfo -Server $Server -ProtocolVersion $Session.ProtocolVersion
    }
    if ($Server.Instructions) { $result['instructions'] = $Server.Instructions }
    $result
}

function Invoke-McpLegacyMethod {
    <#
    .SYNOPSIS
        Answers the methods only the legacy revisions have; returns the result, or $null when the method is not one of them.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [Parameter(Mandatory)]
        [hashtable] $Session,

        [Parameter(Mandatory)]
        [string] $Method,

        [AllowNull()]
        [object] $Params
    )

    $invalidParams = $script:McpErrorCode.InvalidParams
    switch ($Method) {
        'ping' {
            return [ordered]@{}
        }
        'logging/setLevel' {
            $level = if ($Params -is [System.Collections.IDictionary]) { $Params['level'] } else { $null }
            if ($level -isnot [string] -or $level -cnotin $script:McpLoggingLevelNames) {
                throw [McpProtocolException]::new($invalidParams, "logging/setLevel requires 'level', one of: $($script:McpLoggingLevelNames -join ', ').")
            }
            $Session.LogLevel = $level
            return [ordered]@{}
        }
        { $_ -in @('resources/subscribe', 'resources/unsubscribe') } {
            Assert-McpServerCapability -Server $Server -Capability resources -Method $Method
            $uri = if ($Params -is [System.Collections.IDictionary]) { $Params['uri'] } else { $null }
            if (-not (Test-McpResourceUri -Uri $uri)) {
                throw [McpProtocolException]::new($invalidParams, "$Method requires a parameter 'uri' with an absolute URI.")
            }
            if ($Method -eq 'resources/subscribe') {
                $null = $Session.ResourceSubscriptions.Add([string] $uri)
            } else {
                $null = $Session.ResourceSubscriptions.Remove([string] $uri)
            }
            return [ordered]@{}
        }
    }
    $null
}

function Get-McpLegacyRequestMeta {
    <#
    .SYNOPSIS
        The request metadata of a legacy request, in the shape of Get-McpRequestMeta: version, capabilities and client info from the session, the log level of logging/setLevel, the progress token from _meta.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Session,

        [AllowNull()]
        [object] $Params
    )

    $progressToken = $null
    if ($Params -is [System.Collections.IDictionary] -and $Params['_meta'] -is [System.Collections.IDictionary]) {
        $meta = $Params['_meta']
        $tokenKey = $script:McpMetaKey.ProgressToken
        if ($meta.Contains($tokenKey) -and $null -ne $meta[$tokenKey]) {
            $progressToken = $meta[$tokenKey]
            if (-not (Test-McpRequestId -Id $progressToken)) {
                throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "_meta field '$tokenKey' must be a string or an integer.")
            }
        }
    }
    @{
        ProtocolVersion    = $Session.ProtocolVersion
        ClientCapabilities = $Session.ClientCapabilities
        ClientInfo         = $Session.ClientInfo
        LogLevel           = $Session.LogLevel
        ProgressToken      = $progressToken
    }
}

function Complete-McpLegacyServerRequest {
    <#
    .SYNOPSIS
        Hands the client's response to a server-initiated request to the worker waiting for it; $false when no request of the session has that id.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Session,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Message
    )

    if (-not $Message.Contains('id') -or $null -eq $Message['id']) { return $false }
    $slot = $null
    if (-not $Session.Pending.TryGetValue([string] $Message['id'], [ref] $slot)) { return $false }
    $slot.Json = ConvertTo-McpJson -InputObject $Message
    $slot.Event.Set()
    $true
}

function Stop-McpLegacyServerRequest {
    <#
    .SYNOPSIS
        Fails an open server-initiated request (it could not be delivered, or the session ended).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal request bookkeeping.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Session,

        [Parameter(Mandatory)]
        [string] $Id,

        [Parameter(Mandatory)]
        [string] $Reason
    )

    $slot = $null
    if (-not $Session.Pending.TryGetValue($Id, [ref] $slot)) { return }
    $slot.Json = ConvertTo-McpJson -InputObject (New-McpErrorResponse -Id $Id -ErrorObject (New-McpError -Code $script:McpErrorCode.InternalError -Message $Reason))
    $slot.Event.Set()
}

function Close-McpLegacySession {
    <#
    .SYNOPSIS
        Ends a legacy session: cancels its requests, fails its open server-initiated requests and closes its GET stream.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal session bookkeeping.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [hashtable] $Session,

        [string] $Reason = 'closed'
    )

    if ($Session.Closed) { return }
    $Session.Closed = $true
    foreach ($key in @($State.InFlight.Keys)) {
        if (-not ([string] $key).StartsWith($Session.KeyPrefix, [System.StringComparison]::Ordinal)) { continue }
        $entry = $State.InFlight[$key]
        if (-not $entry.Cancelled -and -not $entry.Responded) {
            Stop-McpInFlightRequest -Entry $entry
            $entry.Responded = $true
        }
    }
    foreach ($id in @($Session.Pending.Keys)) { Stop-McpLegacyServerRequest -Session $Session -Id $id -Reason "The session ended ($Reason)." }
    if ($null -ne $Session.GetChannel) {
        Close-McpHttpChannel -State $State -Channel $Session.GetChannel
        $Session.GetChannel = $null
    }
    if ($Session.Id -and $null -ne $State.Sessions) { $State.Sessions.Remove($Session.Id) }
    if ($State.LineSession -eq $Session) { $State.LineSession = $null }
    Write-McpStderr -Level Info -Threshold $State.LogLevel -Logger $State.Server.Name -Message ("Legacy session {0}{1}." -f $(if ($Session.Id) { "$($Session.Id) " } else { '' }), $Reason)
}

function Test-McpLegacyNotificationMatch {
    <#
    .SYNOPSIS
        Whether a session receives an unsolicited notification: list changes always, resource updates for subscribed URIs and their sub-resources.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Session,

        [Parameter(Mandatory)]
        [string] $Method,

        [AllowNull()]
        [System.Collections.IDictionary] $Params
    )

    if (-not $Session.Initialized -or $Session.Closed) { return $false }
    if ($Method -ceq 'notifications/resources/updated') {
        if ($null -eq $Params -or $Session.ResourceSubscriptions.Count -eq 0) { return $false }
        $honoured = @{ resourceSubscriptions = [string[]] @($Session.ResourceSubscriptions) }
        return Test-McpListenerMatch -Honoured $honoured -Method $Method -Params $Params
    }
    $Method -in @($script:McpListenFilterFlags.Values)
}

function Send-McpLegacyNotification {
    <#
    .SYNOPSIS
        Delivers a list-changed or resource-updated notification to the legacy sessions: on the line transport, or on a session's GET stream.
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

    $json = $null
    foreach ($session in @(Get-McpLegacySession -State $State)) {
        if (-not (Test-McpLegacyNotificationMatch -Session $session -Method $Method -Params $Params)) { continue }
        if ($null -eq $json) {
            $plain = $null
            if ($null -ne $Params) {
                $plain = [ordered]@{}
                foreach ($key in $Params.Keys) { if ([string] $key -ne '_meta') { $plain[$key] = $Params[$key] } }
            }
            $json = ConvertTo-McpJson -InputObject (New-McpNotification -Method $Method -Params $plain)
        }
        if ($session.Id) {
            $channel = $session.GetChannel
            if ($null -eq $channel -or $channel.Closed) {
                Write-McpStderr -Level Debug -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Dropping $Method for session $($session.Id): no GET stream open."
                continue
            }
            if (-not (Write-McpSseChunk -State $State -Channel $channel -Text "event: message`ndata: $json`n`n")) { $session.GetChannel = $null }
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

function Invoke-McpLegacyInputRequest {
    <#
    .SYNOPSIS
        Worker side of an input request in a legacy session: sends it as a server-initiated request and waits for the client's answer.
    .DESCRIPTION
        The request goes to the dispatcher (Kind ServerRequest), which writes it to the line transport or to the
        request's SSE stream. The worker waits for the response, the cancellation of its request or the request
        timeout; a cancelled wait ends the handler. The answer is validated like an answer to an input request
        and cached under its key, so that asking again with the same key does not ask the client twice.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [object] $Context,

        [Parameter(Mandatory)]
        [string] $Key,

        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary] $Request
    )

    $legacy = $Context.Legacy
    $params = [ordered]@{}
    foreach ($name in $Request['params'].Keys) { $params[$name] = $Request['params'][$name] }
    if ($Request['method'] -eq 'elicitation/create') {
        if ($params['mode'] -eq 'url') {
            if ($Context.ProtocolVersion -ne '2025-11-25') {
                throw [McpProtocolException]::new($script:McpErrorCode.InvalidRequest, "URL mode elicitation needs protocol version 2025-11-25; the session speaks $($Context.ProtocolVersion).")
            }
            if (-not $params.Contains('elicitationId')) { $params['elicitationId'] = [guid]::NewGuid().ToString() }
        } elseif ($Context.ProtocolVersion -ne '2025-11-25' -and $params.Contains('mode')) {
            $params.Remove('mode')
        }
    }
    $id = 'srv-' + [guid]::NewGuid().ToString('n')
    $slot = @{ Event = [System.Threading.ManualResetEventSlim]::new($false); Json = $null }
    $null = $legacy.Pending.TryAdd($id, $slot)
    try {
        $json = ConvertTo-McpJson -InputObject (New-McpRequest -Id $id -Method $Request['method'] -Params $params)
        $Context.Sink.Queue.Enqueue(@{ Kind = 'ServerRequest'; RequestId = $Context.RequestId; KeyPrefix = $Context.Sink.KeyPrefix; ServerRequestId = $id; Json = $json })
        $null = $Context.Sink.Signal.Set()
        $timeoutMs = if ($legacy.TimeoutSeconds -gt 0) { [int] $legacy.TimeoutSeconds * 1000 } else { -1 }
        $handles = [System.Threading.WaitHandle[]] @($slot.Event.WaitHandle, $Context.CancellationToken.WaitHandle)
        $index = [System.Threading.WaitHandle]::WaitAny($handles, $timeoutMs)
        if ($index -eq 1 -or $Context.CancellationToken.IsCancellationRequested) {
            throw [System.OperationCanceledException]::new('The request was cancelled while it waited for the client.')
        }
        if ($index -eq [System.Threading.WaitHandle]::WaitTimeout) {
            throw [McpProtocolException]::new($script:McpErrorCode.InternalError, "The client did not answer $($Request['method']) within $($legacy.TimeoutSeconds) seconds.")
        }
    } finally {
        $removed = $null
        $null = $legacy.Pending.TryRemove($id, [ref] $removed)
        $slot.Event.Dispose()
    }
    $answer = ConvertFrom-McpJson -Json $slot.Json
    if ($answer.Contains('error')) {
        $errorObject = $answer['error']
        throw [McpProtocolException]::new($script:McpErrorCode.InternalError, "The client answered $($Request['method']) with error $($errorObject['code']): $($errorObject['message'])")
    }
    $result = $answer['result']
    if ($result -is [System.Collections.IDictionary] -and $result.Contains('_meta')) { $result.Remove('_meta') }
    $response = Test-McpInputResponse -Key $Key -Request ([ordered]@{ method = $Request['method']; params = $params }) -Response $result
    $Context.InputResponses[$Key] = $response
    $Context.ConsumedInput[$Key] = $response
    $response
}
