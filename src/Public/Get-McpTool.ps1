function Get-McpTool {
    <#
    .SYNOPSIS
        Lists the server's tools (tools/list, following all pages) or gets one tool by name.
    .DESCRIPTION
        The list is cached in the session; -Refresh queries the server again.
    .PARAMETER Name
        The name of a tool (exact match); an unknown name is an error.
    .PARAMETER Session
        The session; defaults to the default session.
    .PARAMETER Refresh
        Query tools/list again instead of using the cached list.
    .EXAMPLE
        Get-McpTool | Select-Object Name, Description
    .OUTPUTS
        Mcp.Tool
    #>
    [CmdletBinding()]
    [OutputType('Mcp.Tool')]
    param(
        [Parameter(Position = 0)]
        [string] $Name,

        [object] $Session,

        [switch] $Refresh
    )

    $target = Resolve-McpSession -Session $Session
    if ($Refresh -or $null -eq $target.Tools) {
        $tools = [System.Collections.Generic.List[object]]::new()
        $cursor = $null
        $pages = 0
        do {
            $params = [ordered]@{}
            if ($null -ne $cursor) { $params['cursor'] = $cursor }
            $result = Invoke-McpClientRequest -Session $target -Method 'tools/list' -Params $params
            if ($result -isnot [System.Collections.IDictionary] -or -not $result.Contains('tools')) {
                throw [System.InvalidOperationException]::new('The tools/list result has no tools member.')
            }
            foreach ($tool in @($result['tools'])) {
                if ($tool -is [System.Collections.IDictionary]) { $tools.Add((ConvertTo-McpToolObject -Tool $tool)) }
            }
            $cursor = if ($result.Contains('nextCursor') -and $null -ne $result['nextCursor']) { [string] $result['nextCursor'] } else { $null }
            $pages++
            if ($pages -gt 10000) { throw [System.InvalidOperationException]::new('tools/list paged more than 10000 times.') }
        } while ($null -ne $cursor)
        $target.Tools = $tools.ToArray()
    }
    if ($Name) {
        $tool = $target.Tools | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if (-not $tool) {
            throw [System.ArgumentException]::new("The server has no tool named '$Name'.")
        }
        return $tool
    }
    $target.Tools
}
