function Write-McpLog {
    <#
    .SYNOPSIS
        Logs a message to stderr and, when the request asked for it, as a notifications/message to the client.
    .DESCRIPTION
        The message goes to stderr when its level reaches the server's log level. It is also sent to the
        client as notifications/message when the request carried io.modelcontextprotocol/logLevel in its _meta
        and the level reaches that level. Without a context only stderr is written.
    .PARAMETER Message
        The message text.
    .PARAMETER Level
        The severity: debug, info, notice, warning, error, critical, alert or emergency (default: info).
    .PARAMETER Context
        The request context (the handler's Context parameter).
    .PARAMETER Logger
        The logger name; defaults to the name of the tool or prompt or the URI of the resource being served.
    .PARAMETER Data
        Structured data sent instead of the message text in the notification (any JSON-serialisable value).
    .EXAMPLE
        Write-McpLog -Context $Context -Level warning -Message 'Rate limit is close.'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string] $Message,

        [McpLoggingLevel] $Level = [McpLoggingLevel]::Info,

        [object] $Context,

        [string] $Logger,

        [object] $Data
    )

    $threshold = if ($null -ne $Context -and $Context.PSObject.Properties['ServerLogLevel'] -and $null -ne $Context.ServerLogLevel) { $Context.ServerLogLevel } else { $script:McpDefaultLogLevel }
    $loggerName = if ($Logger) { $Logger } elseif ($null -ne $Context -and $Context.PSObject.Properties['Name']) { $Context.Name } else { $null }
    Write-McpStderr -Level $Level -Threshold $threshold -Logger $loggerName -Message $Message

    if ($null -eq $Context -or -not $Context.PSObject.Properties['LogLevel'] -or $null -eq $Context.LogLevel -or $null -eq $Context.Sink) { return }
    $requested = ConvertTo-McpLoggingLevel -Level $Context.LogLevel
    if ([int] $Level -lt [int] $requested) { return }
    $params = [ordered]@{
        level = $Level.ToString().ToLowerInvariant()
    }
    if ($loggerName) { $params['logger'] = $loggerName }
    $params['data'] = if ($PSBoundParameters.ContainsKey('Data')) { $Data } else { $Message }
    $notification = New-McpNotification -Method 'notifications/message' -Params $params
    Send-McpSinkMessage -Sink $Context.Sink -Kind Notification -RequestId $Context.RequestId -Json (ConvertTo-McpJson -InputObject $notification)
}
