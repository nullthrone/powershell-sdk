function Unregister-McpPrompt {
    <#
    .SYNOPSIS
        Removes a prompt from a server; while the server runs, listening clients are told that the prompt list changed.
    .PARAMETER Name
        The prompt name.
    .PARAMETER Server
        The server; defaults to the server set with New-McpServer -SetDefault.
    .EXAMPLE
        Unregister-McpPrompt -Name 'summarize'
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
            if (-not $target.Prompts.Contains($item)) { throw [System.ArgumentException]::new("No prompt named '$item' is registered.") }
            if ($PSCmdlet.ShouldProcess($item, 'Unregister MCP prompt')) {
                $target.Prompts.Remove($item)
                $null = Send-McpServerNotification -Method 'notifications/prompts/list_changed' -Server $target
            }
        }
    }
}
