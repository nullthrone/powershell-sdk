function Connect-McpServer {
    <#
    .SYNOPSIS
        Connects to an MCP server over stdio (a server process), Streamable HTTP (a URL) or in memory (a server object) and returns a session.
    .DESCRIPTION
        For stdio the command is started with redirected standard streams; its stderr is captured in a file
        (see the session's StandardErrorPath). Over Streamable HTTP every request is its own POST to the URL
        with the request metadata headers of revision 2026-07-28 (MCP-Protocol-Version, Mcp-Method, Mcp-Name,
        Mcp-Param-*); responses arrive as JSON or as a request-scoped SSE stream. The session probes the server
        with server/discover, selects a protocol version from the server's supported versions and caches the
        server info. Servers that only speak the initialize handshake of earlier revisions are not supported by
        this milestone.

        With -Server, the given server object runs in a background runspace of this process over an in-memory
        transport: the way to test a server without a child process.

        The first session becomes the default session for the other client commands; -SetDefault makes a later
        session the default.
    .PARAMETER Command
        The server executable (for a PowerShell server: pwsh).
    .PARAMETER Arguments
        The command-line arguments, for example -NoLogo, -NoProfile, -NonInteractive, -File, ./server.ps1.
    .PARAMETER WorkingDirectory
        The working directory of the server process.
    .PARAMETER Environment
        Additional environment variables for the server process.
    .PARAMETER StandardErrorPath
        The file that receives the server's stderr (default: a file in the temp folder).
    .PARAMETER Url
        The URL of a Streamable HTTP endpoint, for example http://127.0.0.1:8080/mcp/.
    .PARAMETER Headers
        Additional HTTP headers sent with every request to -Url (for example an Authorization header).
    .PARAMETER NoProxy
        Do not use the system or environment proxy for -Url (loopback URLs never use a proxy).
    .PARAMETER Server
        A server object (New-McpServer) to run in-process over an in-memory transport.
    .PARAMETER ClientInfo
        The clientInfo sent with every request (name and version); defaults to this module.
    .PARAMETER Capabilities
        The client capabilities declared with every request (default: none).
    .PARAMETER ProtocolVersion
        The preferred protocol version (default: 2026-07-28).
    .PARAMETER RequestTimeoutSeconds
        The default timeout for requests (default: 60).
    .PARAMETER ConnectTimeoutSeconds
        The timeout for the initial server/discover (default: 30).
    .PARAMETER LogLevel
        Ask the server for notifications/message at this level and above (io.modelcontextprotocol/logLevel).
    .PARAMETER OnLog
        A script block invoked with each notifications/message received (Mcp.LogMessage).
    .PARAMETER SetDefault
        Make this session the default session.
    .EXAMPLE
        $session = Connect-McpServer -Command pwsh -Arguments '-NoLogo', '-NoProfile', '-NonInteractive', '-File', './examples/echo-server.ps1'
    .EXAMPLE
        $session = Connect-McpServer -Url http://127.0.0.1:8080/mcp/
    .EXAMPLE
        $session = Connect-McpServer -Server $server
    .OUTPUTS
        Mcp.Session
    #>
    [CmdletBinding(DefaultParameterSetName = 'Stdio', SupportsShouldProcess)]
    [OutputType('Mcp.Session')]
    param(
        [Parameter(ParameterSetName = 'Stdio', Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Command,

        [Parameter(ParameterSetName = 'Stdio', Position = 1)]
        [string[]] $Arguments = @(),

        [Parameter(ParameterSetName = 'Stdio')]
        [string] $WorkingDirectory,

        [Parameter(ParameterSetName = 'Stdio')]
        [hashtable] $Environment,

        [Parameter(ParameterSetName = 'Stdio')]
        [string] $StandardErrorPath,

        [Parameter(ParameterSetName = 'Http', Mandatory)]
        [ValidateNotNull()]
        [uri] $Url,

        [Parameter(ParameterSetName = 'Http')]
        [hashtable] $Headers,

        [Parameter(ParameterSetName = 'Http')]
        [switch] $NoProxy,

        [Parameter(ParameterSetName = 'InMemory', Mandatory)]
        [ValidateNotNull()]
        [object] $Server,

        [hashtable] $ClientInfo,

        [hashtable] $Capabilities,

        [ValidateNotNullOrEmpty()]
        [string] $ProtocolVersion = '2026-07-28',

        [ValidateRange(1, 86400)]
        [int] $RequestTimeoutSeconds = 60,

        [ValidateRange(1, 3600)]
        [int] $ConnectTimeoutSeconds = 30,

        [McpLoggingLevel] $LogLevel,

        [scriptblock] $OnLog,

        [switch] $SetDefault
    )

    $target = switch ($PSCmdlet.ParameterSetName) {
        'InMemory' { "server '$($Server.Name)' in memory" }
        'Http' { $Url.AbsoluteUri }
        default { "$Command $($Arguments -join ' ')" }
    }
    if (-not $PSCmdlet.ShouldProcess($target, 'Connect')) { return }

    $clientInfoObject = [ordered]@{ name = 'ModelContextProtocol'; version = Get-McpModuleVersionString }
    if ($ClientInfo) {
        foreach ($key in $ClientInfo.Keys) { $clientInfoObject[[string] $key] = $ClientInfo[$key] }
    }
    if (-not $clientInfoObject.Contains('name') -or -not $clientInfoObject.Contains('version')) {
        throw [System.ArgumentException]::new('-ClientInfo needs name and version.')
    }
    $capabilityObject = if ($Capabilities) { ConvertFrom-McpJson -Json (ConvertTo-McpJson -InputObject $Capabilities) } else { [ordered]@{} }

    $transport = $null
    $background = $null
    $stderrPath = $null
    if ($PSCmdlet.ParameterSetName -eq 'InMemory') {
        if (-not (Test-McpServerObject -Server $Server)) { throw [System.ArgumentException]::new('-Server must be a server created by New-McpServer.') }
        $pair = New-McpInMemoryTransportPair
        $background = Start-McpBackgroundServer -Server $Server -Endpoint $pair.Server
        $transport = $pair.Client
    } elseif ($PSCmdlet.ParameterSetName -eq 'Http') {
        $transport = New-McpHttpClientTransport -Url $Url -Headers $Headers -NoProxy:$NoProxy
    } else {
        $transport = New-McpProcessTransport -FilePath $Command -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -Environment $Environment -StandardErrorPath $StandardErrorPath
        $stderrPath = $transport.StandardErrorPath
    }

    $session = [pscustomobject]@{
        PSTypeName         = 'Mcp.Session'
        Name               = $null
        Kind               = $transport.Kind
        Endpoint           = $target
        Transport          = $transport
        Background         = $background
        ClientInfo         = $clientInfoObject
        ClientCapabilities = $capabilityObject
        ProtocolVersion    = $ProtocolVersion
        Era                = 'Modern'
        ServerInfo         = $null
        Tools              = $null
        ToolHeaders        = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        NextId             = 1
        RequestTimeoutMs   = $RequestTimeoutSeconds * 1000
        LogLevel           = if ($PSBoundParameters.ContainsKey('LogLevel')) { $LogLevel } else { $null }
        OnLog              = $OnLog
        Log                = [System.Collections.Generic.List[object]]::new()
        Notifications      = [System.Collections.Generic.Queue[object]]::new()
        StandardErrorPath  = $stderrPath
        Closed             = $false
    }

    try {
        $discover = $null
        try {
            $discover = Invoke-McpClientRequest -Session $session -Method 'server/discover' -TimeoutMs ($ConnectTimeoutSeconds * 1000)
        } catch [McpProtocolException] {
            $exception = $_.Exception
            if ($exception.Code -eq $script:McpErrorCode.UnsupportedProtocolVersion -and $exception.Data -is [System.Collections.IDictionary] -and $exception.Data.Contains('supported')) {
                $mutual = @($exception.Data['supported'] | Where-Object { $_ -in $script:McpModernProtocolVersions })
                if ($mutual.Count -eq 0) {
                    throw [System.InvalidOperationException]::new("The server supports protocol version(s) $(@($exception.Data['supported']) -join ', '), none of which this client speaks ($($script:McpModernProtocolVersions -join ', ')).")
                }
                $session.ProtocolVersion = $mutual[0]
                $discover = Invoke-McpClientRequest -Session $session -Method 'server/discover' -TimeoutMs ($ConnectTimeoutSeconds * 1000)
            } else {
                throw [System.InvalidOperationException]::new("server/discover failed with $($exception.Code): $($exception.Message). Servers that only implement the initialize handshake of revisions before 2026-07-28 are not supported by this milestone.")
            }
        } catch [System.Net.Http.HttpRequestException] {
            throw [System.InvalidOperationException]::new("server/discover at $Url failed: $($_.Exception.Message) A response without a JSON-RPC error body indicates a server of a revision before 2026-07-28; its initialize handshake is not supported by this milestone.", $_.Exception)
        }
        if ($discover -isnot [System.Collections.IDictionary] -or -not $discover.Contains('supportedVersions')) {
            throw [System.InvalidOperationException]::new('The server/discover result is not a DiscoverResult.')
        }
        $supported = @($discover['supportedVersions'])
        if ($session.ProtocolVersion -notin $supported) {
            $mutual = @($supported | Where-Object { $_ -in $script:McpModernProtocolVersions })
            if ($mutual.Count -eq 0) {
                throw [System.InvalidOperationException]::new("The server supports protocol version(s) $($supported -join ', '), none of which this client speaks.")
            }
            $session.ProtocolVersion = $mutual[0]
        }
        $session.ServerInfo = ConvertTo-McpServerInfoObject -DiscoverResult $discover -ProtocolVersion $session.ProtocolVersion
        $session.Name = $session.ServerInfo.Name
    } catch {
        try { Disconnect-McpServer -Session $session -Confirm:$false } catch { Write-Debug 'Cleanup after a failed connection failed.' }
        throw
    }

    if ($SetDefault -or $null -eq $script:McpDefaultSession -or $script:McpDefaultSession.Closed) {
        $script:McpDefaultSession = $session
    }
    $session
}
