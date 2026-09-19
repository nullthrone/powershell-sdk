function Get-McpServerInfo {
    <#
    .SYNOPSIS
        The server's implementation info, capabilities, instructions and supported versions (from server/discover).
    .PARAMETER Session
        The session; defaults to the default session.
    .PARAMETER Refresh
        Query server/discover again instead of returning the cached result.
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
    if ($Refresh -or $null -eq $target.ServerInfo) {
        $discover = Invoke-McpClientRequest -Session $target -Method 'server/discover'
        $target.ServerInfo = ConvertTo-McpServerInfoObject -DiscoverResult $discover -ProtocolVersion $target.ProtocolVersion
        $target.Name = $target.ServerInfo.Name
    }
    $target.ServerInfo
}
