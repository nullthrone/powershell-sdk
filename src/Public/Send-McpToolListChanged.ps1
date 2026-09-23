function Send-McpToolListChanged {
    <#
    .SYNOPSIS
        Sends notifications/tools/list_changed to the clients listening for tool list changes.
    .DESCRIPTION
        The notification goes to every open subscriptions/listen stream whose filter asked for
        toolsListChanged, tagged with the stream's subscription id. Register-McpTool and Unregister-McpTool
        send it automatically while the server runs; call this command when the list changes otherwise. It
        works from a handler (-Context) and from any runspace that holds the server object (-Server); when the
        server is not running, nothing is sent.
    .PARAMETER Context
        The request context of a handler (its Context parameter).
    .PARAMETER Server
        The server; defaults to the server set with New-McpServer -SetDefault.
    .EXAMPLE
        Send-McpToolListChanged -Server $server
    #>
    [CmdletBinding(DefaultParameterSetName = 'Server')]
    param(
        [Parameter(ParameterSetName = 'Context', Mandatory)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(ParameterSetName = 'Server')]
        [object] $Server
    )

    $null = Send-McpServerNotification -Method 'notifications/tools/list_changed' -Context $Context -Server $Server
}
