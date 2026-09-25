# Server side of the Streamable HTTP transport (revision 2026-07-28) on System.Net.HttpListener. The dispatcher
# loop in Dispatcher.ps1 calls Invoke-McpHttpDispatcherLoop; every accepted POST becomes a channel (the HTTP
# response) that receives either one JSON object or a request-scoped SSE stream of notifications followed by
# the final response. Nothing here touches the console: diagnostics go through Write-McpStderr.

# Built on first use: the error code table (JsonRpc.ps1) is assembled after this file.
$script:McpHttpStatusByErrorCode = $null

function Get-McpHttpStatusCode {
    <#
    .SYNOPSIS
        The HTTP status of a JSON-RPC response: 400 for malformed requests, headers and versions, 404 for unknown methods, 200 otherwise.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()]
        [object] $ErrorCode
    )

    if ($null -eq $ErrorCode) { return 200 }
    if ($null -eq $script:McpHttpStatusByErrorCode) {
        $table = @{}
        foreach ($name in 'ParseError', 'InvalidRequest', 'InvalidParams', 'HeaderMismatch', 'MissingRequiredClientCapability', 'UnsupportedProtocolVersion') {
            $table[[int] $script:McpErrorCode[$name]] = 400
        }
        $table[[int] $script:McpErrorCode.MethodNotFound] = 404
        $script:McpHttpStatusByErrorCode = $table
    }
    $code = [int] $ErrorCode
    if ($script:McpHttpStatusByErrorCode.ContainsKey($code)) { return $script:McpHttpStatusByErrorCode[$code] }
    200
}

function New-McpHttpServerTransport {
    <#
    .SYNOPSIS
        Starts an HttpListener for the MCP endpoint and returns the transport object of the dispatcher.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The caller (Start-McpServer) owns the ShouldProcess decision.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [uri] $Url,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $AllowedOrigins,

        [long] $MaxBodyBytes = 16MB,

        [int] $KeepAliveSeconds = 5,

        [int] $BodyTimeoutSeconds = 30
    )

    if (-not $Url.IsAbsoluteUri -or $Url.Scheme -notin @('http', 'https')) {
        throw [System.ArgumentException]::new("The endpoint URL must be an absolute http or https URL such as http://127.0.0.1:8080/mcp/, not '$Url'.")
    }
    $path = $Url.AbsolutePath
    if ([string]::IsNullOrEmpty($path) -or $path -eq '/') { $path = '/mcp/' }
    if (-not $path.EndsWith('/')) { $path += '/' }
    $prefix = $Url.GetLeftPart([System.UriPartial]::Authority) + $path
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($prefix)
    try {
        $listener.Start()
    } catch {
        try { $listener.Close() } catch { Write-Debug 'Closing the failed listener failed.' }
        throw [System.InvalidOperationException]::new("Cannot listen on $prefix : $($_.Exception.Message) On Windows, users without administrative rights need a URL reservation (netsh http add urlacl url=$prefix user=<account>).", $_.Exception)
    }
    @{
        Kind               = 'Http'
        Listener           = $listener
        Url                = $Url
        Prefix             = $prefix
        Path               = $path.TrimEnd('/')
        AllowedOrigins     = @($AllowedOrigins | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        MaxBodyBytes       = $MaxBodyBytes
        KeepAliveSeconds   = $KeepAliveSeconds
        BodyTimeoutSeconds = $BodyTimeoutSeconds
        PendingBodies      = [System.Collections.Generic.List[hashtable]]::new()
        OpenChannels       = [System.Collections.Generic.List[hashtable]]::new()
        Stopped            = $false
        Closed             = $false
    }
}

function Close-McpHttpServerTransport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Transport
    )

    if ($Transport.Closed) { return }
    $Transport.Closed = $true
    foreach ($pending in @($Transport.PendingBodies)) {
        try { $pending.Channel.Response.Abort() } catch { Write-Debug 'Aborting a pending request failed.' }
    }
    $Transport.PendingBodies.Clear()
    foreach ($channel in @($Transport.OpenChannels)) {
        try { $channel.Response.Abort() } catch { Write-Debug 'Aborting an open response failed.' }
        $channel.Closed = $true
    }
    $Transport.OpenChannels.Clear()
    try {
        if (-not $Transport.Stopped) { $Transport.Listener.Stop() }
    } catch {
        Write-Debug 'Stopping the listener failed.'
    }
    $Transport.Stopped = $true
    try { $Transport.Listener.Close() } catch { Write-Debug 'Closing the listener failed.' }
}

function Test-McpHttpOrigin {
    <#
    .SYNOPSIS
        True when a request's Origin header is acceptable: absent, in the allow list, or (by default) a loopback origin or the server's own origin.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Transport,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Origin
    )

    if ([string]::IsNullOrEmpty($Origin)) { return $true }
    $candidate = $Origin.Trim().TrimEnd('/')
    $allowed = @($Transport.AllowedOrigins)
    if ($allowed.Count -gt 0) {
        foreach ($entry in $allowed) {
            if ($entry -eq '*' -or $entry.TrimEnd('/') -ieq $candidate) { return $true }
        }
        return $false
    }
    $uri = $null
    if (-not [uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref] $uri)) { return $false }
    if ($uri.Scheme -notin @('http', 'https')) { return $false }
    if ($uri.IsLoopback) { return $true }
    $own = $Transport.Url.GetLeftPart([System.UriPartial]::Authority)
    $candidate -ieq $own
}

function Test-McpHttpHost {
    <#
    .SYNOPSIS
        True when a request's Host header names the endpoint the listener was started with (host and port).
    .DESCRIPTION
        The managed HttpListener on Linux and macOS only routes requests whose Host header matches the prefix
        host, but http.sys on Windows delivers requests with any Host header to a prefix bound to an IP
        address, so the server checks the header itself on every platform: DNS rebinding protection must not
        depend on the listener implementation. The port may be omitted when it is the default port of the scheme.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Transport,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $HostHeader
    )

    if ([string]::IsNullOrWhiteSpace($HostHeader)) { return $false }
    $value = $HostHeader.Trim()
    $expected = $Transport.Url
    $hostPart = $value
    $portPart = $null
    if ($value.StartsWith('[')) {
        $close = $value.IndexOf(']')
        if ($close -lt 0) { return $false }
        $hostPart = $value.Substring(0, $close + 1)
        $rest = $value.Substring($close + 1)
        if ($rest.Length -gt 0) {
            if (-not $rest.StartsWith(':')) { return $false }
            $portPart = $rest.Substring(1)
        }
    } else {
        $colon = $value.LastIndexOf(':')
        if ($colon -ge 0) {
            $hostPart = $value.Substring(0, $colon)
            $portPart = $value.Substring($colon + 1)
        }
    }
    $port = if ($expected.Scheme -eq 'https') { 443 } else { 80 }
    if ($null -ne $portPart) {
        if ($portPart.Length -eq 0 -or -not [int]::TryParse($portPart, [ref] $port)) { return $false }
    }
    ($hostPart -eq $expected.Host) -and ($port -eq $expected.Port)
}

function New-McpHttpChannel {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerContext] $Context
    )

    @{
        Kind      = 'Http'
        Context   = $Context
        Response  = $Context.Response
        Mode      = $null
        Stream    = $null
        Closed    = $false
        LastWrite = [datetime]::UtcNow
        RequestId = $null
    }
}

function New-McpHttpErrorJson {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a wire message.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [int] $Code,

        [Parameter(Mandatory)]
        [string] $Message,

        [AllowNull()]
        [object] $Id
    )

    ConvertTo-McpJson -InputObject (New-McpErrorResponse -Id $Id -ErrorObject (New-McpError -Code $Code -Message $Message))
}

function Close-McpHttpChannel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [hashtable] $Channel,

        [switch] $Abort
    )

    if ($Channel.Closed) { return }
    $Channel.Closed = $true
    $null = $State.Transport.OpenChannels.Remove($Channel)
    try {
        if ($Abort) {
            $Channel.Response.Abort()
        } else {
            if ($null -ne $Channel.Stream) { $Channel.Stream.Close() }
            $Channel.Response.Close()
        }
    } catch {
        Write-Debug "Closing an HTTP response failed: $($_.Exception.Message)"
    }
}

function Send-McpHttpStatus {
    <#
    .SYNOPSIS
        Completes a channel with a status code, optional headers and an optional JSON body; returns $false when the client is gone.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [hashtable] $Channel,

        [Parameter(Mandatory)]
        [int] $StatusCode,

        [string] $Json,

        [hashtable] $Headers
    )

    if ($Channel.Closed) { return $false }
    try {
        $response = $Channel.Response
        $response.StatusCode = $StatusCode
        if ($Headers) {
            foreach ($name in $Headers.Keys) { $response.AddHeader([string] $name, [string] $Headers[$name]) }
        }
        if ($Json) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
            $response.ContentType = 'application/json; charset=utf-8'
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $response.ContentLength64 = 0
        }
        Write-McpStderr -Level Debug -Threshold $State.LogLevel -Logger $State.Server.Name -Message ("-> HTTP {0} id={1} ({2} bytes)" -f $StatusCode, $Channel.RequestId, $(if ($Json) { $Json.Length } else { 0 }))
        $Channel.Closed = $true
        $null = $State.Transport.OpenChannels.Remove($Channel)
        $response.Close()
        return $true
    } catch {
        Write-McpStderr -Level Debug -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Writing an HTTP response failed: $($_.Exception.Message)"
        Close-McpHttpChannel -State $State -Channel $Channel -Abort
        return $false
    }
}

function Start-McpHttpSse {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Switches an HTTP response to streaming; part of the request pipeline.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [hashtable] $Channel
    )

    if ($Channel.Closed) { return $false }
    if ($Channel.Mode -eq 'Sse') { return $true }
    try {
        $response = $Channel.Response
        $response.StatusCode = 200
        $response.ContentType = 'text/event-stream'
        $response.SendChunked = $true
        $response.AddHeader('Cache-Control', 'no-cache')
        $response.AddHeader('X-Accel-Buffering', 'no')
        $Channel.Stream = $response.OutputStream
        $Channel.Mode = 'Sse'
        $Channel.LastWrite = [datetime]::UtcNow
        $State.Transport.OpenChannels.Add($Channel)
        Write-McpStderr -Level Debug -Threshold $State.LogLevel -Logger $State.Server.Name -Message ("-> HTTP 200 text/event-stream id={0}" -f $Channel.RequestId)
        return $true
    } catch {
        Write-McpStderr -Level Debug -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Starting an SSE response failed: $($_.Exception.Message)"
        Close-McpHttpChannel -State $State -Channel $Channel -Abort
        return $false
    }
}

function Write-McpSseChunk {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [hashtable] $Channel,

        [Parameter(Mandatory)]
        [string] $Text
    )

    if ($Channel.Closed -or $Channel.Mode -ne 'Sse') { return $false }
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $Channel.Stream.Write($bytes, 0, $bytes.Length)
        $Channel.Stream.Flush()
        $Channel.LastWrite = [datetime]::UtcNow
        return $true
    } catch {
        Write-McpStderr -Level Debug -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Writing to an SSE stream failed (id=$($Channel.RequestId)): $($_.Exception.Message)"
        Close-McpHttpChannel -State $State -Channel $Channel -Abort
        return $false
    }
}

function Send-McpHttpNotification {
    <#
    .SYNOPSIS
        Sends a notification on a request's channel, switching the response to an SSE stream first; $false when the client is gone.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [hashtable] $Channel,

        [Parameter(Mandatory)]
        [string] $Json
    )

    if (-not (Start-McpHttpSse -State $State -Channel $Channel)) { return $false }
    Write-McpSseChunk -State $State -Channel $Channel -Text "event: message`ndata: $Json`n`n"
}

function Send-McpHttpResponse {
    <#
    .SYNOPSIS
        Sends the final JSON-RPC response of a request: as the last SSE event of an open stream, or as a JSON body with the status of its error code.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [hashtable] $Channel,

        [Parameter(Mandatory)]
        [string] $Json,

        [AllowNull()]
        [object] $ErrorCode
    )

    if ($Channel.Closed) { return $false }
    if ($Channel.Mode -eq 'Sse') {
        $written = Write-McpSseChunk -State $State -Channel $Channel -Text "event: message`ndata: $Json`n`n"
        Close-McpHttpChannel -State $State -Channel $Channel
        return $written
    }
    Send-McpHttpStatus -State $State -Channel $Channel -StatusCode (Get-McpHttpStatusCode -ErrorCode $ErrorCode) -Json $Json
}

function Update-McpHttpChannel {
    <#
    .SYNOPSIS
        Switches long-running requests to SSE and sends keep-alive comments on idle streams; a failed write means the client closed the stream, which cancels the request.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal housekeeping of the dispatcher loop.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $transport = $State.Transport
    if ($transport.KeepAliveSeconds -le 0) { return }
    $now = [datetime]::UtcNow
    # A request that outlives the keep-alive interval switches to an SSE stream: only a write can reveal
    # that the client closed the connection, and a plain JSON response is written only at the very end.
    foreach ($entry in @($State.InFlight.Values)) {
        $channel = $entry.Channel
        if ($null -eq $channel -or $channel.Kind -ne 'Http' -or $channel.Closed -or $channel.Mode -eq 'Sse') { continue }
        if ($entry.Cancelled -or $entry.Responded) { continue }
        if (($now - $entry.StartedAt).TotalSeconds -lt $transport.KeepAliveSeconds) { continue }
        if (-not (Start-McpHttpSse -State $State -Channel $channel) -or -not (Write-McpSseChunk -State $State -Channel $channel -Text ": keep-alive`n`n")) {
            Stop-McpHttpChannelRequest -State $State -Channel $channel
        }
    }
    if ($transport.OpenChannels.Count -eq 0) { return }
    foreach ($channel in @($transport.OpenChannels)) {
        if ($channel.Closed) { $null = $transport.OpenChannels.Remove($channel); continue }
        if (($now - $channel.LastWrite).TotalSeconds -lt $transport.KeepAliveSeconds) { continue }
        if (-not (Write-McpSseChunk -State $State -Channel $channel -Text ": keep-alive`n`n")) {
            Stop-McpHttpChannelRequest -State $State -Channel $channel
        }
    }
}

function Stop-McpHttpChannelRequest {
    <#
    .SYNOPSIS
        Cancels the in-flight request of a channel whose client went away (a write to it failed).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal request bookkeeping.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [hashtable] $Channel
    )

    if ($null -eq $Channel.RequestId -and $null -eq $Channel.RequestKey) { return }
    $key = if ($Channel.RequestKey) { $Channel.RequestKey } else { Get-McpRequestKey -Id $Channel.RequestId }
    if ($State.Listeners.ContainsKey($key) -and $State.Listeners[$key].Channel -eq $Channel) {
        Remove-McpListener -State $State -Key $key -Reason 'ended: the client closed the stream'
        return
    }
    if (-not $State.InFlight.ContainsKey($key)) { return }
    $entry = $State.InFlight[$key]
    if ($entry.Cancelled -or $entry.Responded) { return }
    Write-McpStderr -Level Info -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Request $($entry.Id) ($($entry.Label)): the client closed the connection; cancelling."
    Stop-McpInFlightRequest -Entry $entry
    $entry.Responded = $true
}

function Test-McpHttpRequestHeader {
    <#
    .SYNOPSIS
        Validates the standard request headers of a POST against its JSON-RPC body; throws -32020 on any mismatch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerRequest] $Request,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Message
    )

    $mismatch = $script:McpErrorCode.HeaderMismatch
    $headers = $Request.Headers
    $versionHeader = $headers['MCP-Protocol-Version']
    if ($null -eq $versionHeader) {
        throw [McpProtocolException]::new($mismatch, 'Header mismatch: the MCP-Protocol-Version header is missing.')
    }
    $versionHeader = $versionHeader.Trim()
    $method = [string] $Message['method']
    $methodHeader = $headers['Mcp-Method']
    if ($null -eq $methodHeader) {
        throw [McpProtocolException]::new($mismatch, 'Header mismatch: the Mcp-Method header is missing.')
    }
    if ($methodHeader.Trim() -cne $method) {
        throw [McpProtocolException]::new($mismatch, "Header mismatch: Mcp-Method header value '$($methodHeader.Trim())' does not match body method '$method'.")
    }
    $params = if ($Message.Contains('params')) { $Message['params'] } else { $null }
    $bodyName = Get-McpStandardHeaderName -Method $method -Params $params
    if ($null -ne $bodyName) {
        $nameHeader = $headers['Mcp-Name']
        if ($null -eq $nameHeader) {
            throw [McpProtocolException]::new($mismatch, "Header mismatch: the Mcp-Name header is missing for $method.")
        }
        $decoded = ConvertFrom-McpHeaderValue -Value $nameHeader -HeaderName 'Mcp-Name'
        if ($decoded -cne $bodyName) {
            throw [McpProtocolException]::new($mismatch, "Header mismatch: Mcp-Name header value '$decoded' does not match body value '$bodyName'.")
        }
    }
    if ($params -is [System.Collections.IDictionary] -and $params.Contains('_meta') -and $params['_meta'] -is [System.Collections.IDictionary]) {
        $meta = $params['_meta']
        $key = $script:McpMetaKey.ProtocolVersion
        if ($meta.Contains($key) -and $meta[$key] -is [string] -and $meta[$key] -cne $versionHeader) {
            throw [McpProtocolException]::new($mismatch, "Header mismatch: MCP-Protocol-Version header '$versionHeader' does not match _meta protocolVersion '$($meta[$key])'.")
        }
    }
}

function Invoke-McpInboundHttpMessage {
    <#
    .SYNOPSIS
        Handles the body of an accepted POST: parse errors and invalid messages answer 400, notifications 202, requests go to the dispatcher.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [hashtable] $Channel,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Body
    )

    $logger = $State.Server.Name
    $message = $null
    try {
        $message = ConvertFrom-McpJson -Json $Body
    } catch {
        $null = Send-McpHttpStatus -State $State -Channel $Channel -StatusCode 400 -Json (New-McpHttpErrorJson -Code $script:McpErrorCode.ParseError -Message 'Parse error')
        return
    }
    $kind = Get-McpMessageKind -Message $message
    Write-McpStderr -Level Debug -Threshold $State.LogLevel -Logger $logger -Message ("<- {0} {1} {2}" -f $kind, $(if ($message -is [System.Collections.IDictionary] -and $message.Contains('method')) { $message['method'] } else { '' }), $(if ($message -is [System.Collections.IDictionary] -and $message.Contains('id')) { "id=$($message['id'])" } else { '' }))
    switch ($kind) {
        'Request' {
            $Channel.RequestId = $message['id']
            if ([string] $message['method'] -ne 'initialize') {
                try {
                    Test-McpHttpRequestHeader -Request $Channel.Context.Request -Message $message
                } catch [McpProtocolException] {
                    Send-McpDispatcherMessage -State $State -Channel $Channel -Message (New-McpErrorResponse -Id $message['id'] -ErrorObject (ConvertTo-McpErrorObject -Exception $_.Exception))
                    return
                }
            }
            Invoke-McpInboundRequest -State $State -Message $message -Channel $Channel
        }
        'Notification' {
            Write-McpStderr -Level Debug -Threshold $State.LogLevel -Logger $logger -Message "Accepted notification '$($message['method'])' (revision 2026-07-28 defines no client notifications over Streamable HTTP)."
            $null = Send-McpHttpStatus -State $State -Channel $Channel -StatusCode 202
        }
        { $_ -in @('Response', 'ErrorResponse') } {
            $null = Send-McpHttpStatus -State $State -Channel $Channel -StatusCode 400 -Json (New-McpHttpErrorJson -Code $script:McpErrorCode.InvalidRequest -Message 'Clients do not send JSON-RPC responses in revision 2026-07-28; server-to-client interactions are input requests inside results.')
        }
        default {
            $id = $null
            if ($message -is [System.Collections.IDictionary] -and $message.Contains('id') -and (Test-McpRequestId -Id $message['id'])) { $id = $message['id'] }
            $null = Send-McpHttpStatus -State $State -Channel $Channel -StatusCode 400 -Json (New-McpHttpErrorJson -Code $script:McpErrorCode.InvalidRequest -Message 'Invalid Request' -Id $id)
        }
    }
}

function Invoke-McpHttpAccept {
    <#
    .SYNOPSIS
        Screens an accepted connection (Host, path, Origin, method, content type, size) and starts reading its body.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [System.Net.HttpListenerContext] $Context
    )

    $transport = $State.Transport
    $request = $Context.Request
    $channel = New-McpHttpChannel -Context $Context
    Write-McpStderr -Level Debug -Threshold $State.LogLevel -Logger $State.Server.Name -Message ("<- HTTP {0} {1} from {2}" -f $request.HttpMethod, $request.RawUrl, $request.RemoteEndPoint)
    $invalidRequest = $script:McpErrorCode.InvalidRequest
    $hostHeader = $request.Headers['Host']
    if (-not (Test-McpHttpHost -Transport $transport -HostHeader $hostHeader)) {
        Write-McpStderr -Level Warning -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Rejected a request with Host '$hostHeader' (the endpoint is $($transport.Url.Authority))."
        $null = Send-McpHttpStatus -State $State -Channel $channel -StatusCode 404 -Json (New-McpHttpErrorJson -Code $invalidRequest -Message "No MCP endpoint for host '$hostHeader'; the endpoint is '$($transport.Url)'.")
        return
    }
    $path = $request.Url.AbsolutePath.TrimEnd('/')
    if ($path -cne $transport.Path) {
        $null = Send-McpHttpStatus -State $State -Channel $channel -StatusCode 404 -Json (New-McpHttpErrorJson -Code $invalidRequest -Message "No MCP endpoint at '$($request.Url.AbsolutePath)'; the endpoint is '$($transport.Path)/'.")
        return
    }
    $origin = $request.Headers['Origin']
    if (-not (Test-McpHttpOrigin -Transport $transport -Origin $origin)) {
        Write-McpStderr -Level Warning -Threshold $State.LogLevel -Logger $State.Server.Name -Message "Rejected a request with Origin '$origin' (allowed: $(if ($transport.AllowedOrigins.Count -gt 0) { $transport.AllowedOrigins -join ', ' } else { 'loopback origins' }))."
        $null = Send-McpHttpStatus -State $State -Channel $channel -StatusCode 403 -Json (New-McpHttpErrorJson -Code $invalidRequest -Message "Origin '$origin' is not allowed.")
        return
    }
    if ($request.HttpMethod -cne 'POST') {
        $null = Send-McpHttpStatus -State $State -Channel $channel -StatusCode 405 -Headers @{ Allow = 'POST' } -Json (New-McpHttpErrorJson -Code $invalidRequest -Message 'The MCP endpoint accepts POST only: revision 2026-07-28 has neither a GET stream nor sessions.')
        return
    }
    $contentType = $request.ContentType
    if (-not [string]::IsNullOrWhiteSpace($contentType) -and $contentType -notmatch '^\s*application/json\s*(;|$)') {
        $null = Send-McpHttpStatus -State $State -Channel $channel -StatusCode 415 -Json (New-McpHttpErrorJson -Code $invalidRequest -Message "Unsupported Content-Type '$contentType'; the body must be application/json.")
        return
    }
    if ($request.ContentLength64 -gt $transport.MaxBodyBytes) {
        $null = Send-McpHttpStatus -State $State -Channel $channel -StatusCode 413 -Json (New-McpHttpErrorJson -Code $invalidRequest -Message "The request body exceeds the limit of $($transport.MaxBodyBytes) bytes.")
        return
    }
    $buffer = [System.IO.MemoryStream]::new()
    $task = $request.InputStream.CopyToAsync($buffer)
    $transport.PendingBodies.Add(@{ Channel = $channel; Buffer = $buffer; Task = $task; Started = [datetime]::UtcNow })
}

function Update-McpHttpPendingBody {
    <#
    .SYNOPSIS
        Hands completed body reads to the message handler and times out slow ones.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal housekeeping of the dispatcher loop.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $transport = $State.Transport
    if ($transport.PendingBodies.Count -eq 0) { return }
    foreach ($pending in @($transport.PendingBodies)) {
        if ($pending.Task.IsCompleted) {
            $null = $transport.PendingBodies.Remove($pending)
            if ($pending.Task.IsFaulted -or $pending.Task.IsCanceled) {
                Close-McpHttpChannel -State $State -Channel $pending.Channel -Abort
                continue
            }
            if ($pending.Buffer.Length -gt $transport.MaxBodyBytes) {
                $null = Send-McpHttpStatus -State $State -Channel $pending.Channel -StatusCode 413 -Json (New-McpHttpErrorJson -Code $script:McpErrorCode.InvalidRequest -Message "The request body exceeds the limit of $($transport.MaxBodyBytes) bytes.")
                continue
            }
            $bytes = $pending.Buffer.ToArray()
            $offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
            $body = [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)
            Invoke-McpInboundHttpMessage -State $State -Channel $pending.Channel -Body $body
        } elseif (([datetime]::UtcNow - $pending.Started).TotalSeconds -gt $transport.BodyTimeoutSeconds) {
            $null = $transport.PendingBodies.Remove($pending)
            $null = Send-McpHttpStatus -State $State -Channel $pending.Channel -StatusCode 408 -Json (New-McpHttpErrorJson -Code $script:McpErrorCode.InvalidRequest -Message "The request body was not received within $($transport.BodyTimeoutSeconds) seconds.")
        }
    }
}

function Complete-McpHttpAccept {
    [CmdletBinding()]
    [OutputType([System.Net.HttpListenerContext])]
    param(
        [Parameter(Mandatory)]
        [System.Threading.Tasks.Task] $Task
    )

    if ($Task.IsFaulted -or $Task.IsCanceled) { return $null }
    $Task.Result
}

function Invoke-McpHttpDispatcherLoop {
    <#
    .SYNOPSIS
        The dispatcher loop of the Streamable HTTP transport: accepts connections, reads bodies, routes messages, forwards worker output, sends keep-alives.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [int] $ShutdownGraceSeconds = 5
    )

    $server = $State.Server
    $transport = $State.Transport
    $listener = $transport.Listener
    $acceptTask = $listener.GetContextAsync()
    $stopDeadline = $null
    while ($true) {
        $handles = [System.Collections.Generic.List[System.Threading.WaitHandle]]::new()
        if (-not $transport.Stopped) { $handles.Add((Get-McpTaskWaitHandle -Task $acceptTask)) }
        $handles.Add($State.Signal)
        foreach ($pending in $transport.PendingBodies) {
            if ($handles.Count -ge 60) { break }
            $handles.Add((Get-McpTaskWaitHandle -Task $pending.Task))
        }
        $null = [System.Threading.WaitHandle]::WaitAny($handles.ToArray(), 250)
        if (-not $transport.Stopped -and $acceptTask.IsCompleted) {
            $context = Complete-McpHttpAccept -Task $acceptTask
            if ($null -ne $context) { Invoke-McpHttpAccept -State $State -Context $context }
            if ($listener.IsListening) {
                $acceptTask = $listener.GetContextAsync()
            } else {
                $transport.Stopped = $true
            }
        }
        Update-McpHttpPendingBody -State $State
        Send-McpOutboundQueue -State $State
        Update-McpInFlightRequest -State $State
        Update-McpHttpChannel -State $State
        if ($State.Stopping) { break }
        if ($server.State.StopRequested) {
            if ($State.Listeners.Count -gt 0) { Close-McpAllListener -State $State }
            if (-not $transport.Stopped) {
                $transport.Stopped = $true
                Write-McpStderr -Level Info -Threshold $State.LogLevel -Logger $server.Name -Message 'Stop requested; no longer accepting connections.'
                try { $listener.Stop() } catch { Write-Debug 'Stopping the listener failed.' }
            }
            if ($State.InFlight.Count -eq 0 -and $transport.PendingBodies.Count -eq 0) { break }
            if ($null -eq $stopDeadline) { $stopDeadline = [datetime]::UtcNow.AddSeconds($ShutdownGraceSeconds) }
            if ([datetime]::UtcNow -ge $stopDeadline) { break }
        }
    }
}
