function Start-McpServer {
    <#
    .SYNOPSIS
        Serves a transport with the registered tools until the client disconnects or Stop-McpServer is called.
    .DESCRIPTION
        Over stdio (the default) the server reads JSON-RPC messages from standard input and writes responses
        to standard output, one per line, and exits when standard input is closed. Nothing but protocol
        messages may reach stdout: diagnostics go to stderr (see -LogLevel of New-McpServer).

        Over Streamable HTTP (-Transport Http) the server listens on -Url with System.Net.HttpListener. Every
        POST carries one JSON-RPC request or notification with the request metadata headers of revision
        2026-07-28; the response is a single JSON object, or a request-scoped SSE stream when the request asks
        for progress or log notifications. GET and DELETE answer 405, unknown methods 404, header, version
        and capability violations 400 with the JSON-RPC error codes of the specification.

        A server with legacy revisions (the default, see New-McpServer -SupportedVersions) also speaks the
        Streamable HTTP of 2025-11-25 and 2025-06-18: initialize returns an Mcp-Session-Id, requests with that
        header belong to the session, GET with it opens the session's stream (list-changed and resource-updated
        notifications, server-initiated requests), DELETE ends the session, unknown or expired sessions answer
        404. Over stdio an initialize request opens one process-wide legacy session. The Origin header
        is validated (403): by default only loopback origins and the server's own origin are accepted. Bind
        to 127.0.0.1 unless the server is meant to be reachable from other machines, and put TLS and
        authentication in front of it (a reverse proxy, or on Windows an http.sys certificate binding).

        Tool handlers run in a runspace pool of the size given by -MaxConcurrency of New-McpServer. The
        command blocks until the server has shut down. For tests and in-process clients, Connect-McpServer
        -Server starts the same loop in a background runspace over an in-memory transport.
    .PARAMETER Server
        The server to start; defaults to the default server.
    .PARAMETER Transport
        Stdio (default), Http (with -Url) or InMemory (with -Endpoint).
    .PARAMETER Url
        The MCP endpoint of the HTTP transport (default: http://127.0.0.1:8080/mcp/). Clients must use the
        same host name or address: requests whose Host header names another host or port are answered with 404.
    .PARAMETER AllowedOrigins
        Origins (scheme://host[:port]) accepted in the Origin header, or '*' for any; the default accepts
        loopback origins and the server's own origin. Requests without an Origin header are always accepted.
    .PARAMETER MaxBodyBytes
        The largest request body accepted over HTTP (default: 16 MB; larger bodies answer 413).
    .PARAMETER KeepAliveSeconds
        Seconds between SSE keep-alive comments on open response streams; a failed keep-alive means the client
        closed the stream, which cancels the request (default: 5; 0 disables keep-alives).
    .PARAMETER SessionIdleTimeoutSeconds
        Legacy sessions over HTTP: seconds without a request after which a session without an open GET stream
        ends (default: 1800; 0 keeps sessions until DELETE or shutdown).
    .PARAMETER MaxSessions
        Legacy sessions over HTTP: the maximum number of open sessions; initialize beyond it answers 503 (default: 100).
    .PARAMETER Endpoint
        The server end of an in-memory transport pair (internal use by Connect-McpServer).
    .PARAMETER ShutdownGraceSeconds
        How long running handlers may finish after the input ends or Stop-McpServer was called before they are stopped.
    .EXAMPLE
        New-McpServer -Name echo -Version 1.0.0 -SetDefault
        Register-McpTool -Name echo -ScriptBlock { param([string] $Text) $Text }
        Start-McpServer
    .EXAMPLE
        Start-McpServer -Transport Http -Url http://127.0.0.1:3001/mcp/
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [object] $Server,

        [ValidateSet('Stdio', 'Http', 'InMemory')]
        [string] $Transport = 'Stdio',

        [ValidateNotNull()]
        [uri] $Url = 'http://127.0.0.1:8080/mcp/',

        [string[]] $AllowedOrigins,

        [ValidateRange(1KB, 1GB)]
        [long] $MaxBodyBytes = 16MB,

        [ValidateRange(0, 3600)]
        [int] $KeepAliveSeconds = 5,

        [ValidateRange(0, 604800)]
        [int] $SessionIdleTimeoutSeconds = 1800,

        [ValidateRange(1, 100000)]
        [int] $MaxSessions = 100,

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
    $where = if ($Transport -eq 'Http') { "Streamable HTTP at $Url" } else { $Transport }
    if (-not $PSCmdlet.ShouldProcess("server '$($target.Name)' on $where", 'Start')) { return }
    $transportObject = switch ($Transport) {
        'Stdio' { New-McpStdioServerTransport }
        'Http' { New-McpHttpServerTransport -Url $Url -AllowedOrigins $AllowedOrigins -MaxBodyBytes $MaxBodyBytes -KeepAliveSeconds $KeepAliveSeconds -SessionIdleTimeoutSeconds $SessionIdleTimeoutSeconds -MaxSessions $MaxSessions }
        default { $Endpoint }
    }
    Invoke-McpDispatcher -Server $target -Transport $transportObject -ShutdownGraceSeconds $ShutdownGraceSeconds
}
