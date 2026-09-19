# Client side: the session object (PSTypeName Mcp.Session), request/response over a transport with progress
# and log notifications dispatched on the way, and the public object shapes (Mcp.ServerInfo, Mcp.Tool,
# Mcp.ToolResult).

$script:McpDefaultSession = $null

function Get-McpModuleVersionString {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $module = $ExecutionContext.SessionState.Module
    if ($module -and $module.Version) { return $module.Version.ToString() }
    '0.0.0'
}

function Test-McpSessionObject {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Session
    )

    $null -ne $Session -and $Session.PSObject.TypeNames -contains 'Mcp.Session'
}

function Resolve-McpSession {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Session
    )

    if ($null -ne $Session) {
        if (-not (Test-McpSessionObject -Session $Session)) {
            throw [System.ArgumentException]::new('The -Session argument is not a session created by Connect-McpServer.')
        }
        if ($Session.Closed) {
            throw [System.InvalidOperationException]::new('The session is closed.')
        }
        return $Session
    }
    if ($null -eq $script:McpDefaultSession -or $script:McpDefaultSession.Closed) {
        throw [System.InvalidOperationException]::new('No session given and no default session; connect with Connect-McpServer first.')
    }
    $script:McpDefaultSession
}

function New-McpClientRequestMeta {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory wire object.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [AllowNull()]
        [object] $ProgressToken,

        [AllowNull()]
        [object] $LogLevel
    )

    $meta = [ordered]@{}
    $meta[$script:McpMetaKey.ProtocolVersion] = $Session.ProtocolVersion
    $meta[$script:McpMetaKey.ClientCapabilities] = $Session.ClientCapabilities
    if ($null -ne $Session.ClientInfo) { $meta[$script:McpMetaKey.ClientInfo] = $Session.ClientInfo }
    if ($null -ne $LogLevel) { $meta[$script:McpMetaKey.LogLevel] = (ConvertTo-McpLoggingLevel -Level $LogLevel).ToString().ToLowerInvariant() }
    if ($null -ne $ProgressToken) { $meta[$script:McpMetaKey.ProgressToken] = $ProgressToken }
    $meta
}

function Send-McpClientNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [string] $Method,

        [System.Collections.IDictionary] $Params
    )

    $notification = New-McpNotification -Method $Method -Params $Params
    Send-McpTransportLine -Transport $Session.Transport -Line (ConvertTo-McpJson -InputObject $notification)
}

function Invoke-McpClientRequest {
    <#
    .SYNOPSIS
        Sends a request with the session's _meta and waits for its response, dispatching notifications meanwhile.
    .DESCRIPTION
        Returns the result object. A JSON-RPC error response is thrown as McpProtocolException. On timeout a
        notifications/cancelled is sent and a TimeoutException thrown. Progress notifications for the request's
        token go to -OnProgress; notifications/message go to the session log and -OnLog; other notifications
        are queued on the session.
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

        [int] $TimeoutMs = 0
    )

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
    $request = New-McpRequest -Id $id -Method $Method -Params $requestParams
    Send-McpTransportLine -Transport $Session.Transport -Line (ConvertTo-McpJson -InputObject $request)

    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        $remaining = [int] [math]::Max(1, [math]::Min(500, ($deadline - [datetime]::UtcNow).TotalMilliseconds))
        $received = Receive-McpTransportLine -Transport $Session.Transport -TimeoutMs $remaining
        # (if/elseif rather than switch: inside a switch, continue would apply to the switch, not to the loop.)
        if ($received.Status -eq 'Eof') {
            $Session.Closed = $true
            $hint = if ($Session.StandardErrorPath) { " Its stderr was captured in '$($Session.StandardErrorPath)'." } else { '' }
            throw [System.IO.IOException]::new("The server closed the connection while '$Method' (id $id) was pending.$hint")
        } elseif ($received.Status -eq 'Timeout') {
            if ([datetime]::UtcNow -lt $deadline) { continue }
            try {
                Send-McpClientNotification -Session $Session -Method 'notifications/cancelled' -Params ([ordered]@{ requestId = $id; reason = "timeout after $TimeoutMs ms" })
            } catch {
                Write-Debug 'Sending the cancellation failed.'
            }
            throw [System.TimeoutException]::new("No response to '$Method' (id $id) within $TimeoutMs ms.")
        }
        $message = $null
        try {
            $message = ConvertFrom-McpJson -Json $received.Line
        } catch {
            Write-Warning "Ignoring a line from the server that is not JSON: $($received.Line.Substring(0, [math]::Min(120, $received.Line.Length)))"
            continue
        }
        switch (Get-McpMessageKind -Message $message) {
            'Response' {
                if ([string] $message['id'] -ceq [string] $id) { return $message['result'] }
                Write-Debug "Ignoring a response with id $($message['id'])."
            }
            'ErrorResponse' {
                if ($message.Contains('id') -and [string] $message['id'] -ceq [string] $id) {
                    $errorObject = $message['error']
                    $data = if ($errorObject.Contains('data')) { $errorObject['data'] } else { $null }
                    throw [McpProtocolException]::new([int] $errorObject['code'], [string] $errorObject['message'], $data)
                }
                Write-Debug "Ignoring an error response with id $($message['id'])."
            }
            'Notification' {
                Invoke-McpClientNotificationHandler -Session $Session -Message $message -ProgressToken $progressToken -OnProgress $OnProgress
            }
            'Request' {
                Write-Warning "Ignoring a request '$($message['method'])' from the server: servers do not send requests in protocol version $($Session.ProtocolVersion)."
            }
            default {
                Write-Warning 'Ignoring an invalid JSON-RPC message from the server.'
            }
        }
    }
}

function Invoke-McpClientNotificationHandler {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Message,

        [AllowNull()]
        [object] $ProgressToken,

        [scriptblock] $OnProgress
    )

    $method = [string] $Message['method']
    $params = if ($Message.Contains('params') -and $Message['params'] -is [System.Collections.IDictionary]) { $Message['params'] } else { [ordered]@{} }
    switch ($method) {
        'notifications/progress' {
            $token = if ($params.Contains('progressToken')) { $params['progressToken'] } else { $null }
            if ($null -ne $ProgressToken -and $null -ne $OnProgress -and [string] $token -ceq [string] $ProgressToken) {
                $progress = [pscustomobject]@{
                    PSTypeName = 'Mcp.Progress'
                    Progress   = $params['progress']
                    Total      = if ($params.Contains('total')) { $params['total'] } else { $null }
                    Message    = if ($params.Contains('message')) { $params['message'] } else { $null }
                    Token      = $token
                }
                try { & $OnProgress $progress } catch { Write-Warning "The progress callback failed: $($_.Exception.Message)" }
            } else {
                $Session.Notifications.Enqueue($Message)
            }
        }
        'notifications/message' {
            $entry = [pscustomobject]@{
                PSTypeName = 'Mcp.LogMessage'
                Level      = if ($params.Contains('level')) { [string] $params['level'] } else { 'info' }
                Logger     = if ($params.Contains('logger')) { [string] $params['logger'] } else { $null }
                Data       = if ($params.Contains('data')) { $params['data'] } else { $null }
                Received   = [datetime]::UtcNow
            }
            $Session.Log.Add($entry)
            if ($Session.OnLog) {
                try { & $Session.OnLog $entry } catch { Write-Warning "The log callback failed: $($_.Exception.Message)" }
            }
        }
        default {
            $Session.Notifications.Enqueue($Message)
        }
    }
}

function ConvertTo-McpServerInfoObject {
    [CmdletBinding()]
    [OutputType('Mcp.ServerInfo')]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $DiscoverResult,

        [Parameter(Mandatory)]
        [string] $ProtocolVersion
    )

    $info = [ordered]@{}
    if ($DiscoverResult.Contains('_meta') -and $DiscoverResult['_meta'] -is [System.Collections.IDictionary] -and $DiscoverResult['_meta'].Contains($script:McpMetaKey.ServerInfo)) {
        $info = $DiscoverResult['_meta'][$script:McpMetaKey.ServerInfo]
    }
    $get = { param($table, $key) if ($table -is [System.Collections.IDictionary] -and $table.Contains($key)) { $table[$key] } else { $null } }
    [pscustomobject]@{
        PSTypeName        = 'Mcp.ServerInfo'
        Name              = & $get $info 'name'
        Version           = & $get $info 'version'
        Title             = & $get $info 'title'
        Description       = & $get $info 'description'
        WebsiteUrl        = & $get $info 'websiteUrl'
        Icons             = & $get $info 'icons'
        ProtocolVersion   = $ProtocolVersion
        SupportedVersions = @(& $get $DiscoverResult 'supportedVersions')
        Capabilities      = & $get $DiscoverResult 'capabilities'
        Instructions      = & $get $DiscoverResult 'instructions'
        TtlMs             = & $get $DiscoverResult 'ttlMs'
        CacheScope        = & $get $DiscoverResult 'cacheScope'
        Raw               = $DiscoverResult
    }
}

function ConvertTo-McpToolObject {
    [CmdletBinding()]
    [OutputType('Mcp.Tool')]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Tool
    )

    $get = { param($key) if ($Tool.Contains($key)) { $Tool[$key] } else { $null } }
    [pscustomobject]@{
        PSTypeName   = 'Mcp.Tool'
        Name         = & $get 'name'
        Title        = & $get 'title'
        Description  = & $get 'description'
        InputSchema  = & $get 'inputSchema'
        OutputSchema = & $get 'outputSchema'
        Annotations  = & $get 'annotations'
        Icons        = & $get 'icons'
        Meta         = & $get '_meta'
        Raw          = $Tool
    }
}

function ConvertTo-McpToolResultObject {
    [CmdletBinding()]
    [OutputType('Mcp.ToolResult')]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Result,

        [Parameter(Mandatory)]
        [string] $ToolName
    )

    $content = @()
    if ($Result.Contains('content') -and $null -ne $Result['content']) {
        $content = @($Result['content'] | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { [pscustomobject] $_ } else { $_ } })
    }
    $text = ($content | Where-Object { $_.PSObject.Properties['type'] -and $_.type -eq 'text' } | ForEach-Object { [string] $_.text }) -join "`n"
    [pscustomobject]@{
        PSTypeName        = 'Mcp.ToolResult'
        ToolName          = $ToolName
        IsError           = [bool] ($Result.Contains('isError') -and $Result['isError'])
        Text              = $text
        Content           = $content
        StructuredContent = if ($Result.Contains('structuredContent')) { $Result['structuredContent'] } else { $null }
        ResultType        = if ($Result.Contains('resultType')) { [string] $Result['resultType'] } else { 'complete' }
        Meta              = if ($Result.Contains('_meta')) { $Result['_meta'] } else { $null }
        Raw               = $Result
    }
}

function Start-McpBackgroundServer {
    <#
    .SYNOPSIS
        Runs Start-McpServer for an in-memory endpoint in a background runspace; returns the runspace handles.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The caller (Connect-McpServer) owns the ShouldProcess decision.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [Parameter(Mandatory)]
        [hashtable] $Endpoint
    )

    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    if ($IsWindows) { $sessionState.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass }
    $sessionState.ImportPSModule([string[]] @($script:McpModuleManifestPath))
    $runspace = [runspacefactory]::CreateRunspace($sessionState)
    $runspace.Open()
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace
    $null = $powershell.AddCommand('Start-McpServer').AddParameter('Server', $Server).AddParameter('Transport', 'InMemory').AddParameter('Endpoint', $Endpoint)
    $handle = $powershell.BeginInvoke()
    @{
        PowerShell = $powershell
        Handle     = $handle
        Runspace   = $runspace
    }
}

function Stop-McpBackgroundServer {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The caller (Disconnect-McpServer) owns the ShouldProcess decision.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Background,

        [int] $TimeoutSeconds = 10
    )

    $powershell = $Background.PowerShell
    try {
        if (-not $Background.Handle.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000)) {
            Write-Warning 'The in-memory server did not stop in time; stopping it forcibly.'
            $powershell.Stop()
        }
        if ($powershell.InvocationStateInfo.State -eq [System.Management.Automation.PSInvocationState]::Failed) {
            Write-Warning "The in-memory server failed: $($powershell.InvocationStateInfo.Reason.Message)"
        }
        foreach ($record in $powershell.Streams.Error) { Write-Warning "In-memory server error: $record" }
    } finally {
        try { $powershell.Dispose() } catch { Write-Debug 'Disposing the server runspace failed.' }
        try { $Background.Runspace.Dispose() } catch { Write-Debug 'Disposing the server runspace failed.' }
    }
}
