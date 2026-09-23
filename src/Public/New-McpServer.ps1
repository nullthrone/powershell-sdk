function New-McpServer {
    <#
    .SYNOPSIS
        Creates an MCP server object to register tools on and to start with Start-McpServer.
    .DESCRIPTION
        The server object carries the implementation info (name, version, title, description, website URL,
        icons), the instructions for clients, the supported protocol versions and the runtime options. It is
        a plain object (PSTypeName Mcp.Server); tools, resources and prompts are registered on it with
        Register-McpTool, Register-McpResource and Register-McpPrompt. With -SetDefault the object becomes the
        default for the other server commands of this session.
    .PARAMETER Name
        The implementation name reported as serverInfo.name.
    .PARAMETER Version
        The implementation version reported as serverInfo.version.
    .PARAMETER Title
        A human-readable title (serverInfo.title).
    .PARAMETER Description
        A description of the server (serverInfo.description).
    .PARAMETER WebsiteUrl
        A website with more information (serverInfo.websiteUrl).
    .PARAMETER Icons
        Icon objects (hashtables with src, and optionally mimeType, sizes, theme) reported as serverInfo.icons.
    .PARAMETER Instructions
        Natural-language guidance for clients and their models, returned by server/discover.
    .PARAMETER SupportedVersions
        The protocol revisions the server speaks. This milestone supports 2026-07-28 only.
    .PARAMETER MaxConcurrency
        The maximum number of handlers running at the same time (the size of the worker runspace pool).
    .PARAMETER RequestTimeoutSeconds
        Seconds after which a running handler is stopped and the request answered with an error; 0 disables the timeout.
    .PARAMETER DefaultTtlMs
        The ttlMs caching hint sent with server/discover, the list results and resources/read (unless the
        resource sets its own with Register-McpResource -TtlMs).
    .PARAMETER DefaultCacheScope
        The cacheScope caching hint (public or private) sent with the same results.
    .PARAMETER PageSize
        The number of items per page of tools/list, resources/list, resources/templates/list and prompts/list.
    .PARAMETER LogLevel
        The minimum level of diagnostics written to stderr (default: warning).
    .PARAMETER NoServerInfo
        Do not add io.modelcontextprotocol/serverInfo to results.
    .PARAMETER SetDefault
        Make the new server the default for Register-McpTool, Start-McpServer and the other server commands.
    .EXAMPLE
        $server = New-McpServer -Name 'weather' -Version '1.0.0' -Instructions 'Weather lookups.' -SetDefault
    .OUTPUTS
        Mcp.Server
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    [OutputType('Mcp.Server')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Version,

        [string] $Title,

        [string] $Description,

        [string] $WebsiteUrl,

        [object[]] $Icons,

        [string] $Instructions,

        [ValidateNotNullOrEmpty()]
        [string[]] $SupportedVersions = @('2026-07-28'),

        [ValidateRange(1, 64)]
        [int] $MaxConcurrency = [System.Math]::Max(1, [System.Environment]::ProcessorCount),

        [ValidateRange(0, 86400)]
        [int] $RequestTimeoutSeconds = 0,

        [ValidateRange(0, 2147483647)]
        [int] $DefaultTtlMs = 0,

        [ValidateSet('public', 'private')]
        [string] $DefaultCacheScope = 'public',

        [ValidateRange(1, 1000)]
        [int] $PageSize = 100,

        [McpLoggingLevel] $LogLevel = [McpLoggingLevel]::Warning,

        [switch] $NoServerInfo,

        [switch] $SetDefault
    )

    foreach ($candidate in $SupportedVersions) {
        if ($candidate -notin $script:McpModernProtocolVersions) {
            throw [System.ArgumentException]::new("Protocol version '$candidate' is not supported by this milestone; supported: $($script:McpModernProtocolVersions -join ', ').")
        }
    }

    $server = [pscustomobject]@{
        PSTypeName        = 'Mcp.Server'
        Name              = $Name
        Version           = $Version
        Title             = $Title
        Description       = $Description
        WebsiteUrl        = $WebsiteUrl
        Icons             = ConvertTo-McpIconList -Icons $Icons
        Instructions      = $Instructions
        SupportedVersions = [string[]] $SupportedVersions
        Tools             = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        Resources         = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        ResourceTemplates = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        Prompts           = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        Options           = @{
            MaxConcurrency        = $MaxConcurrency
            RequestTimeoutSeconds = $RequestTimeoutSeconds
            DefaultTtlMs          = $DefaultTtlMs
            DefaultCacheScope     = $DefaultCacheScope
            PageSize              = $PageSize
            LogLevel              = $LogLevel
            IncludeServerInfo     = -not $NoServerInfo
            # listChanged (tools, prompts, resources) is advertised once subscriptions/listen can deliver the
            # notifications (milestone M4).
            ListChanged           = $false
        }
        State             = @{
            Started       = $false
            StopRequested = $false
        }
    }
    if ($SetDefault) {
        $script:McpDefaultServer = $server
    }
    $server
}
