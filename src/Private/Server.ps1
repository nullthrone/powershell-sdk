# The server object (a PSCustomObject with PSTypeName Mcp.Server) and the results that describe the server:
# server/discover and the serverInfo metadata added to every result.

$script:McpLatestProtocolVersion = '2026-07-28'
$script:McpModernProtocolVersions = @('2026-07-28')
$script:McpDefaultServer = $null

function Test-McpServerObject {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Server
    )

    $null -ne $Server -and $Server.PSObject.TypeNames -contains 'Mcp.Server'
}

function Resolve-McpServer {
    <#
    .SYNOPSIS
        The server passed to a command, or the default server set with New-McpServer -SetDefault.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Server
    )

    if ($null -ne $Server) {
        if (-not (Test-McpServerObject -Server $Server)) {
            throw [System.ArgumentException]::new('The -Server argument is not a server created by New-McpServer.')
        }
        return $Server
    }
    if ($null -eq $script:McpDefaultServer) {
        throw [System.InvalidOperationException]::new('No server given and no default server set. Create one with New-McpServer -SetDefault or pass -Server.')
    }
    $script:McpDefaultServer
}

function Get-McpServerInfoObject {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server
    )

    $info = [ordered]@{
        name    = $Server.Name
        version = $Server.Version
    }
    if ($Server.Title) { $info['title'] = $Server.Title }
    if ($Server.Description) { $info['description'] = $Server.Description }
    if ($Server.WebsiteUrl) { $info['websiteUrl'] = $Server.WebsiteUrl }
    if ($Server.Icons -and @($Server.Icons).Count -gt 0) { $info['icons'] = @($Server.Icons) }
    $info
}

function Get-McpServerCapability {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server
    )

    $capabilities = [ordered]@{
        tools = [ordered]@{ listChanged = [bool] $Server.Options.ListChanged }
    }
    $capabilities
}

function Add-McpResultMeta {
    <#
    .SYNOPSIS
        Adds _meta with the server info to a result (unless the server is configured without server info).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary] $Result,

        [Parameter(Mandatory)]
        [pscustomobject] $Server
    )

    if ($Server.Options.IncludeServerInfo) {
        $meta = if ($Result.Contains('_meta') -and $Result['_meta'] -is [System.Collections.IDictionary]) { $Result['_meta'] } else { [ordered]@{} }
        $meta[$script:McpMetaKey.ServerInfo] = Get-McpServerInfoObject -Server $Server
        $Result['_meta'] = $meta
    }
    $Result
}

function Get-McpDiscoverResult {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server
    )

    $result = [ordered]@{
        resultType        = 'complete'
        supportedVersions = @($Server.SupportedVersions)
        capabilities      = Get-McpServerCapability -Server $Server
    }
    if ($Server.Instructions) { $result['instructions'] = $Server.Instructions }
    $result['ttlMs'] = [long] $Server.Options.DefaultTtlMs
    $result['cacheScope'] = $Server.Options.DefaultCacheScope
    Add-McpResultMeta -Result $result -Server $Server
}
