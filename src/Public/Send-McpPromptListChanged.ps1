function Send-McpPromptListChanged {
    <#
    .SYNOPSIS
        Sends notifications/prompts/list_changed to the clients listening for prompt list changes.
    .DESCRIPTION
        The notification goes to every open subscriptions/listen stream whose filter asked for
        promptsListChanged, tagged with the stream's subscription id. Register-McpPrompt and Unregister-McpPrompt
        send it automatically while the server runs; call this command when the list changes otherwise. It
        works from a handler (-Context) and from any runspace that holds the server object (-Server); when the
        server is not running, nothing is sent.
    .PARAMETER Context
        The request context of a handler (its Context parameter).
    .PARAMETER Server
        The server; defaults to the server set with New-McpServer -SetDefault.
    .EXAMPLE
        Send-McpPromptListChanged -Server $server
    #>
    [CmdletBinding(DefaultParameterSetName = 'Server')]
    param(
        [Parameter(ParameterSetName = 'Context', Mandatory)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(ParameterSetName = 'Server')]
        [object] $Server
    )

    $null = Send-McpServerNotification -Method 'notifications/prompts/list_changed' -Context $Context -Server $Server
}
