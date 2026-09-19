function Start-McpServer {
    <#
    .SYNOPSIS
        Serves a transport with the registered tools until the client disconnects or Stop-McpServer is called.
    .DESCRIPTION
        Over stdio (the default) the server reads JSON-RPC messages from standard input and writes responses
        to standard output, one per line, and exits when standard input is closed. Nothing but protocol
        messages may reach stdout: diagnostics go to stderr (see -LogLevel of New-McpServer). Tool handlers
        run in a runspace pool of the size given by -MaxConcurrency of New-McpServer.

        The command blocks until the server has shut down. For tests and in-process clients, Connect-McpServer
        -Server starts the same loop in a background runspace over an in-memory transport.
    .PARAMETER Server
        The server to start; defaults to the default server.
    .PARAMETER Transport
        Stdio (default) or InMemory (with -Endpoint).
    .PARAMETER Endpoint
        The server end of an in-memory transport pair (internal use by Connect-McpServer).
    .PARAMETER ShutdownGraceSeconds
        How long running handlers may finish after the input ends before they are stopped.
    .EXAMPLE
        New-McpServer -Name echo -Version 1.0.0 -SetDefault
        Register-McpTool -Name echo -ScriptBlock { param([string] $Text) $Text }
        Start-McpServer
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [object] $Server,

        [ValidateSet('Stdio', 'InMemory')]
        [string] $Transport = 'Stdio',

        [hashtable] $Endpoint,

        [ValidateRange(0, 3600)]
        [int] $ShutdownGraceSeconds = 5
    )

    $target = Resolve-McpServer -Server $Server
    if ($target.State.Started) {
        throw [System.InvalidOperationException]::new("Server '$($target.Name)' is already running.")
    }
    if ($Transport -eq 'InMemory' -and ($null -eq $Endpoint -or $Endpoint.Kind -ne 'InMemory')) {
        throw [System.ArgumentException]::new('-Transport InMemory requires -Endpoint (the server end of New-McpInMemoryTransportPair).')
    }
    if (-not $PSCmdlet.ShouldProcess("server '$($target.Name)' on $Transport", 'Start')) { return }
    $transportObject = if ($Transport -eq 'Stdio') { New-McpStdioServerTransport } else { $Endpoint }
    Invoke-McpDispatcher -Server $target -Transport $transportObject -ShutdownGraceSeconds $ShutdownGraceSeconds
}
