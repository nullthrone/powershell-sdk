# The dispatcher: the loop that owns a transport, decodes inbound messages, answers server/discover, the list
# methods and everything that runs no user code itself, hands tools/call, resources/read, prompts/get and
# completion/complete with a handler to the worker runspace pool, forwards the workers' responses and
# notifications, honours notifications/cancelled and shuts down on end of stream or Stop-McpServer.
#
# Over stdio and in memory all messages share one line writer. Over Streamable HTTP every request owns a
# channel (its HTTP response, sent as one JSON object or as a request-scoped SSE stream); accepting
# connections, header validation and SSE writing live in HttpServer.ps1.
#
# A dual-era server also serves legacy sessions (initialize handshake, LegacySession.ps1): every request is
# routed by its era (Get-McpMessageEra), legacy responses are converted in Send-McpDispatcherMessage and in the
# worker, and the requests of a legacy session are keyed with the session's prefix.

function Get-McpRequestKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Id
    )

    if ($Id -is [string]) { return 's:' + $Id }
    'n:' + ([System.Management.Automation.LanguagePrimitives]::ConvertTo($Id, [string]))
}

function New-McpWorkerPool {
    <#
    .SYNOPSIS
        The hostless runspace pool that runs handlers: the module, the registered handlers and preferences.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a runspace pool for the caller (Start-McpServer), which owns the ShouldProcess decision.')]
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Runspaces.RunspacePool])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server
    )

    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    if ($IsWindows) {
        $sessionState.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
    }
    $modules = [System.Collections.Generic.List[string]]::new()
    $modules.Add($script:McpModuleManifestPath)
    foreach ($handler in Get-McpServerHandler -Server $Server) {
        if ($handler.ModulePath -and -not $modules.Contains($handler.ModulePath)) {
            $modules.Add($handler.ModulePath)
        } elseif (-not $handler.ModulePath -and $handler.ModuleName -and -not $modules.Contains($handler.ModuleName)) {
            $modules.Add($handler.ModuleName)
        }
        if ($handler.Definition -and $handler.Kind -in @('ScriptBlock', 'Function')) {
            $sessionState.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($handler.CommandName, $handler.Definition))
        }
    }
    $sessionState.ImportPSModule([string[]] $modules.ToArray())
    foreach ($preference in @(@('ProgressPreference', 'SilentlyContinue'), @('ErrorActionPreference', 'Continue'), @('WarningPreference', 'Continue'), @('InformationPreference', 'Continue'), @('VerbosePreference', 'SilentlyContinue'))) {
        $sessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new($preference[0], $preference[1], 'MCP worker preference'))
    }
    $pool = [runspacefactory]::CreateRunspacePool($sessionState)
    $null = $pool.SetMinRunspaces(1)
    $null = $pool.SetMaxRunspaces([int] $Server.Options.MaxConcurrency)
    $pool.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $pool.Open()
    $pool
}

function Invoke-McpDispatcher {
    <#
    .SYNOPSIS
        Serves a transport until end of stream or Stop-McpServer; returns when the server has shut down.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [Parameter(Mandatory)]
        [hashtable] $Transport,

        [ValidateRange(0, 3600)]
        [int] $ShutdownGraceSeconds = 5
    )

    $state = @{
        Server      = $Server
        Transport   = $Transport
        Outbound    = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
        Signal      = [System.Threading.AutoResetEvent]::new($false)
        InFlight    = @{}
        Listeners   = @{}
        Pool        = $null
        EofReceived = $false
        Stopping    = $false
        # Legacy sessions: the process-wide one of a line transport, and those of Streamable HTTP by Mcp-Session-Id.
        LineSession = $null
        Sessions    = @{}
        ServerInfo  = Get-McpServerInfoObject -Server $Server
        LogLevel    = $Server.Options.LogLevel
    }
    $Server.State.Signal = $state.Signal
    # Fan-out cmdlets (Send-McpToolListChanged ...) queue notifications for the listeners here, from any runspace.
    $Server.State.Sink = @{ Queue = $state.Outbound; Signal = $state.Signal }
    # The open subscriptions, for diagnostics (a Hashtable: one writer, the dispatcher, and any number of readers).
    $Server.State.Listeners = $state.Listeners
    $Server.State.Started = $true
    $Server.State.StopRequested = $false
    $where = if ($Transport.Kind -eq 'Http') { "Streamable HTTP at $($Transport.Prefix)" } else { $Transport.Kind }
    Write-McpStderr -Level Info -Threshold $state.LogLevel -Logger $Server.Name -Message "Server '$($Server.Name)' $($Server.Version) starting on $where with $($Server.Tools.Count) tool(s), $($Server.Resources.Count + $Server.ResourceTemplates.Count) resource(s) and template(s), $($Server.Prompts.Count) prompt(s)."
    if (-not $Server.Options.RequestStateKeyGiven -and $Transport.Kind -eq 'Http') {
        Write-McpStderr -Level Info -Threshold $state.LogLevel -Logger $Server.Name -Message 'requestState of input requests is signed with a random per-process key; pass New-McpServer -RequestStateKey to share it between instances.'
    }
    try {
        $state.Pool = New-McpWorkerPool -Server $Server
        if ($Transport.Kind -eq 'Http') {
            Invoke-McpHttpDispatcherLoop -State $state -ShutdownGraceSeconds $ShutdownGraceSeconds
        } else {
            Invoke-McpLineDispatcherLoop -State $state -ShutdownGraceSeconds $ShutdownGraceSeconds
        }
    } finally {
        Close-McpAllListener -State $state
        foreach ($session in @(Get-McpLegacySession -State $state)) { Close-McpLegacySession -State $state -Session $session -Reason 'ended: the server stopped' }
        Stop-McpAllInFlightRequest -State $state
        Send-McpOutboundQueue -State $state
        if ($null -ne $state.Pool) {
            try { $state.Pool.Close(); $state.Pool.Dispose() } catch { Write-Debug 'Closing the runspace pool failed.' }
        }
        Close-McpTransport -Transport $Transport
        $Server.State.Started = $false
        $Server.State.Signal = $null
        $Server.State.Sink = $null
        $Server.State.Listeners = $null
        Write-McpStderr -Level Info -Threshold $state.LogLevel -Logger $Server.Name -Message 'Server stopped.'
    }
}

function Invoke-McpLineDispatcherLoop {
    <#
    .SYNOPSIS
        The dispatcher loop of the line-based transports (stdio, in memory): reads lines until end of stream or Stop-McpServer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [int] $ShutdownGraceSeconds = 5
    )

    $server = $State.Server
    $transport = $State.Transport
    $readTask = Read-McpTransportLineAsync -Transport $transport
    $stopDeadline = $null
    while ($true) {
        $handles = if ($State.EofReceived) { @($State.Signal) } else { @((Get-McpTaskWaitHandle -Task $readTask), $State.Signal) }
        $index = [System.Threading.WaitHandle]::WaitAny([System.Threading.WaitHandle[]] $handles, 250)
        if (-not $State.EofReceived -and $index -eq 0) {
            $line = Complete-McpTransportRead -Transport $transport -Task $readTask
            if ($null -eq $line) {
                $State.EofReceived = $true
                Write-McpStderr -Level Info -Threshold $State.LogLevel -Logger $server.Name -Message 'End of input; shutting down.'
            } else {
                Invoke-McpInboundLine -State $State -Line $line
                $readTask = Read-McpTransportLineAsync -Transport $transport
            }
        }
        Send-McpOutboundQueue -State $State
        Update-McpInFlightRequest -State $State
        if ($State.Stopping) { break }
        if ($State.EofReceived -or $server.State.StopRequested) {
            if ($State.Listeners.Count -gt 0) { Close-McpAllListener -State $State }
            if ($State.InFlight.Count -eq 0) { break }
            if ($null -eq $stopDeadline) { $stopDeadline = [datetime]::UtcNow.AddSeconds($ShutdownGraceSeconds) }
            if ([datetime]::UtcNow -ge $stopDeadline) { break }
        }
    }
}

function Send-McpDispatcherMessage {
    <#
    .SYNOPSIS
        Writes a message built by the dispatcher: to the request's HTTP channel, or to the shared line transport.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Message,

        [AllowNull()]
        [hashtable] $Channel,

        # The era of the request being answered: legacy results and errors are converted (Era.ps1).
        [ValidateSet('Modern', 'Legacy')]
        [string] $Era = 'Modern'
    )

    $Message = ConvertTo-McpEraMessage -Message $Message -Era $Era
    if ($null -ne $Channel -and $Channel.Kind -eq 'Http') {
        $errorCode = $null
        if ($Message.Contains('error') -and $Message['error'] -is [System.Collections.IDictionary] -and $Message['error'].Contains('code')) { $errorCode = $Message['error']['code'] }
        $null = Send-McpHttpResponse -State $State -Channel $Channel -Json (ConvertTo-McpJson -InputObject $Message) -ErrorCode $errorCode
        return
    }
    try {
        Send-McpTransportLine -Transport $State.Transport -Line (ConvertTo-McpJson -InputObject $Message)
    } catch [System.IO.IOException] {
        Write-McpStderr -Level Warning -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Writing to the transport failed: $($_.Exception.Message)"
        $State.Stopping = $true
    }
}

function Send-McpOutboundQueue {
    <#
    .SYNOPSIS
        Forwards the responses and notifications that workers enqueued: to the request's channel over HTTP, to the line writer otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $item = $null
    while ($State.Outbound.TryDequeue([ref] $item)) {
        if ($item.Kind -eq 'Broadcast') {
            $params = if ($item.ParamsJson) { ConvertFrom-McpJson -Json $item.ParamsJson } else { $null }
            Send-McpListenerNotification -State $State -Method $item.Method -Params $params
            if ($State.Stopping) { return }
            Send-McpLegacyNotification -State $State -Method $item.Method -Params $params
            if ($State.Stopping) { return }
            continue
        }
        $entry = $null
        if ($null -ne $item.RequestId) {
            $key = [string] $item.KeyPrefix + (Get-McpRequestKey -Id $item.RequestId)
            if ($State.InFlight.ContainsKey($key)) { $entry = $State.InFlight[$key] }
        }
        if ($item.Kind -eq 'ServerRequest') {
            Send-McpServerRequest -State $State -Item $item -Entry $entry
            if ($State.Stopping) { return }
            continue
        }
        if ($null -ne $entry -and ($entry.Cancelled -or $entry.Responded)) { continue }
        if ($item.Kind -eq 'Response' -and $null -ne $entry) { $entry.Responded = $true }
        Write-McpStderr -Level Debug -Threshold $State.LogLevel -Logger $State.Server.Name -Message ("-> {0} id={1} ({2} bytes)" -f $item.Kind, $item.RequestId, $item.Json.Length)
        if ($State.Transport.Kind -eq 'Http') {
            if ($null -eq $entry) {
                Write-McpStderr -Level Debug -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Dropping a $($item.Kind) for request $($item.RequestId): no open HTTP response."
                continue
            }
            $delivered = if ($item.Kind -eq 'Notification') {
                Send-McpHttpNotification -State $State -Channel $entry.Channel -Json $item.Json
            } else {
                Send-McpHttpResponse -State $State -Channel $entry.Channel -Json $item.Json -ErrorCode $item.ErrorCode
            }
            if (-not $delivered -and -not $entry.Cancelled) {
                Write-McpStderr -Level Info -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Request $($entry.Id) ($($entry.Label)): the client disconnected; cancelling."
                Stop-McpInFlightRequest -Entry $entry
                $entry.Responded = $true
            }
            continue
        }
        try {
            Send-McpTransportLine -Transport $State.Transport -Line $item.Json
        } catch [System.IO.IOException] {
            Write-McpStderr -Level Warning -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Writing to the transport failed: $($_.Exception.Message)"
            $State.Stopping = $true
            return
        }
    }
}

function Invoke-McpInboundLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    $message = $null
    try {
        $message = ConvertFrom-McpJson -Json $Line
    } catch {
        Send-McpDispatcherMessage -State $State -Message (New-McpErrorResponse -Id $null -ErrorObject (New-McpError -Code $script:McpErrorCode.ParseError -Message 'Parse error'))
        return
    }
    $kind = Get-McpMessageKind -Message $message
    Write-McpStderr -Level Debug -Threshold $State.LogLevel -Logger $State.Server.Name -Message ("<- {0} {1} {2}" -f $kind, $(if ($message -is [System.Collections.IDictionary] -and $message.Contains('method')) { $message['method'] } else { '' }), $(if ($message -is [System.Collections.IDictionary] -and $message.Contains('id')) { "id=$($message['id'])" } else { '' }))
    switch ($kind) {
        'Request' { Invoke-McpInboundRequest -State $State -Message $message }
        'Notification' { Invoke-McpInboundNotification -State $State -Message $message }
        { $_ -in @('Response', 'ErrorResponse') } {
            # Answers to server-initiated requests of the legacy session; modern clients send no responses.
            if ($null -eq $State.LineSession -or -not (Complete-McpLegacyServerRequest -Session $State.LineSession -Message $message)) {
                Write-McpStderr -Level Debug -Threshold $State.LogLevel -Logger $State.Server.Name -Message 'Ignoring a JSON-RPC response that answers no open server request.'
            }
        }
        default {
            $id = $null
            if ($message -is [System.Collections.IDictionary] -and $message.Contains('id') -and (Test-McpRequestId -Id $message['id'])) { $id = $message['id'] }
            Send-McpDispatcherMessage -State $State -Message (New-McpErrorResponse -Id $id -ErrorObject (New-McpError -Code $script:McpErrorCode.InvalidRequest -Message 'Invalid Request'))
        }
    }
}

function Invoke-McpInboundNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Message,

        # The legacy session of a Streamable HTTP request (Mcp-Session-Id); line transports use the process-wide one.
        [AllowNull()]
        [hashtable] $Session
    )

    $method = [string] $Message['method']
    if ($null -eq $Session -and $State.Transport.Kind -ne 'Http') { $Session = $State.LineSession }
    if ($method -eq 'notifications/initialized' -and $null -ne $Session) {
        $Session.Initialized = $true
        return
    }
    if ($method -ne 'notifications/cancelled') {
        Write-McpStderr -Level Debug -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Ignoring notification '$method'."
        return
    }
    $params = if ($Message.Contains('params')) { $Message['params'] } else { $null }
    if ($params -isnot [System.Collections.IDictionary] -or -not $params.Contains('requestId') -or -not (Test-McpRequestId -Id $params['requestId'])) { return }
    $key = Get-McpRequestKey -Id $params['requestId']
    if ($null -ne $Session -and $State.InFlight.ContainsKey($Session.KeyPrefix + $key)) { $key = $Session.KeyPrefix + $key }
    if ($State.Listeners.ContainsKey($key)) {
        Remove-McpListener -State $State -Key $key -Reason 'cancelled by the client'
        return
    }
    if (-not $State.InFlight.ContainsKey($key)) { return }
    $entry = $State.InFlight[$key]
    if ($entry.Cancelled -or $entry.Responded) { return }
    $reason = if ($params.Contains('reason') -and $params['reason'] -is [string]) { $params['reason'] } else { 'no reason given' }
    Write-McpStderr -Level Info -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Request $($params['requestId']) cancelled by the client ($reason)."
    Stop-McpInFlightRequest -Entry $entry
}

function Stop-McpInFlightRequest {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal request bookkeeping.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Entry
    )

    $Entry.Cancelled = $true
    try { $Entry.Cts.Cancel() } catch { Write-Debug 'Cancelling the request token failed.' }
    try { $null = $Entry.PowerShell.BeginStop($null, $null) } catch { Write-Debug 'Stopping the worker pipeline failed.' }
}

function Close-McpRequestChannel {
    <#
    .SYNOPSIS
        Closes the HTTP channel of a finished request; a request that ends without a response gets an internal error first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [hashtable] $Entry,

        [string] $Reason = 'The handler produced no response.'
    )

    $channel = $Entry.Channel
    if ($null -eq $channel -or $channel.Kind -ne 'Http' -or $channel.Closed) { return }
    if (-not $Entry.Responded) {
        $Entry.Responded = $true
        $null = Send-McpHttpResponse -State $State -Channel $channel -Json (ConvertTo-McpJson -InputObject (New-McpErrorResponse -Id $Entry.Id -ErrorObject (New-McpError -Code $script:McpErrorCode.InternalError -Message $Reason))) -ErrorCode $script:McpErrorCode.InternalError
    }
    Close-McpHttpChannel -State $State -Channel $channel
}

function Stop-McpAllInFlightRequest {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal request bookkeeping.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    foreach ($entry in @($State.InFlight.Values)) {
        if (-not $entry.Cancelled -and -not $entry.Responded) { Stop-McpInFlightRequest -Entry $entry }
        Close-McpRequestChannel -State $State -Entry $entry -Reason 'The server is shutting down.'
    }
    foreach ($entry in @($State.InFlight.Values)) {
        try { $null = $entry.PowerShell.InvocationStateInfo; $entry.PowerShell.Dispose() } catch { Write-Debug 'Disposing a worker failed.' }
        try { $entry.Cts.Dispose() } catch { Write-Debug 'Disposing a token source failed.' }
    }
    $State.InFlight.Clear()
}

function Update-McpInFlightRequest {
    <#
    .SYNOPSIS
        Housekeeping: disposes finished workers, answers crashed ones and enforces the request timeout.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal request bookkeeping.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $timeout = [int] $State.Server.Options.RequestTimeoutSeconds
    foreach ($key in @($State.InFlight.Keys)) {
        if (-not $State.InFlight.ContainsKey($key)) { continue }
        $entry = $State.InFlight[$key]
        $invocationState = $entry.PowerShell.InvocationStateInfo.State
        $finished = $invocationState -in @([System.Management.Automation.PSInvocationState]::Completed, [System.Management.Automation.PSInvocationState]::Failed, [System.Management.Automation.PSInvocationState]::Stopped)
        if (-not $finished) {
            if ($timeout -gt 0 -and -not $entry.Cancelled -and -not $entry.Responded -and ([datetime]::UtcNow - $entry.StartedAt).TotalSeconds -gt $timeout) {
                Write-McpStderr -Level Warning -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Request $($entry.Id) ($($entry.Label)) timed out after $timeout s."
                Stop-McpInFlightRequest -Entry $entry
                $entry.Responded = $true
                Send-McpDispatcherMessage -State $State -Channel $entry.Channel -Era $entry.Era -Message (New-McpErrorResponse -Id $entry.Id -ErrorObject (New-McpError -Code $script:McpErrorCode.InternalError -Message "The request timed out after $timeout seconds."))
            }
            continue
        }
        # A worker enqueues its response before it completes: deliver whatever is queued while the entry exists.
        Send-McpOutboundQueue -State $State
        if ($invocationState -eq [System.Management.Automation.PSInvocationState]::Failed -and -not $entry.Cancelled -and -not $entry.Responded) {
            $reason = $entry.PowerShell.InvocationStateInfo.Reason
            $text = if ($reason) { $reason.Message } else { 'The worker failed.' }
            Write-McpStderr -Level Error -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Request $($entry.Id) ($($entry.Label)) failed in the worker: $text"
            $entry.Responded = $true
            Send-McpDispatcherMessage -State $State -Channel $entry.Channel -Era $entry.Era -Message (New-McpErrorResponse -Id $entry.Id -ErrorObject (New-McpError -Code $script:McpErrorCode.InternalError -Message $text))
        }
        Close-McpRequestChannel -State $State -Entry $entry
        try { $entry.PowerShell.Dispose() } catch { Write-Debug 'Disposing a worker failed.' }
        try { $entry.Cts.Dispose() } catch { Write-Debug 'Disposing a token source failed.' }
        $State.InFlight.Remove($key)
    }
}

function Send-McpServerRequest {
    <#
    .SYNOPSIS
        Delivers a server-initiated request of a legacy session: on the line transport, on the SSE stream of the request that asked, or on the session's GET stream.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [hashtable] $Item,

        [AllowNull()]
        [hashtable] $Entry
    )

    if ($null -ne $Entry -and ($Entry.Cancelled -or $Entry.Responded)) { return }
    Write-McpStderr -Level Debug -Threshold $State.LogLevel -Logger $State.Server.Name -Message ("-> ServerRequest {0} for request {1}" -f $Item.ServerRequestId, $Item.RequestId)
    if ($State.Transport.Kind -ne 'Http') {
        try {
            Send-McpTransportLine -Transport $State.Transport -Line $Item.Json
        } catch [System.IO.IOException] {
            Write-McpStderr -Level Warning -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Writing to the transport failed: $($_.Exception.Message)"
            $State.Stopping = $true
        }
        return
    }
    $session = if ($null -ne $Entry) { $Entry.Session } else { $null }
    if ($null -ne $Entry -and $null -ne $Entry.Channel -and -not $Entry.Channel.Closed -and (Send-McpHttpNotification -State $State -Channel $Entry.Channel -Json $Item.Json)) { return }
    if ($null -ne $session -and $null -ne $session.GetChannel -and (Write-McpSseChunk -State $State -Channel $session.GetChannel -Text "event: message`ndata: $($Item.Json)`n`n")) { return }
    if ($null -ne $session) {
        Stop-McpLegacyServerRequest -Session $session -Id $Item.ServerRequestId -Reason 'The request could not be delivered to the client: no open stream.'
    }
}

function Invoke-McpInboundRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Message,

        [AllowNull()]
        [hashtable] $Channel,

        # The legacy session of a Streamable HTTP request, resolved from its Mcp-Session-Id header.
        [AllowNull()]
        [hashtable] $Session
    )

    $server = $State.Server
    $id = $Message['id']
    $method = [string] $Message['method']
    $params = if ($Message.Contains('params')) { $Message['params'] } else { $null }
    $isHttp = $null -ne $Channel -and $Channel.Kind -eq 'Http'
    $era = Get-McpMessageEra -State $State -Method $method -Params $params -Session $Session -Http:$isHttp
    # A modern-only server answers initialize with -32022 in the modern shape (the versions it supports).
    if ($method -ceq 'initialize' -and @(Get-McpServerVersion -Server $server -Era Legacy).Count -eq 0) { $era = 'Modern' }
    if ($era -eq 'Legacy' -and $null -eq $Session -and -not $isHttp) { $Session = $State.LineSession }
    if ($isHttp) { $Channel.Era = $era }
    $reply = @{ State = $State; Channel = $Channel; Era = $era }
    $key = Get-McpRequestKey -Id $id
    if ($null -ne $Session) { $key = $Session.KeyPrefix + $key }
    if ($isHttp) { $Channel.RequestKey = $key }
    if ($State.InFlight.ContainsKey($key) -and ($State.InFlight[$key].Responded -or $State.InFlight[$key].Cancelled)) {
        # Answered or cancelled, only its worker is still winding down: the client may reuse the id. The entry
        # stays under a private key until Update-McpInFlightRequest disposes the worker.
        $State.InFlight["$key#retired-" + [guid]::NewGuid().ToString('n')] = $State.InFlight[$key]
        $State.InFlight.Remove($key)
    }
    if ($State.InFlight.ContainsKey($key) -or $State.Listeners.ContainsKey($key)) {
        Send-McpDispatcherMessage @reply -Message (New-McpErrorResponse -Id $id -ErrorObject (New-McpError -Code $script:McpErrorCode.InvalidRequest -Message "A request with id '$id' is already in flight."))
        return
    }
    try {
        if ($method -ceq 'initialize') {
            if ($null -ne $Session -or (-not $isHttp -and $null -ne $State.LineSession)) {
                throw [McpProtocolException]::new($script:McpErrorCode.InvalidRequest, 'The session is already initialized.')
            }
            $sessionId = if ($isHttp) { [guid]::NewGuid().ToString() } else { $null }
            $opened = Invoke-McpLegacyInitialize -Server $server -Params $params -SessionId $sessionId
            if ($isHttp) {
                $State.Sessions[$sessionId] = $opened
                $Channel.Headers = @{ 'Mcp-Session-Id' = $sessionId }
            } else {
                $State.LineSession = $opened
            }
            $client = $opened.ClientInfo
            Write-McpStderr -Level Info -Threshold $State.LogLevel -Logger $server.Name -Message ("Legacy session {0}opened: protocol version {1}, client {2} {3}." -f $(if ($sessionId) { "$sessionId " } else { '' }), $opened.ProtocolVersion, $client['name'], $client['version'])
            Send-McpDispatcherMessage @reply -Message (New-McpResultResponse -Id $id -Result (Get-McpLegacyInitializeResult -Server $server -Session $opened))
            return
        }
        if ($era -eq 'Legacy') {
            $Session.LastSeen = [datetime]::UtcNow
            $legacyResult = Invoke-McpLegacyMethod -Server $server -Session $Session -Method $method -Params $params
            if ($null -ne $legacyResult) {
                Send-McpDispatcherMessage @reply -Message (New-McpResultResponse -Id $id -Result $legacyResult)
                return
            }
            if ($method -in @('server/discover', 'subscriptions/listen')) {
                throw [McpProtocolException]::new($script:McpErrorCode.MethodNotFound, "Method not found: $method (revision $($Session.ProtocolVersion) of this session does not have it).")
            }
            $meta = Get-McpLegacyRequestMeta -Session $Session -Params $params
        } else {
            $modernVersions = @(Get-McpServerVersion -Server $server -Era Modern)
            if ($modernVersions.Count -eq 0) {
                # A legacy-only server answers like the servers of those revisions before initialize.
                throw [McpProtocolException]::new($script:McpErrorCode.InvalidRequest, "The server is not initialized: send initialize first (protocol versions $((Get-McpServerVersion -Server $server -Era Legacy) -join ', ')).")
            }
            if ($method -in $script:McpLegacyOnlyMethods) {
                throw [McpProtocolException]::new($script:McpErrorCode.MethodNotFound, "Method not found: $method (removed in revision 2026-07-28; available in a legacy session after initialize).")
            }
            $meta = Get-McpRequestMeta -Params $params -SupportedVersions $modernVersions
        }
        if ($null -eq $params) { $params = [ordered]@{} }
        $worker = @{ State = $State; Id = $id; Key = $key; Meta = $meta; Channel = $Channel; Era = $era; Session = $Session }
        switch ($method) {
            'server/discover' {
                Send-McpDispatcherMessage @reply -Message (New-McpResultResponse -Id $id -Result (Get-McpDiscoverResult -Server $server))
            }
            'tools/list' {
                Send-McpDispatcherMessage @reply -Message (New-McpResultResponse -Id $id -Result (Get-McpToolListResult -Server $server -Cursor (Get-McpCursorParam -Params $params)))
            }
            'tools/call' {
                if (-not $params.Contains('name') -or $params['name'] -isnot [string]) {
                    throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "tools/call requires a string parameter 'name'.")
                }
                $arguments = $null
                if ($params.Contains('arguments') -and $null -ne $params['arguments']) {
                    $arguments = $params['arguments']
                    if ($arguments -isnot [System.Collections.IDictionary]) {
                        throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "tools/call 'arguments' must be an object.")
                    }
                }
                $registration = Get-McpToolRegistration -Server $server -Name $params['name']
                if ($isHttp -and $era -eq 'Modern') {
                    Test-McpToolParameterHeader -HeaderParameters $registration.HeaderParameters -Arguments $arguments -Headers $Channel.Context.Request.Headers
                }
                $payload = New-McpInputPayload -Server $server -Method $method -Name $registration.Name -Params $params
                $payload['Arguments'] = $arguments
                Start-McpWorkerRequest @worker -Kind Tool -Method $method -Name $registration.Name -Registration $registration -Payload $payload
            }
            'subscriptions/listen' {
                Start-McpListener -State $State -Id $id -Params $params -Channel $Channel
            }
            'resources/list' {
                Assert-McpServerCapability -Server $server -Capability resources -Method $method
                Send-McpDispatcherMessage @reply -Message (New-McpResultResponse -Id $id -Result (Get-McpResourceListResult -Server $server -Cursor (Get-McpCursorParam -Params $params)))
            }
            'resources/templates/list' {
                Assert-McpServerCapability -Server $server -Capability resources -Method $method
                Send-McpDispatcherMessage @reply -Message (New-McpResultResponse -Id $id -Result (Get-McpResourceTemplateListResult -Server $server -Cursor (Get-McpCursorParam -Params $params)))
            }
            'resources/read' {
                Assert-McpServerCapability -Server $server -Capability resources -Method $method
                $uri = $params['uri']
                if (-not (Test-McpResourceUri -Uri $uri)) {
                    throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "resources/read requires a parameter 'uri' with an absolute URI.")
                }
                $payload = New-McpInputPayload -Server $server -Method $method -Name $uri -Params $params
                $resolved = Resolve-McpResourceRequest -Server $server -Uri $uri
                $registration = $resolved.Registration
                $cacheHint = Get-McpResourceCacheHint -Server $server -Registration $registration
                if ($registration.Source -eq 'Content') {
                    $result = Invoke-McpResourceHandler -Registration $registration -Uri $uri -CacheHint $cacheHint
                    Send-McpDispatcherMessage @reply -Message (New-McpResultResponse -Id $id -Result (Add-McpResultMeta -Result $result -Server $server))
                } else {
                    $payload['Variables'] = $resolved.Variables
                    $payload['CacheHint'] = $cacheHint
                    Start-McpWorkerRequest @worker -Kind Resource -Method $method -Name $uri -Registration $registration -Payload $payload
                }
            }
            'prompts/list' {
                Assert-McpServerCapability -Server $server -Capability prompts -Method $method
                Send-McpDispatcherMessage @reply -Message (New-McpResultResponse -Id $id -Result (Get-McpPromptListResult -Server $server -Cursor (Get-McpCursorParam -Params $params)))
            }
            'prompts/get' {
                Assert-McpServerCapability -Server $server -Capability prompts -Method $method
                $registration = Get-McpPromptRegistration -Server $server -Name $params['name']
                $payload = New-McpInputPayload -Server $server -Method $method -Name $registration.Name -Params $params
                $payload['Arguments'] = Test-McpPromptArgument -Registration $registration -Arguments $(if ($params.Contains('arguments')) { $params['arguments'] } else { $null })
                Start-McpWorkerRequest @worker -Kind Prompt -Method $method -Name $registration.Name -Registration $registration -Payload $payload
            }
            'completion/complete' {
                Assert-McpServerCapability -Server $server -Capability completions -Method $method
                $request = Resolve-McpCompletionRequest -Server $server -Params $params
                if ($null -eq $request.Source -or $null -eq $request.Source.Handler) {
                    Send-McpDispatcherMessage @reply -Message (New-McpResultResponse -Id $id -Result (Add-McpResultMeta -Result (Invoke-McpCompletionHandler -Request $request) -Server $server))
                } else {
                    Start-McpWorkerRequest @worker -Kind Completion -Method $method -Name $request.Label -Registration $null -Payload @{ Completion = $request }
                }
            }
            default {
                throw [McpProtocolException]::new($script:McpErrorCode.MethodNotFound, "Method not found: $method")
            }
        }
    } catch [McpProtocolException] {
        Send-McpDispatcherMessage @reply -Message (New-McpErrorResponse -Id $id -ErrorObject (ConvertTo-McpErrorObject -Exception $_.Exception -Era $era))
    } catch {
        $exception = $_.Exception
        if ($exception -is [System.Management.Automation.RuntimeException] -and $exception.InnerException -is [McpProtocolException]) {
            Send-McpDispatcherMessage @reply -Message (New-McpErrorResponse -Id $id -ErrorObject (ConvertTo-McpErrorObject -Exception $exception.InnerException -Era $era))
            return
        }
        Write-McpStderr -Level Error -Threshold $State.LogLevel -Logger $server.Name -Message "Request $id ($method) failed: $($exception.Message)"
        Send-McpDispatcherMessage @reply -Message (New-McpErrorResponse -Id $id -ErrorObject (New-McpError -Code $script:McpErrorCode.InternalError -Message $exception.Message))
    }
}

function New-McpInputPayload {
    <#
    .SYNOPSIS
        The envelope members of a request that may ask for input: the verified answers and handler state of earlier rounds and what the worker needs to sign the next requestState.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory table.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [Parameter(Mandatory)]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Params
    )

    $requestInput = Get-McpRequestInput -Server $Server -Method $Method -Name $Name -Params $Params
    @{
        InputResponses         = $requestInput.InputResponses
        HandlerState           = $requestInput.HandlerState
        RequestDigest          = $requestInput.Digest
        RequestStateKey        = $Server.Options.RequestStateKey
        RequestStateTtlSeconds = $Server.Options.RequestStateTtlSeconds
    }
}

function Get-McpCursorParam {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $Params
    )

    if ($null -ne $Params -and $Params.Contains('cursor')) { return $Params['cursor'] }
    $null
}

function Assert-McpServerCapability {
    <#
    .SYNOPSIS
        Answers methods of a capability the server does not declare (no registrations) with -32601.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [Parameter(Mandatory)]
        [ValidateSet('resources', 'prompts', 'completions')]
        [string] $Capability,

        [Parameter(Mandatory)]
        [string] $Method
    )

    $declared = switch ($Capability) {
        'resources' { Test-McpResourceCapability -Server $Server }
        'prompts' { $Server.Prompts.Count -gt 0 }
        'completions' { Test-McpCompletionCapability -Server $Server }
    }
    if (-not $declared) {
        throw [McpProtocolException]::new($script:McpErrorCode.MethodNotFound, "Method not found: $Method (the server does not declare the $Capability capability).")
    }
}

function Start-McpWorkerRequest {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal request bookkeeping.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [object] $Id,

        [Parameter(Mandatory)]
        [ValidateSet('Tool', 'Resource', 'Prompt', 'Completion')]
        [string] $Kind,

        [Parameter(Mandatory)]
        [string] $Method,

        # The tool or prompt name, the resource URI or the completion target.
        [Parameter(Mandatory)]
        [string] $Name,

        [AllowNull()]
        [pscustomobject] $Registration,

        # Kind-specific envelope members: Arguments, Variables, CacheHint or Completion, and the input members of New-McpInputPayload.
        [hashtable] $Payload = @{},

        [Parameter(Mandatory)]
        [hashtable] $Meta,

        [AllowNull()]
        [hashtable] $Channel,

        # The in-flight key (the request id, prefixed with the session's prefix in a legacy session).
        [Parameter(Mandatory)]
        [string] $Key,

        [ValidateSet('Modern', 'Legacy')]
        [string] $Era = 'Modern',

        [AllowNull()]
        [hashtable] $Session
    )

    $server = $State.Server
    $cts = [System.Threading.CancellationTokenSource]::new()
    $keyPrefix = if ($null -ne $Session) { $Session.KeyPrefix } else { '' }
    $envelope = @{
        RequestId         = $Id
        Kind              = $Kind
        Method            = $Method
        Name              = $Name
        Registration      = $Registration
        Meta              = $Meta
        Era               = $Era
        Legacy            = if ($null -ne $Session) { @{ Pending = $Session.Pending; TimeoutSeconds = [int] $server.Options.RequestTimeoutSeconds } } else { $null }
        Sink              = @{ Queue = $State.Outbound; Signal = $State.Signal; KeyPrefix = $keyPrefix }
        CancellationToken = $cts.Token
        ServerName        = $server.Name
        ServerLogLevel    = $server.Options.LogLevel
        ServerInfo        = $State.ServerInfo
        IncludeServerInfo = [bool] $server.Options.IncludeServerInfo
    }
    foreach ($member in $Payload.Keys) { $envelope[$member] = $Payload[$member] }
    $worker = [powershell]::Create()
    $worker.RunspacePool = $State.Pool
    $null = $worker.AddScript($script:McpWorkerScript).AddArgument($envelope)
    $handle = $worker.BeginInvoke()
    $State.InFlight[$Key] = @{
        Id         = $Id
        Label      = "$Method $Name"
        PowerShell = $worker
        Handle     = $handle
        Cts        = $cts
        StartedAt  = [datetime]::UtcNow
        Cancelled  = $false
        Responded  = $false
        Channel    = $Channel
        Era        = $Era
        Session    = $Session
    }
}
