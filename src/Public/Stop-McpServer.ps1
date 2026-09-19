function Stop-McpServer {
    <#
    .SYNOPSIS
        Asks a running server to shut down: no new requests are accepted and running handlers get a grace period.
    .DESCRIPTION
        Can be called from a tool handler (it runs in a worker runspace) or from another runspace that holds
        the server object. Start-McpServer returns once the shutdown has completed.
    .PARAMETER Server
        The server to stop; defaults to the default server.
    .EXAMPLE
        Stop-McpServer -Server $server
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [object] $Server
    )

    $target = Resolve-McpServer -Server $Server
    if (-not $PSCmdlet.ShouldProcess("server '$($target.Name)'", 'Stop')) { return }
    $target.State.StopRequested = $true
    $signal = $target.State.Signal
    if ($null -ne $signal) { $null = $signal.Set() }
}
