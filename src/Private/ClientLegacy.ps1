# Client side of the dual era: the detection of the server's era (the server/discover probe over stdio and in
# memory, the modern POST whose answer is inspected over Streamable HTTP), the initialize handshake with the
# servers of 2025-11-25, 2025-06-18 and 2025-03-26, answers to server-initiated requests (elicitation, sampling
# and roots through the session's callbacks, ping), resumption of an interrupted SSE response stream with GET
# and Last-Event-ID, the session's GET stream, and DELETE when the session ends. The request path in
# Client.ps1 and HttpClient.ps1 consults Session.Era for the per-request metadata and headers.

# The era of HTTP endpoints this process has talked to (keyed by URL), so that a second connection to a legacy
# server skips the probe. A failed handshake removes the entry.
$script:McpClientEraCache = [System.Collections.Concurrent.ConcurrentDictionary[string, string]]::new([System.StringComparer]::Ordinal)

# The revisions whose initialize handshake the client speaks, newest first; 2025-03-26 is accepted from servers.
$script:McpClientLegacyVersions = @('2025-11-25', '2025-06-18', '2025-03-26')

# Errors that only a server of revision 2026-07-28 sends: they identify a modern server (no fallback).
$script:McpModernOnlyErrorCodes = @(-32020, -32021, -32022)

function Get-McpClientEraCacheKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session
    )

    if ($Session.Kind -ne 'Http') { return $null }
    $Session.Transport.Url.AbsoluteUri
}

function Test-McpDiscoverResult {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Result
    )

    $Result -is [System.Collections.IDictionary] -and $Result['supportedVersions'] -is [System.Collections.IList] -and $Result['capabilities'] -is [System.Collections.IDictionary]
}

function Connect-McpClientModern {
    <#
    .SYNOPSIS
        The modern start of a session: server/discover, with one retry at a mutual version after -32022; returns $null when the answer shows a legacy server (Auto only).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [int] $TimeoutMs,

        # Auto: an answer that is not a DiscoverResult or a modern error means a legacy server ($null).
        [switch] $Probe
    )

    $discover = $null
    try {
        $discover = Invoke-McpClientRequest -Session $Session -Method 'server/discover' -TimeoutMs $TimeoutMs
    } catch [McpProtocolException] {
        $exception = $_.Exception
        if ($exception.Code -eq $script:McpErrorCode.UnsupportedProtocolVersion -and $exception.Data -is [System.Collections.IDictionary] -and $exception.Data.Contains('supported')) {
            $mutual = @($exception.Data['supported'] | Where-Object { $_ -in $script:McpModernProtocolVersions })
            if ($mutual.Count -eq 0) {
                throw [System.InvalidOperationException]::new("The server supports protocol version(s) $(@($exception.Data['supported']) -join ', '), none of which this client speaks ($($script:McpModernProtocolVersions -join ', ')).")
            }
            $Session.ProtocolVersion = $mutual[0]
            $discover = Invoke-McpClientRequest -Session $Session -Method 'server/discover' -TimeoutMs $TimeoutMs
        } elseif ($Probe -and $exception.Code -notin $script:McpModernOnlyErrorCodes) {
            # Any other error is how a legacy server answers an unknown method before initialize.
            Write-Verbose "server/discover failed with $($exception.Code) ($($exception.Message)); falling back to the initialize handshake."
            return $null
        } else {
            throw [System.InvalidOperationException]::new("server/discover failed with $($exception.Code): $($exception.Message)", $exception)
        }
    } catch [System.TimeoutException] {
        if (-not $Probe) { throw }
        Write-Verbose 'No answer to server/discover in time; falling back to the initialize handshake.'
        return $null
    } catch [System.Net.Http.HttpRequestException] {
        # A response without a JSON-RPC body (an empty 400, an HTML error page) comes from a legacy server.
        if (-not $Probe) { throw }
        Write-Verbose "server/discover failed: $($_.Exception.Message); falling back to the initialize handshake."
        return $null
    }
    if (-not (Test-McpDiscoverResult -Result $discover)) {
        if ($Probe) {
            Write-Verbose 'The answer to server/discover is not a DiscoverResult; falling back to the initialize handshake.'
            return $null
        }
        throw [System.InvalidOperationException]::new('The server/discover result is not a DiscoverResult.')
    }
    $supported = @($discover['supportedVersions'])
    if ($Session.ProtocolVersion -notin $supported) {
        $mutual = @($supported | Where-Object { $_ -in $script:McpModernProtocolVersions })
        if ($mutual.Count -eq 0) {
            throw [System.InvalidOperationException]::new("The server supports protocol version(s) $($supported -join ', '), none of which this client speaks.")
        }
        $Session.ProtocolVersion = $mutual[0]
    }
    $discover
}

function ConvertTo-McpLegacyClientCapability {
    <#
    .SYNOPSIS
        The client capabilities of an initialize request: those of the session, in the shape of the negotiated revision.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Capabilities,

        [Parameter(Mandatory)]
        [string] $ProtocolVersion
    )

    $legacy = [ordered]@{}
    foreach ($key in $Capabilities.Keys) {
        # Extensions are negotiated in revision 2026-07-28 only.
        if ([string] $key -eq 'extensions') { continue }
        $legacy[[string] $key] = $Capabilities[$key]
    }
    if ($legacy.Contains('elicitation') -and $ProtocolVersion -ne '2025-11-25') {
        # Before 2025-11-25 elicitation had no modes (form only).
        $legacy['elicitation'] = [ordered]@{}
    }
    if ($legacy.Contains('roots')) {
        $legacy['roots'] = [ordered]@{ listChanged = $false }
    }
    $legacy
}

function ConvertTo-McpLegacyServerInfoObject {
    <#
    .SYNOPSIS
        The Mcp.ServerInfo of a legacy session, from its InitializeResult.
    #>
    [CmdletBinding()]
    [OutputType('Mcp.ServerInfo')]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $InitializeResult
    )

    $info = Get-McpWireValue -Object $InitializeResult -Key 'serverInfo'
    [pscustomobject]@{
        PSTypeName        = 'Mcp.ServerInfo'
        Name              = Get-McpWireValue -Object $info -Key 'name'
        Version           = Get-McpWireValue -Object $info -Key 'version'
        Title             = Get-McpWireValue -Object $info -Key 'title'
        Description       = Get-McpWireValue -Object $info -Key 'description'
        WebsiteUrl        = Get-McpWireValue -Object $info -Key 'websiteUrl'
        Icons             = Get-McpWireValue -Object $info -Key 'icons'
        ProtocolVersion   = [string] $InitializeResult['protocolVersion']
        SupportedVersions = @([string] $InitializeResult['protocolVersion'])
        Capabilities      = Get-McpWireValue -Object $InitializeResult -Key 'capabilities'
        Instructions      = Get-McpWireValue -Object $InitializeResult -Key 'instructions'
        TtlMs             = $null
        CacheScope        = $null
        Raw               = $InitializeResult
    }
}

function Initialize-McpLegacyClient {
    <#
    .SYNOPSIS
        The initialize handshake of the legacy revisions: negotiates the version, keeps the server info, sends notifications/initialized and sets the session's log level.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [int] $TimeoutMs
    )

    $requested = if ($Session.PreferredLegacyVersion) { $Session.PreferredLegacyVersion } else { $script:McpClientLegacyVersions[0] }
    $Session.Era = 'Legacy'
    $Session.SessionId = $null
    $Session.InitializeResult = $null
    $Session.ProtocolVersion = $requested
    $params = [ordered]@{
        protocolVersion = $requested
        capabilities    = ConvertTo-McpLegacyClientCapability -Capabilities $Session.ClientCapabilities -ProtocolVersion $requested
        clientInfo      = $Session.ClientInfo
    }
    $result = Invoke-McpClientRequest -Session $Session -Method 'initialize' -Params $params -TimeoutMs $TimeoutMs
    if ($result -isnot [System.Collections.IDictionary] -or $result['protocolVersion'] -isnot [string] -or $result['capabilities'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('The initialize result is not an InitializeResult.')
    }
    $negotiated = [string] $result['protocolVersion']
    if ($negotiated -notin $script:McpClientLegacyVersions) {
        throw [System.InvalidOperationException]::new("The server answered initialize with protocol version '$negotiated', which this client does not speak ($($script:McpClientLegacyVersions -join ', ')).")
    }
    $Session.ProtocolVersion = $negotiated
    $Session.InitializeResult = $result
    $Session.ServerInfo = ConvertTo-McpLegacyServerInfoObject -InitializeResult $result
    $Session.Name = $Session.ServerInfo.Name
    Send-McpClientNotification -Session $Session -Method 'notifications/initialized'
    $Session.LegacyLogLevel = $null
    if ($null -ne $Session.LogLevel) { Set-McpLegacyClientLogLevel -Session $Session -Level $Session.LogLevel }
}

function Set-McpLegacyClientLogLevel {
    <#
    .SYNOPSIS
        Sends logging/setLevel when the level differs from the one the session last set and the server declares logging.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The caller owns the ShouldProcess decision.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [object] $Level
    )

    $name = (ConvertTo-McpLoggingLevel -Level $Level).ToString().ToLowerInvariant()
    if ($Session.LegacyLogLevel -ceq $name) { return }
    $capabilities = if ($null -ne $Session.InitializeResult) { $Session.InitializeResult['capabilities'] } else { $null }
    if (-not (Test-McpCapabilityPath -Capabilities $capabilities -Path 'logging')) {
        Write-Verbose "The server does not declare the logging capability; the log level '$name' is not sent."
        return
    }
    $null = Invoke-McpClientRequest -Session $Session -Method 'logging/setLevel' -Params ([ordered]@{ level = $name })
    $Session.LegacyLogLevel = $name
}

function Initialize-McpClientSession {
    <#
    .SYNOPSIS
        Starts a session in the requested era (Auto detects it): the modern server/discover or the legacy initialize handshake.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [ValidateSet('Auto', 'Modern', 'Legacy')]
        [string] $Era,

        [Parameter(Mandatory)]
        [int] $ConnectTimeoutMs
    )

    $cacheKey = Get-McpClientEraCacheKey -Session $Session
    $cached = $null
    if ($Era -eq 'Auto' -and $null -ne $cacheKey) { $null = $script:McpClientEraCache.TryGetValue($cacheKey, [ref] $cached) }
    if ($Era -eq 'Legacy' -or $cached -eq 'Legacy') {
        try {
            Initialize-McpLegacyClient -Session $Session -TimeoutMs $ConnectTimeoutMs
            if ($null -ne $cacheKey) { $script:McpClientEraCache[$cacheKey] = 'Legacy' }
            return
        } catch {
            $removed = $null
            if ($null -ne $cacheKey) { $null = $script:McpClientEraCache.TryRemove($cacheKey, [ref] $removed) }
            # A cached assumption that no longer holds is probed again; an explicit -Era Legacy fails.
            if ($Era -eq 'Legacy') { throw }
            $Session.Era = 'Modern'
            $Session.ProtocolVersion = $Session.PreferredModernVersion
        }
    }
    $probeTimeout = if ($Era -eq 'Auto') { [math]::Min($ConnectTimeoutMs, 5000) } else { $ConnectTimeoutMs }
    $discover = Connect-McpClientModern -Session $Session -TimeoutMs $probeTimeout -Probe:($Era -eq 'Auto')
    if ($null -eq $discover) {
        Initialize-McpLegacyClient -Session $Session -TimeoutMs $ConnectTimeoutMs
        if ($null -ne $cacheKey) { $script:McpClientEraCache[$cacheKey] = 'Legacy' }
        return
    }
    $Session.Era = 'Modern'
    $Session.ServerInfo = ConvertTo-McpServerInfoObject -DiscoverResult $discover -ProtocolVersion $Session.ProtocolVersion
    $Session.Name = $Session.ServerInfo.Name
    Set-McpClientCacheEntry -Session $Session -Key 'server/discover' -Value $Session.ServerInfo -CacheHint (Get-McpResultCacheHint -Result $discover)
    if ($null -ne $cacheKey) { $script:McpClientEraCache[$cacheKey] = 'Modern' }
}

function Invoke-McpClientServerRequest {
    <#
    .SYNOPSIS
        Answers a request of a legacy server: ping, and elicitation, sampling and roots through the session's callbacks; sends the response back.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Message,

        # The client request during which the server asked (empty on the GET stream).
        [AllowEmptyString()]
        [string] $RequestMethod = ''
    )

    $id = $Message['id']
    $method = [string] $Message['method']
    $response = $null
    if ($Session.Era -ne 'Legacy') {
        Write-Warning "Ignoring a request '$method' from the server: servers do not send requests in protocol version $($Session.ProtocolVersion)."
        return
    }
    try {
        $result = switch ($method) {
            'ping' { [ordered]@{} }
            { $_ -in @('elicitation/create', 'sampling/createMessage', 'roots/list') } {
                $request = ConvertTo-McpInputRequestObject -Key ([string] $id) -Request $Message -RequestMethod $RequestMethod
                Invoke-McpClientInputCallback -Session $Session -Request $request
            }
            default { throw [McpProtocolException]::new($script:McpErrorCode.MethodNotFound, "Method not found: $method") }
        }
        $response = New-McpResultResponse -Id $id -Result $result
    } catch [McpProtocolException] {
        $response = New-McpErrorResponse -Id $id -ErrorObject (New-McpError -Code $_.Exception.Code -Message $_.Exception.Message)
    } catch [System.InvalidOperationException] {
        # No callback for this kind of request: the client does not offer it.
        $response = New-McpErrorResponse -Id $id -ErrorObject (New-McpError -Code $script:McpErrorCode.MethodNotFound -Message $_.Exception.Message)
    } catch {
        $response = New-McpErrorResponse -Id $id -ErrorObject (New-McpError -Code $script:McpErrorCode.InternalError -Message "The client failed to answer $method : $($_.Exception.Message)")
    }
    $json = ConvertTo-McpJson -InputObject $response
    try {
        if ($Session.Transport.Kind -eq 'Http') {
            Send-McpHttpClientMessage -Session $Session -Json $json -Method $method
        } else {
            Send-McpTransportLine -Transport $Session.Transport -Line $json
        }
    } catch {
        Write-Warning "Sending the answer to the server's $method request failed: $($_.Exception.Message)"
    }
}

function Send-McpLegacyNotificationToSubscription {
    <#
    .SYNOPSIS
        Hands an unsolicited notification of a legacy server to the session's subscriptions that asked for it; invalidates the cache in any case.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Message
    )

    $method = [string] $Message['method']
    $params = if ($Message['params'] -is [System.Collections.IDictionary]) { $Message['params'] } else { $null }
    $delivered = $false
    foreach ($subscription in @($Session.Subscriptions.Values)) {
        if ($subscription.State -ne 'Open' -or $null -eq $subscription.Honoured) { continue }
        if (-not (Test-McpListenerMatch -Honoured $subscription.Honoured -Method $method -Params $params)) { continue }
        Receive-McpSubscriptionNotification -Session $Session -Subscription $subscription -Message $Message
        $delivered = $true
    }
    if (-not $delivered) {
        # Invalidate the cache like a subscription would, and keep the notification on the session.
        $scratch = [pscustomobject]@{ Id = $null; Action = $null; Notifications = [System.Collections.Generic.Queue[object]]::new(); State = 'Open'; Honoured = $null }
        Receive-McpSubscriptionNotification -Session $Session -Subscription $scratch -Message $Message
        $Session.Notifications.Enqueue($Message)
    }
}

function Invoke-McpHttpLegacyStreamLoop {
    <#
    .SYNOPSIS
        Background loop of the GET stream of a legacy session: reads its events into the session inbox, reconnecting with Last-Event-ID; ends when the server refuses the stream (405).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [hashtable] $Stream
    )

    $inbox = $Session.Inbox
    $attempt = 0
    $lastEventId = $null
    while (-not $Stream.StopRequested) {
        $message = New-McpHttpGetMessage -Session $Session -LastEventId $lastEventId
        $response = $null
        try {
            $sendTask = $Session.Transport.Client.SendAsync($message, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $Stream.Cts.Token)
            while (-not $sendTask.IsCompleted -and -not $Stream.StopRequested) { $null = $sendTask.Wait(250) }
            if ($Stream.StopRequested) { break }
            $failure = Get-McpTaskFailure -Task $sendTask
            if ($null -ne $failure) { throw $failure }
            $response = $sendTask.Result
            $mediaType = if ($null -ne $response.Content.Headers.ContentType) { $response.Content.Headers.ContentType.MediaType } else { $null }
            if (-not $response.IsSuccessStatusCode -or $mediaType -ne 'text/event-stream') {
                $Stream.Status = "HTTP $([int] $response.StatusCode)"
                break
            }
            $Stream.Status = 'Open'
            $sse = New-McpSseReader -Stream ($response.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
            try {
                while (-not $Stream.StopRequested) {
                    $received = Receive-McpSseEvent -Sse $sse -TimeoutMs 250
                    if ($received.Status -eq 'Timeout') { continue }
                    if ($received.Status -eq 'Eof') { break }
                    if ($null -ne $received.Id) { $lastEventId = $received.Id }
                    if ([string]::IsNullOrWhiteSpace($received.Data) -or ($null -ne $received.Event -and $received.Event -ne 'message')) { continue }
                    $attempt = 0
                    $inbox.Enqueue(@{ Kind = 'Legacy'; Json = $received.Data })
                }
            } finally {
                try { $sse.Reader.Dispose() } catch { Write-Debug 'Disposing the SSE reader failed.' }
            }
        } catch {
            $Stream.Status = "failed: $($_.Exception.Message)"
        } finally {
            if ($null -ne $response) { try { $response.Dispose() } catch { Write-Debug 'Disposing the GET response failed.' } }
            $message.Dispose()
        }
        if ($Stream.StopRequested) { break }
        $attempt++
        if ($attempt -gt 5) { break }
        $until = [datetime]::UtcNow.AddSeconds([math]::Min(16, [math]::Pow(2, $attempt - 1)))
        while ([datetime]::UtcNow -lt $until -and -not $Stream.StopRequested) { Start-Sleep -Milliseconds 100 }
    }
    if ($Stream.Status -eq 'Open') { $Stream.Status = 'Closed' }
}

function Start-McpLegacyClientStream {
    <#
    .SYNOPSIS
        Opens the GET stream of a legacy HTTP session in the background (once per session).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal background reader.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session
    )

    if ($Session.Kind -ne 'Http' -or $null -ne $Session.LegacyStream) { return }
    $stream = @{ StopRequested = $false; Cts = [System.Threading.CancellationTokenSource]::new(); Status = 'Opening'; Reader = $null }
    $stream.Reader = New-McpClientBackgroundRunspace -FunctionName 'Invoke-McpHttpLegacyStreamLoop' -Parameters @{ Session = $Session; Stream = $stream }
    $Session.LegacyStream = $stream
}

function Stop-McpLegacyClientStream {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal background reader.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session
    )

    $stream = $Session.LegacyStream
    if ($null -eq $stream) { return }
    $stream.StopRequested = $true
    try { $stream.Cts.Cancel() } catch { Write-Debug 'Cancelling the GET stream failed.' }
    Stop-McpClientBackgroundRunspace -Background $stream.Reader -TimeoutMs 5000
    try { $stream.Cts.Dispose() } catch { Write-Debug 'Disposing the token source failed.' }
    $Session.LegacyStream = $null
}

function Close-McpLegacyClientSession {
    <#
    .SYNOPSIS
        Ends a legacy HTTP session: stops the GET stream and sends DELETE with the session id (a refusal is fine).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The caller (Disconnect-McpServer) owns the ShouldProcess decision.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session
    )

    Stop-McpLegacyClientStream -Session $Session
    if ($Session.Kind -ne 'Http' -or -not $Session.SessionId -or $Session.Transport.Closed) { return }
    $message = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Delete, $Session.Transport.Url)
    Add-McpHttpSessionHeader -Session $Session -Message $message
    $cts = [System.Threading.CancellationTokenSource]::new()
    try {
        $task = $Session.Transport.Client.SendAsync($message, $cts.Token)
        if (-not (Wait-McpTask -Task $task -Deadline ([datetime]::UtcNow.AddSeconds(5)))) { $cts.Cancel() }
        elseif ($task.IsCompletedSuccessfully) { $task.Result.Dispose() }
    } catch {
        Write-Debug "DELETE of session $($Session.SessionId) failed: $($_.Exception.Message)"
    } finally {
        $cts.Dispose()
        $message.Dispose()
    }
}
