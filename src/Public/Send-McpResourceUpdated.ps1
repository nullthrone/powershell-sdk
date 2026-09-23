function Send-McpResourceUpdated {
    <#
    .SYNOPSIS
        Sends notifications/resources/updated for a resource to the clients that subscribed to it.
    .DESCRIPTION
        The notification goes to every open subscriptions/listen stream whose resourceSubscriptions contain the
        URI, or a URI it lies below (a subscription to 'docs://guide' also receives 'docs://guide/intro.md'),
        tagged with the stream's subscription id. It works from a handler (-Context) and from any runspace that
        holds the server object (-Server); when the server is not running, nothing is sent.
    .PARAMETER Uri
        The URI of the resource that changed.
    .PARAMETER Context
        The request context of a handler (its Context parameter).
    .PARAMETER Server
        The server; defaults to the server set with New-McpServer -SetDefault.
    .EXAMPLE
        Send-McpResourceUpdated -Uri 'config://app' -Server $server
    #>
    [CmdletBinding(DefaultParameterSetName = 'Server')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Uri,

        [Parameter(ParameterSetName = 'Context', Mandatory)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(ParameterSetName = 'Server')]
        [object] $Server
    )

    process {
        foreach ($item in $Uri) {
            if (-not (Test-McpResourceUri -Uri $item)) { throw [System.ArgumentException]::new("'$item' is not an absolute URI.") }
            $null = Send-McpServerNotification -Method 'notifications/resources/updated' -Params ([ordered]@{ uri = $item }) -Context $Context -Server $Server
        }
    }
}
