function Get-McpServerInfo {
    <#
    .SYNOPSIS
        The server's implementation info, capabilities, instructions and supported versions (from server/discover).
    .DESCRIPTION
        The result is cached in the session for the ttlMs the server sent with it; afterwards, or with
        -Refresh, server/discover is queried again.
    .PARAMETER Session
        The session; defaults to the default session.
    .PARAMETER Refresh
        Query server/discover again instead of returning a cached result.
    .EXAMPLE
        Get-McpServerInfo | Format-List
    .OUTPUTS
        Mcp.ServerInfo
    #>
    [CmdletBinding()]
    [OutputType('Mcp.ServerInfo')]
    param(
        [object] $Session,

        [switch] $Refresh
    )

    $target = Resolve-McpSession -Session $Session
    if (-not $Refresh) {
        $entry = Get-McpClientCacheEntry -Session $target -Key 'server/discover'
        if ($null -ne $entry) { return $entry.Value }
    }
    $discover = Invoke-McpClientRequest -Session $target -Method 'server/discover'
    $target.ServerInfo = ConvertTo-McpServerInfoObject -DiscoverResult $discover -ProtocolVersion $target.ProtocolVersion
    $target.Name = $target.ServerInfo.Name
    Set-McpClientCacheEntry -Session $target -Key 'server/discover' -Value $target.ServerInfo -CacheHint (Get-McpResultCacheHint -Result $discover)
    $target.ServerInfo
}
