function Get-McpTool {
    <#
    .SYNOPSIS
        Lists the server's tools (tools/list, following all pages) or gets one tool by name.
    .DESCRIPTION
        The list is cached in the session for the ttlMs the server sent with it (the shortest of all pages);
        afterwards, or with -Refresh, tools/list is queried again. Over Streamable HTTP a tool whose
        x-mcp-header annotations are invalid is excluded from the list with a warning, as the specification
        requires; the valid annotations tell Invoke-McpTool which arguments to mirror into Mcp-Param-* headers.
    .PARAMETER Name
        The name of a tool (exact match); an unknown name is an error.
    .PARAMETER Session
        The session; defaults to the default session.
    .PARAMETER Refresh
        Query tools/list again instead of using a cached list.
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
    $entry = if ($Refresh) { $null } else { Get-McpClientCacheEntry -Session $target -Key 'tools/list' }
    if ($null -ne $entry) {
        $tools = $entry.Value
    } else {
        $list = Invoke-McpClientListRequest -Session $target -Method 'tools/list' -ItemKey 'tools'
        $converted = [System.Collections.Generic.List[object]]::new()
        $headers = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        foreach ($tool in $list.Items) {
            if ($target.Kind -eq 'Http' -and $target.Era -ne 'Legacy') {
                $toolName = if ($tool.Contains('name')) { [string] $tool['name'] } else { '(unnamed)' }
                $headerParameters = @()
                try {
                    $headerParameters = @(Get-McpToolHeaderParameter -InputSchema $(if ($tool.Contains('inputSchema')) { $tool['inputSchema'] } else { $null }))
                } catch [System.ArgumentException] {
                    Write-Warning "Excluding tool '$toolName' from the list: $($_.Exception.Message)"
                    continue
                }
                $headers[$toolName] = $headerParameters
            }
            $converted.Add((ConvertTo-McpToolObject -Tool $tool))
        }
        $tools = $converted.ToArray()
        $target.Tools = $tools
        $target.ToolHeaders = $headers
        Set-McpClientCacheEntry -Session $target -Key 'tools/list' -Value $tools -CacheHint $list.CacheHint
    }
    if ($Name) {
        $tool = $tools | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if (-not $tool) {
            throw [System.ArgumentException]::new("The server has no tool named '$Name'.")
        }
        return $tool
    }
    $tools
}
