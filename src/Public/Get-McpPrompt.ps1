function Get-McpPrompt {
    <#
    .SYNOPSIS
        Lists the server's prompts (prompts/list).
    .DESCRIPTION
        All pages are followed. The list is cached in the session for the ttlMs the server sent with it (the
        shortest of all pages); afterwards, or with -Refresh, the server is queried again. Render a prompt with
        Invoke-McpPrompt.
    .PARAMETER Name
        Only prompts whose name matches this wildcard pattern.
    .PARAMETER Session
        The session; defaults to the default session.
    .PARAMETER Refresh
        Query the server again instead of using a cached list.
    .EXAMPLE
        Get-McpPrompt | Select-Object Name, Description
    .OUTPUTS
        Mcp.Prompt
    #>
    [CmdletBinding()]
    [OutputType('Mcp.Prompt')]
    param(
        [Parameter(Position = 0)]
        [SupportsWildcards()]
        [string] $Name,

        [object] $Session,

        [switch] $Refresh
    )

    $target = Resolve-McpSession -Session $Session
    $entry = if ($Refresh) { $null } else { Get-McpClientCacheEntry -Session $target -Key 'prompts/list' }
    if ($null -ne $entry) {
        $prompts = $entry.Value
    } else {
        $list = Invoke-McpClientListRequest -Session $target -Method 'prompts/list' -ItemKey 'prompts'
        $prompts = @($list.Items | ForEach-Object { ConvertTo-McpPromptObject -Prompt $_ })
        Set-McpClientCacheEntry -Session $target -Key 'prompts/list' -Value $prompts -CacheHint $list.CacheHint
    }
    if ($Name) { $prompts = @($prompts | Where-Object { $_.Name -like $Name }) }
    $prompts
}
