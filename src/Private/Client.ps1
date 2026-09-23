# Client side: the session object (PSTypeName Mcp.Session), request/response over a transport with progress
# and log notifications dispatched on the way, the result cache that honours the servers' caching hints, list
# pagination, and the public object shapes (Mcp.ServerInfo, Mcp.Tool, Mcp.ToolResult, Mcp.Content,
# Mcp.Resource, Mcp.ResourceTemplate, Mcp.ResourceContent, Mcp.Prompt, Mcp.PromptResult, Mcp.Completion).

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

    if ($Session.Transport.Kind -eq 'Http') {
        Send-McpHttpClientNotification -Session $Session -Method $Method -Params $Params
        return
    }
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

        [int] $TimeoutMs = 0,

        # Additional HTTP headers of this request (Streamable HTTP only), for example Mcp-Param-* headers.
        [hashtable] $Headers
    )

    if ($Session.Transport.Kind -eq 'Http') {
        return Invoke-McpHttpClientRequest -Session $Session -Method $Method -Params $Params -OnProgress $OnProgress -LogLevel $LogLevel -TimeoutMs $TimeoutMs -Headers $Headers
    }
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
    if ($info.Count -eq 0 -and $DiscoverResult.Contains('serverInfo') -and $DiscoverResult['serverInfo'] -is [System.Collections.IDictionary]) {
        # Servers written against the drafts before spec PR #3002 put serverInfo into the result body.
        $info = $DiscoverResult['serverInfo']
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
        $content = @($Result['content'] | ForEach-Object { ConvertTo-McpClientContentObject -Block $_ })
    }
    [pscustomobject]@{
        PSTypeName        = 'Mcp.ToolResult'
        ToolName          = $ToolName
        IsError           = [bool] ($Result.Contains('isError') -and $Result['isError'])
        Text              = Get-McpContentText -Content $content
        Content           = $content
        StructuredContent = if ($Result.Contains('structuredContent')) { $Result['structuredContent'] } else { $null }
        ResultType        = if ($Result.Contains('resultType')) { [string] $Result['resultType'] } else { 'complete' }
        Meta              = if ($Result.Contains('_meta')) { $Result['_meta'] } else { $null }
        Raw               = $Result
    }
}

function Get-McpWireValue {
    <#
    .SYNOPSIS
        A member of a wire object, or $null when it is absent.
    #>
    [CmdletBinding()]
    [OutputType([object], [object[]])]
    param(
        [AllowNull()]
        [object] $Object,

        [Parameter(Mandatory)]
        [string] $Key
    )

    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Key)) { return , $Object[$Key] }
    $null
}

function ConvertTo-McpClientContentObject {
    <#
    .SYNOPSIS
        A content block received from a server as Mcp.Content (its wire members as properties; GetBytes() decodes binary data).
    #>
    [CmdletBinding()]
    [OutputType('Mcp.Content')]
    param(
        [AllowNull()]
        [object] $Block
    )

    if ($Block -isnot [System.Collections.IDictionary]) { return $Block }
    $object = [pscustomobject] $Block
    $object.PSObject.TypeNames.Insert(0, 'Mcp.Content')
    $object
}

function Get-McpContentText {
    <#
    .SYNOPSIS
        The text of the text blocks of a content list, joined with newlines.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Content
    )

    (@($Content) | Where-Object { $null -ne $_ -and $_.PSObject.Properties['type'] -and $_.type -eq 'text' } | ForEach-Object { [string] $_.text }) -join "`n"
}

function ConvertTo-McpResourceObject {
    [CmdletBinding()]
    [OutputType('Mcp.Resource')]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Resource
    )

    [pscustomobject]@{
        PSTypeName  = 'Mcp.Resource'
        Uri         = Get-McpWireValue -Object $Resource -Key 'uri'
        Name        = Get-McpWireValue -Object $Resource -Key 'name'
        Title       = Get-McpWireValue -Object $Resource -Key 'title'
        Description = Get-McpWireValue -Object $Resource -Key 'description'
        MimeType    = Get-McpWireValue -Object $Resource -Key 'mimeType'
        Size        = Get-McpWireValue -Object $Resource -Key 'size'
        Annotations = Get-McpWireValue -Object $Resource -Key 'annotations'
        Icons       = Get-McpWireValue -Object $Resource -Key 'icons'
        Meta        = Get-McpWireValue -Object $Resource -Key '_meta'
        Raw         = $Resource
    }
}

function ConvertTo-McpResourceTemplateObject {
    [CmdletBinding()]
    [OutputType('Mcp.ResourceTemplate')]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template
    )

    [pscustomobject]@{
        PSTypeName  = 'Mcp.ResourceTemplate'
        UriTemplate = Get-McpWireValue -Object $Template -Key 'uriTemplate'
        Name        = Get-McpWireValue -Object $Template -Key 'name'
        Title       = Get-McpWireValue -Object $Template -Key 'title'
        Description = Get-McpWireValue -Object $Template -Key 'description'
        MimeType    = Get-McpWireValue -Object $Template -Key 'mimeType'
        Annotations = Get-McpWireValue -Object $Template -Key 'annotations'
        Icons       = Get-McpWireValue -Object $Template -Key 'icons'
        Meta        = Get-McpWireValue -Object $Template -Key '_meta'
        Raw         = $Template
    }
}

function ConvertTo-McpResourceContentObject {
    [CmdletBinding()]
    [OutputType('Mcp.ResourceContent')]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Content
    )

    [pscustomobject]@{
        PSTypeName = 'Mcp.ResourceContent'
        Uri        = Get-McpWireValue -Object $Content -Key 'uri'
        MimeType   = Get-McpWireValue -Object $Content -Key 'mimeType'
        Text       = Get-McpWireValue -Object $Content -Key 'text'
        Blob       = Get-McpWireValue -Object $Content -Key 'blob'
        Meta       = Get-McpWireValue -Object $Content -Key '_meta'
        Raw        = $Content
    }
}

function ConvertTo-McpPromptObject {
    [CmdletBinding()]
    [OutputType('Mcp.Prompt')]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Prompt
    )

    $wireArguments = Get-McpWireValue -Object $Prompt -Key 'arguments'
    $arguments = @(@($wireArguments) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object {
            [pscustomobject]@{
                PSTypeName  = 'Mcp.PromptArgument'
                Name        = Get-McpWireValue -Object $_ -Key 'name'
                Title       = Get-McpWireValue -Object $_ -Key 'title'
                Description = Get-McpWireValue -Object $_ -Key 'description'
                Required    = [bool] (Get-McpWireValue -Object $_ -Key 'required')
            }
        })
    [pscustomobject]@{
        PSTypeName  = 'Mcp.Prompt'
        Name        = Get-McpWireValue -Object $Prompt -Key 'name'
        Title       = Get-McpWireValue -Object $Prompt -Key 'title'
        Description = Get-McpWireValue -Object $Prompt -Key 'description'
        Arguments   = $arguments
        Icons       = Get-McpWireValue -Object $Prompt -Key 'icons'
        Meta        = Get-McpWireValue -Object $Prompt -Key '_meta'
        Raw         = $Prompt
    }
}

function ConvertTo-McpPromptResultObject {
    [CmdletBinding()]
    [OutputType('Mcp.PromptResult')]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Result,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $wireMessages = Get-McpWireValue -Object $Result -Key 'messages'
    $messages = @(@($wireMessages) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object {
            [pscustomobject]@{
                PSTypeName = 'Mcp.PromptMessage'
                Role       = Get-McpWireValue -Object $_ -Key 'role'
                Content    = ConvertTo-McpClientContentObject -Block (Get-McpWireValue -Object $_ -Key 'content')
            }
        })
    [pscustomobject]@{
        PSTypeName  = 'Mcp.PromptResult'
        Name        = $Name
        Description = Get-McpWireValue -Object $Result -Key 'description'
        Messages    = $messages
        Text        = Get-McpContentText -Content @($messages | ForEach-Object { $_.Content })
        Meta        = Get-McpWireValue -Object $Result -Key '_meta'
        Raw         = $Result
    }
}

function ConvertTo-McpCompletionObject {
    [CmdletBinding()]
    [OutputType('Mcp.Completion')]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Result
    )

    $completion = Get-McpWireValue -Object $Result -Key 'completion'
    $values = Get-McpWireValue -Object $completion -Key 'values'
    [pscustomobject]@{
        PSTypeName = 'Mcp.Completion'
        Values     = [string[]] @(@($values) | Where-Object { $null -ne $_ } | ForEach-Object { [string] $_ })
        Total      = Get-McpWireValue -Object $completion -Key 'total'
        HasMore    = [bool] (Get-McpWireValue -Object $completion -Key 'hasMore')
        Raw        = $Result
    }
}

function Get-McpResultCacheHint {
    <#
    .SYNOPSIS
        The ttlMs and cacheScope of a result; a result without a valid ttlMs is not cached.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object] $Result
    )

    $ttl = Get-McpWireValue -Object $Result -Key 'ttlMs'
    $scope = Get-McpWireValue -Object $Result -Key 'cacheScope'
    @{
        TtlMs      = if (($ttl -is [long] -or $ttl -is [int]) -and $ttl -ge 0) { [long] $ttl } else { [long] 0 }
        CacheScope = if ($scope -in @('public', 'private')) { [string] $scope } else { 'private' }
    }
}

function Get-McpClientCacheEntry {
    <#
    .SYNOPSIS
        A fresh entry of the session's result cache, or $null when there is none or it has expired.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [string] $Key
    )

    $entry = $Session.Cache[$Key]
    if ($null -eq $entry) { return $null }
    if ([datetime]::UtcNow -ge $entry.ExpiresAt) {
        $Session.Cache.Remove($Key)
        return $null
    }
    $entry
}

function Set-McpClientCacheEntry {
    <#
    .SYNOPSIS
        Caches a value for the result's ttlMs; a ttlMs of 0 (immediately stale) removes the entry instead.
    .DESCRIPTION
        The cache belongs to one session, so private and public results are both reusable; the scope is kept
        with the entry.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes an in-memory cache.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [string] $Key,

        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [hashtable] $CacheHint
    )

    if ($CacheHint.TtlMs -le 0) {
        $Session.Cache.Remove($Key)
        return
    }
    $Session.Cache[$Key] = @{
        Value      = $Value
        ExpiresAt  = [datetime]::UtcNow.AddMilliseconds([double] $CacheHint.TtlMs)
        CacheScope = $CacheHint.CacheScope
    }
}

function Invoke-McpClientListRequest {
    <#
    .SYNOPSIS
        Calls a list method and follows nextCursor through all pages.
    .OUTPUTS
        A hashtable with Items (the wire items), and the CacheHint of the whole list: the shortest ttlMs of
        its pages and private when any page is private.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [string] $Method,

        # The member of the result that holds the items (tools, resources, resourceTemplates, prompts).
        [Parameter(Mandatory)]
        [string] $ItemKey
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $hint = $null
    $cursor = $null
    $pages = 0
    do {
        $params = [ordered]@{}
        if ($null -ne $cursor) { $params['cursor'] = $cursor }
        $result = Invoke-McpClientRequest -Session $Session -Method $Method -Params $params
        if ($result -isnot [System.Collections.IDictionary] -or -not $result.Contains($ItemKey)) {
            throw [System.InvalidOperationException]::new("The $Method result has no $ItemKey member.")
        }
        foreach ($item in @($result[$ItemKey])) {
            if ($item -is [System.Collections.IDictionary]) { $items.Add($item) }
        }
        $pageHint = Get-McpResultCacheHint -Result $result
        if ($null -eq $hint) {
            $hint = $pageHint
        } else {
            $hint = @{
                TtlMs      = [math]::Min($hint.TtlMs, $pageHint.TtlMs)
                CacheScope = if ($hint.CacheScope -eq 'private' -or $pageHint.CacheScope -eq 'private') { 'private' } else { 'public' }
            }
        }
        $cursor = if ($result.Contains('nextCursor') -and $null -ne $result['nextCursor']) { [string] $result['nextCursor'] } else { $null }
        $pages++
        if ($pages -gt 10000) { throw [System.InvalidOperationException]::new("$Method paged more than 10000 times.") }
    } while ($null -ne $cursor)
    @{
        Items     = $items.ToArray()
        CacheHint = $hint
    }
}

function Test-McpResourceNotFoundError {
    <#
    .SYNOPSIS
        Whether an error response reports an unknown resource: -32602 with data.uri (2026-07-28) or -32002 (earlier revisions).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [McpProtocolException] $Exception
    )

    if ($Exception.Code -eq -32002) { return $true }
    $Exception.Code -eq $script:McpErrorCode.InvalidParams -and $Exception.Data -is [System.Collections.IDictionary] -and $Exception.Data.Contains('uri')
}

function Start-McpBackgroundServer {
    <#
    .SYNOPSIS
        Runs Start-McpServer in a background runspace (for an in-memory endpoint or with given parameters); returns the runspace handles.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The caller (Connect-McpServer) owns the ShouldProcess decision.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        # The server end of an in-memory transport pair.
        [hashtable] $Endpoint,

        # Alternatively, the parameters of Start-McpServer (for example Transport and Url of an HTTP server).
        [hashtable] $Parameters
    )

    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    if ($IsWindows) { $sessionState.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass }
    $sessionState.ImportPSModule([string[]] @($script:McpModuleManifestPath))
    $runspace = [runspacefactory]::CreateRunspace($sessionState)
    $runspace.Open()
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace
    $command = $powershell.AddCommand('Start-McpServer').AddParameter('Server', $Server)
    if ($null -ne $Endpoint) {
        $null = $command.AddParameter('Transport', 'InMemory').AddParameter('Endpoint', $Endpoint)
    } elseif ($null -ne $Parameters) {
        $null = $command.AddParameters($Parameters)
    } else {
        throw [System.ArgumentException]::new('Start-McpBackgroundServer needs -Endpoint or -Parameters.')
    }
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
