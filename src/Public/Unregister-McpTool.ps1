function Unregister-McpTool {
    <#
    .SYNOPSIS
        Removes a tool from a server; while the server runs, listening clients are told that the tool list changed.
    .PARAMETER Name
        The tool name.
    .PARAMETER Server
        The server; defaults to the server set with New-McpServer -SetDefault.
    .EXAMPLE
        Unregister-McpTool -Name 'echo'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name,

        [object] $Server
    )

    process {
        $target = Resolve-McpServer -Server $Server
        foreach ($item in $Name) {
            if (-not $target.Tools.Contains($item)) { throw [System.ArgumentException]::new("No tool named '$item' is registered.") }
            if ($PSCmdlet.ShouldProcess($item, 'Unregister MCP tool')) {
                $target.Tools.Remove($item)
                $null = Send-McpServerNotification -Method 'notifications/tools/list_changed' -Server $target
            }
        }
    }
}
