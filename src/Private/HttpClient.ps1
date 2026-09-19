# Client side of the Streamable HTTP transport (revision 2026-07-28): one HTTP POST per JSON-RPC message with
# the request metadata headers (MCP-Protocol-Version, Mcp-Method, Mcp-Name and the Mcp-Param-* headers of
# x-mcp-header annotated tool parameters), and responses read either as one JSON object or as a request-scoped
# SSE stream whose notifications are dispatched while the final response is awaited. A timeout closes the
# response stream, which is the cancellation signal of this transport.

function New-McpHttpClientTransport {
    <#
    .SYNOPSIS
        An HttpClient-based transport for an MCP endpoint URL.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The caller (Connect-McpServer) owns the ShouldProcess decision.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [uri] $Url,

        [hashtable] $Headers,

        [switch] $NoProxy
    )

    if (-not $Url.IsAbsoluteUri -or $Url.Scheme -notin @('http', 'https')) {
        throw [System.ArgumentException]::new("The server URL must be an absolute http or https URL, not '$Url'.")
    }
    $handler = [System.Net.Http.SocketsHttpHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    if ($NoProxy -or $Url.IsLoopback) { $handler.UseProxy = $false }
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $static = @{}
    if ($Headers) {
        foreach ($key in $Headers.Keys) { $static[[string] $key] = [string] $Headers[$key] }
    }
    @{
        Kind    = 'Http'
        Url     = $Url
        Client  = $client
        Handler = $handler
        Headers = $static
        Closed  = $false
    }
}

function Close-McpHttpClientTransport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Transport
    )

    if ($Transport.Closed) { return }
    $Transport.Closed = $true
    try { $Transport.Client.Dispose() } catch { Write-Debug 'Disposing the HTTP client failed.' }
    try { $Transport.Handler.Dispose() } catch { Write-Debug 'Disposing the HTTP handler failed.' }
}

function Wait-McpTask {
    <#
    .SYNOPSIS
        Waits for a task until a deadline in short slices (so that Ctrl+C stays responsive); $false when the deadline passed first.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Threading.Tasks.Task] $Task,

        [Parameter(Mandatory)]
        [datetime] $Deadline
    )

    while (-not $Task.IsCompleted) {
        $remaining = ($Deadline - [datetime]::UtcNow).TotalMilliseconds
        if ($remaining -le 0) { return $false }
        try {
            $null = $Task.Wait([int] [math]::Min(500, [math]::Max(1, $remaining)))
        } catch [System.AggregateException] {
            return $true
        }
    }
    $true
}

function Get-McpTaskFailure {
    [CmdletBinding()]
    [OutputType([System.Exception], [System.OperationCanceledException])]
    param(
        [Parameter(Mandatory)]
        [System.Threading.Tasks.Task] $Task
    )

    if ($Task.IsCanceled) { return [System.OperationCanceledException]::new('The operation was cancelled.') }
    if (-not $Task.IsFaulted) { return $null }
    $exception = $Task.Exception
    while ($exception -is [System.AggregateException] -and $null -ne $exception.InnerException) { $exception = $exception.InnerException }
    $exception
}

function New-McpSseReader {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.IO.Stream] $Stream
    )

    @{
        Reader      = [System.IO.StreamReader]::new($Stream, [System.Text.UTF8Encoding]::new($false), $false, 65536)
        PendingRead = $null
        Data        = [System.Collections.Generic.List[string]]::new()
        EventName   = $null
    }
}

function Receive-McpSseEvent {
    <#
    .SYNOPSIS
        Reads the next SSE event: a hashtable with Status (Event, Eof or Timeout), Data (the joined data lines) and Event (the event name).
    .DESCRIPTION
        Comment lines (starting with ':') and the id and retry fields are ignored; an empty line dispatches the
        event collected so far. The pending line read survives a timeout so that no bytes are lost.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Sse,

        [Parameter(Mandatory)]
        [int] $TimeoutMs
    )

    while ($true) {
        if ($null -eq $Sse.PendingRead) { $Sse.PendingRead = $Sse.Reader.ReadLineAsync() }
        $task = $Sse.PendingRead
        $completed = $false
        try {
            $completed = $task.Wait([math]::Max(1, $TimeoutMs))
        } catch [System.AggregateException] {
            $completed = $true
        }
        if (-not $completed) { return @{ Status = 'Timeout'; Data = $null; Event = $null } }
        $Sse.PendingRead = $null
        $line = $null
        if ($task.IsFaulted -or $task.IsCanceled) {
            $failure = Get-McpTaskFailure -Task $task
            if ($failure -is [System.IO.IOException] -or $failure -is [System.ObjectDisposedException] -or $failure -is [System.OperationCanceledException] -or $failure -is [System.Net.Http.HttpRequestException]) {
                return @{ Status = 'Eof'; Data = $null; Event = $null }
            }
            throw $failure
        }
        $line = $task.Result
        if ($null -eq $line) { return @{ Status = 'Eof'; Data = $null; Event = $null } }
        if ($line.Length -eq 0) {
            if ($Sse.Data.Count -eq 0) { $Sse.EventName = $null; continue }
            $data = $Sse.Data -join "`n"
            $name = $Sse.EventName
            $Sse.Data.Clear()
            $Sse.EventName = $null
            return @{ Status = 'Event'; Data = $data; Event = $name }
        }
        if ($line[0] -eq ':') { continue }
        $colon = $line.IndexOf(':')
        $field = if ($colon -ge 0) { $line.Substring(0, $colon) } else { $line }
        $value = ''
        if ($colon -ge 0) {
            $value = $line.Substring($colon + 1)
            if ($value.StartsWith(' ')) { $value = $value.Substring(1) }
        }
        switch ($field) {
            'data' { $Sse.Data.Add($value) }
            'event' { $Sse.EventName = $value }
            default { Write-Debug "Ignoring the SSE field '$field'." }
        }
    }
}

function Convert-McpHttpResponseBody {
    <#
    .SYNOPSIS
        Interprets a JSON body of a POST response: the result of the request, a thrown McpProtocolException, or a transport error.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Transport,

        [Parameter(Mandatory)]
        [int] $Status,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Body,

        [Parameter(Mandatory)]
        [object] $Id,

        [Parameter(Mandatory)]
        [string] $Method
    )

    $where = "'$Method' (id $Id) at $($Transport.Url)"
    if ([string]::IsNullOrWhiteSpace($Body)) {
        throw [System.Net.Http.HttpRequestException]::new("HTTP $Status with an empty body for $where.")
    }
    $message = $null
    try {
        $message = ConvertFrom-McpJson -Json $Body
    } catch {
        $snippet = $Body.Substring(0, [math]::Min(200, $Body.Length))
        throw [System.Net.Http.HttpRequestException]::new("HTTP $Status with a body that is not JSON for $where : $snippet")
    }
    switch (Get-McpMessageKind -Message $message) {
        'Response' {
            if ([string] $message['id'] -ceq [string] $Id) { return $message['result'] }
            throw [System.InvalidOperationException]::new("The response to $where carries the id '$($message['id'])'.")
        }
        'ErrorResponse' {
            $errorObject = $message['error']
            $data = if ($errorObject.Contains('data')) { $errorObject['data'] } else { $null }
            throw [McpProtocolException]::new([int] $errorObject['code'], [string] $errorObject['message'], $data)
        }
        default {
            throw [System.Net.Http.HttpRequestException]::new("HTTP $Status with an unexpected body for $where : $($Body.Substring(0, [math]::Min(200, $Body.Length)))")
        }
    }
}

function Receive-McpSseResponse {
    <#
    .SYNOPSIS
        Reads a request-scoped SSE stream until the response with the request id arrives, dispatching notifications on the way.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [System.Net.Http.HttpResponseMessage] $Response,

        [Parameter(Mandatory)]
        [object] $Id,

        [Parameter(Mandatory)]
        [string] $Method,

        [Parameter(Mandatory)]
        [datetime] $Deadline,

        [Parameter(Mandatory)]
        [System.Threading.CancellationTokenSource] $Cts,

        [AllowNull()]
        [object] $ProgressToken,

        [scriptblock] $OnProgress
    )

    $streamTask = $Response.Content.ReadAsStreamAsync()
    if (-not (Wait-McpTask -Task $streamTask -Deadline $Deadline)) {
        $Cts.Cancel()
        throw [System.TimeoutException]::new("The response stream of '$Method' (id $Id) did not open in time.")
    }
    $failure = Get-McpTaskFailure -Task $streamTask
    if ($null -ne $failure) { throw [System.IO.IOException]::new("Opening the response stream of '$Method' (id $Id) failed: $($failure.Message)", $failure) }
    $sse = New-McpSseReader -Stream $streamTask.Result
    try {
        while ($true) {
            $remaining = ($Deadline - [datetime]::UtcNow).TotalMilliseconds
            if ($remaining -le 0) {
                $Cts.Cancel()
                throw [System.TimeoutException]::new("No response to '$Method' (id $Id) within the timeout; the response stream was closed, which cancels the request.")
            }
            $received = Receive-McpSseEvent -Sse $sse -TimeoutMs ([int] [math]::Min(500, $remaining))
            if ($received.Status -eq 'Timeout') { continue }
            if ($received.Status -eq 'Eof') {
                throw [System.IO.IOException]::new("The server closed the response stream of '$Method' (id $Id) before the response arrived; the request may be re-issued with a new id.")
            }
            if ($null -ne $received.Event -and $received.Event -ne 'message') {
                Write-Debug "Ignoring an SSE event named '$($received.Event)'."
                continue
            }
            $message = $null
            try {
                $message = ConvertFrom-McpJson -Json $received.Data
            } catch {
                Write-Warning "Ignoring an SSE event from the server that is not JSON: $($received.Data.Substring(0, [math]::Min(120, $received.Data.Length)))"
                continue
            }
            switch (Get-McpMessageKind -Message $message) {
                'Response' {
                    if ([string] $message['id'] -ceq [string] $Id) { return $message['result'] }
                    Write-Debug "Ignoring a response with id $($message['id']) on the stream of id $Id."
                }
                'ErrorResponse' {
                    if (-not $message.Contains('id') -or [string] $message['id'] -ceq [string] $Id) {
                        $errorObject = $message['error']
                        $data = if ($errorObject.Contains('data')) { $errorObject['data'] } else { $null }
                        throw [McpProtocolException]::new([int] $errorObject['code'], [string] $errorObject['message'], $data)
                    }
                    Write-Debug "Ignoring an error response with id $($message['id']) on the stream of id $Id."
                }
                'Notification' {
                    Invoke-McpClientNotificationHandler -Session $Session -Message $message -ProgressToken $ProgressToken -OnProgress $OnProgress
                }
                'Request' {
                    Write-Warning "Ignoring a request '$($message['method'])' from the server: servers do not send requests in protocol version $($Session.ProtocolVersion)."
                }
                default {
                    Write-Warning 'Ignoring an invalid JSON-RPC message on the response stream.'
                }
            }
        }
    } finally {
        try { $sse.Reader.Dispose() } catch { Write-Debug 'Disposing the SSE reader failed.' }
    }
}

function New-McpHttpRequestMessage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object.')]
    [CmdletBinding()]
    [OutputType([System.Net.Http.HttpRequestMessage])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [string] $Method,

        [AllowNull()]
        [System.Collections.IDictionary] $Params,

        [Parameter(Mandatory)]
        [string] $Json,

        [hashtable] $Headers
    )

    $transport = $Session.Transport
    $message = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $transport.Url)
    $message.Content = [System.Net.Http.ByteArrayContent]::new([System.Text.Encoding]::UTF8.GetBytes($Json))
    $message.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
    $null = $message.Headers.TryAddWithoutValidation('Accept', 'application/json, text/event-stream')
    $null = $message.Headers.TryAddWithoutValidation('MCP-Protocol-Version', $Session.ProtocolVersion)
    $null = $message.Headers.TryAddWithoutValidation('Mcp-Method', $Method)
    $bodyName = Get-McpStandardHeaderName -Method $Method -Params $Params
    if ($null -ne $bodyName) {
        $null = $message.Headers.TryAddWithoutValidation('Mcp-Name', (ConvertTo-McpHeaderValue -Value $bodyName -Type string))
    }
    foreach ($key in $transport.Headers.Keys) {
        $null = $message.Headers.TryAddWithoutValidation($key, $transport.Headers[$key])
    }
    if ($Headers) {
        foreach ($key in $Headers.Keys) {
            $null = $message.Headers.TryAddWithoutValidation([string] $key, [string] $Headers[$key])
        }
    }
    $message
}

function Invoke-McpHttpClientRequest {
    <#
    .SYNOPSIS
        Sends one request as a POST and returns its result; JSON-RPC errors are thrown as McpProtocolException.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [string] $Method,

        [System.Collections.IDictionary] $Params,

        [scriptblock] $OnProgress,

        [AllowNull()]
        [object] $LogLevel,

        [int] $TimeoutMs = 0,

        [hashtable] $Headers
    )

    $transport = $Session.Transport
    if ($transport.Closed) { throw [System.IO.IOException]::new('The transport is closed.') }
    if ($TimeoutMs -le 0) { $TimeoutMs = [int] $Session.RequestTimeoutMs }
    $id = [int] $Session.NextId
    $Session.NextId = $id + 1
    $progressToken = if ($OnProgress) { "p-$id" } else { $null }
    $requestParams = [ordered]@{}
    $requestParams['_meta'] = New-McpClientRequestMeta -Session $Session -ProgressToken $progressToken -LogLevel $LogLevel
    if ($null -ne $Params) {
        foreach ($key in $Params.Keys) {
            if ([string] $key -eq '_meta') { continue }
            $requestParams[[string] $key] = $Params[$key]
        }
    }
    $json = ConvertTo-McpJson -InputObject (New-McpRequest -Id $id -Method $Method -Params $requestParams)
    $message = New-McpHttpRequestMessage -Session $Session -Method $Method -Params $Params -Json $json -Headers $Headers
    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
    $cts = [System.Threading.CancellationTokenSource]::new()
    $response = $null
    try {
        Write-Debug "-> POST $($transport.Url) $Method id=$id ($($json.Length) bytes)"
        $sendTask = $transport.Client.SendAsync($message, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token)
        if (-not (Wait-McpTask -Task $sendTask -Deadline $deadline)) {
            $cts.Cancel()
            throw [System.TimeoutException]::new("No response headers from $($transport.Url) for '$Method' (id $id) within $TimeoutMs ms.")
        }
        $failure = Get-McpTaskFailure -Task $sendTask
        if ($null -ne $failure) {
            throw [System.Net.Http.HttpRequestException]::new("POST $($transport.Url) failed for '$Method' (id $id): $($failure.Message)", $failure)
        }
        $response = $sendTask.Result
        $status = [int] $response.StatusCode
        $mediaType = $null
        if ($null -ne $response.Content -and $null -ne $response.Content.Headers.ContentType) { $mediaType = $response.Content.Headers.ContentType.MediaType }
        Write-Debug "<- HTTP $status $mediaType for $Method id=$id"
        if ($mediaType -eq 'text/event-stream') {
            return Receive-McpSseResponse -Session $Session -Response $response -Id $id -Method $Method -Deadline $deadline -Cts $cts -ProgressToken $progressToken -OnProgress $OnProgress
        }
        $readTask = $response.Content.ReadAsStringAsync()
        if (-not (Wait-McpTask -Task $readTask -Deadline $deadline)) {
            $cts.Cancel()
            throw [System.TimeoutException]::new("The body of the response to '$Method' (id $id) did not arrive within $TimeoutMs ms.")
        }
        $failure = Get-McpTaskFailure -Task $readTask
        if ($null -ne $failure) {
            throw [System.IO.IOException]::new("Reading the response to '$Method' (id $id) failed: $($failure.Message)", $failure)
        }
        Convert-McpHttpResponseBody -Transport $transport -Status $status -Body $readTask.Result -Id $id -Method $Method
    } finally {
        if ($null -ne $response) { try { $response.Dispose() } catch { Write-Debug 'Disposing the HTTP response failed.' } }
        $cts.Dispose()
        $message.Dispose()
    }
}

function Send-McpHttpClientNotification {
    <#
    .SYNOPSIS
        Posts a notification; the server answers 202 without a body.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [string] $Method,

        [System.Collections.IDictionary] $Params,

        [int] $TimeoutMs = 10000
    )

    $transport = $Session.Transport
    if ($transport.Closed) { throw [System.IO.IOException]::new('The transport is closed.') }
    $json = ConvertTo-McpJson -InputObject (New-McpNotification -Method $Method -Params $Params)
    $message = New-McpHttpRequestMessage -Session $Session -Method $Method -Params $Params -Json $json
    $cts = [System.Threading.CancellationTokenSource]::new()
    $response = $null
    try {
        $sendTask = $transport.Client.SendAsync($message, [System.Net.Http.HttpCompletionOption]::ResponseContentRead, $cts.Token)
        if (-not (Wait-McpTask -Task $sendTask -Deadline ([datetime]::UtcNow.AddMilliseconds($TimeoutMs)))) {
            $cts.Cancel()
            throw [System.TimeoutException]::new("Posting the notification '$Method' timed out after $TimeoutMs ms.")
        }
        $failure = Get-McpTaskFailure -Task $sendTask
        if ($null -ne $failure) { throw [System.Net.Http.HttpRequestException]::new("Posting the notification '$Method' failed: $($failure.Message)", $failure) }
        $response = $sendTask.Result
        if (-not $response.IsSuccessStatusCode) {
            throw [System.Net.Http.HttpRequestException]::new("The server answered the notification '$Method' with HTTP $([int] $response.StatusCode).")
        }
    } finally {
        if ($null -ne $response) { try { $response.Dispose() } catch { Write-Debug 'Disposing the HTTP response failed.' } }
        $cts.Dispose()
        $message.Dispose()
    }
}
