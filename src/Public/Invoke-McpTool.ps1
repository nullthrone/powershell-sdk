function Invoke-McpTool {
    <#
    .SYNOPSIS
        Calls a tool (tools/call) and returns its result as an Mcp.ToolResult.
    .DESCRIPTION
        A tool execution error (isError) is returned as a result with IsError set, so that the caller can show
        it to a model. Protocol errors (unknown tool, invalid arguments, timeouts) are thrown. Progress
        notifications are delivered to -OnProgress while the call is running.
    .PARAMETER Name
        The tool name.
    .PARAMETER Arguments
        The arguments (hashtable with JSON-compatible values).
    .PARAMETER Session
        The session; defaults to the default session.
    .PARAMETER OnProgress
        A script block invoked with each progress notification (Mcp.Progress: Progress, Total, Message).
    .PARAMETER TimeoutSeconds
        The timeout for this call; defaults to the session's request timeout.
    .PARAMETER LogLevel
        Ask for notifications/message at this level and above for this call (see the session's Log).
    .EXAMPLE
        (Invoke-McpTool -Name echo -Arguments @{ Text = 'hi' }).Text
    .OUTPUTS
        Mcp.ToolResult
    #>
    [CmdletBinding()]
    [OutputType('Mcp.ToolResult')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Position = 1)]
        [System.Collections.IDictionary] $Arguments,

        [object] $Session,

        [scriptblock] $OnProgress,

        [ValidateRange(0, 86400)]
        [int] $TimeoutSeconds = 0,

        [McpLoggingLevel] $LogLevel
    )

    $target = Resolve-McpSession -Session $Session
    $params = [ordered]@{ name = $Name }
    if ($null -ne $Arguments) { $params['arguments'] = $Arguments } else { $params['arguments'] = [ordered]@{} }
    $level = if ($PSBoundParameters.ContainsKey('LogLevel')) { $LogLevel } else { $target.LogLevel }
    $timeoutMs = $TimeoutSeconds * 1000
    $result = $null
    if ($target.Kind -ne 'Http') {
        $result = (Invoke-McpClientRequestWithInput -Session $target -Method 'tools/call' -Params $params -OnProgress $OnProgress -LogLevel $level -TimeoutMs $timeoutMs).Result
    } else {
        # Streamable HTTP mirrors x-mcp-header parameters into Mcp-Param-* headers; the annotations come from the
        # cached tool list. A header mismatch reported by the server refreshes the list and retries once.
        if ($null -eq $target.Tools) { $null = Get-McpTool -Session $target }
        $headers = Get-McpToolCallHeader -HeaderParameters $target.ToolHeaders[$Name] -Arguments $params['arguments']
        try {
            $result = (Invoke-McpClientRequestWithInput -Session $target -Method 'tools/call' -Params $params -OnProgress $OnProgress -LogLevel $level -TimeoutMs $timeoutMs -Headers $headers).Result
        } catch [McpProtocolException] {
            if ($_.Exception.Code -ne $script:McpErrorCode.HeaderMismatch) { throw }
            Write-Verbose "The server reported a header mismatch for '$Name'; refreshing the tool list and retrying once."
            $null = Get-McpTool -Session $target -Refresh
            $headers = Get-McpToolCallHeader -HeaderParameters $target.ToolHeaders[$Name] -Arguments $params['arguments']
            $result = (Invoke-McpClientRequestWithInput -Session $target -Method 'tools/call' -Params $params -OnProgress $OnProgress -LogLevel $level -TimeoutMs $timeoutMs -Headers $headers).Result
        }
    }
    if ($result -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('The tools/call result is not an object.')
    }
    ConvertTo-McpToolResultObject -Result $result -ToolName $Name
}
