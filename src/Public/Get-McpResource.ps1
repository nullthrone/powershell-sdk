function Get-McpResource {
    <#
    .SYNOPSIS
        Lists the server's resources (resources/list) or resource templates (resources/templates/list).
    .DESCRIPTION
        All pages are followed. The list is cached in the session for the ttlMs the server sent with it (the
        shortest of all pages); afterwards, or with -Refresh, the server is queried again.
    .PARAMETER Name
        Only resources or templates whose name matches this wildcard pattern.
    .PARAMETER Template
        List the resource templates instead of the resources.
    .PARAMETER Session
        The session; defaults to the default session.
    .PARAMETER Refresh
        Query the server again instead of using a cached list.
    .EXAMPLE
        Get-McpResource | Read-McpResource
    .EXAMPLE
        Get-McpResource -Template | Select-Object Name, UriTemplate
    .OUTPUTS
        Mcp.Resource, Mcp.ResourceTemplate
    #>
    [CmdletBinding()]
    [OutputType('Mcp.Resource', 'Mcp.ResourceTemplate')]
    param(
        [Parameter(Position = 0)]
        [SupportsWildcards()]
        [string] $Name,

        [switch] $Template,

        [object] $Session,

        [switch] $Refresh
    )

    $target = Resolve-McpSession -Session $Session
    $method = if ($Template) { 'resources/templates/list' } else { 'resources/list' }
    $entry = if ($Refresh) { $null } else { Get-McpClientCacheEntry -Session $target -Key $method }
    if ($null -ne $entry) {
        $items = $entry.Value
    } else {
        $list = Invoke-McpClientListRequest -Session $target -Method $method -ItemKey $(if ($Template) { 'resourceTemplates' } else { 'resources' })
        $items = if ($Template) {
            @($list.Items | ForEach-Object { ConvertTo-McpResourceTemplateObject -Template $_ })
        } else {
            @($list.Items | ForEach-Object { ConvertTo-McpResourceObject -Resource $_ })
        }
        Set-McpClientCacheEntry -Session $target -Key $method -Value $items -CacheHint $list.CacheHint
    }
    if ($Name) { $items = @($items | Where-Object { $_.Name -like $Name }) }
    $items
}
