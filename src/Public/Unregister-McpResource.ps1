function Unregister-McpResource {
    <#
    .SYNOPSIS
        Removes a resource or resource template from a server; while the server runs, listening clients are told that the resource list changed.
    .PARAMETER Uri
        The URI of a resource.
    .PARAMETER UriTemplate
        The URI template of a resource template.
    .PARAMETER Server
        The server; defaults to the server set with New-McpServer -SetDefault.
    .EXAMPLE
        Unregister-McpResource -Uri 'config://app'
    #>
    [CmdletBinding(DefaultParameterSetName = 'Uri', SupportsShouldProcess)]
    param(
        [Parameter(ParameterSetName = 'Uri', Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Uri,

        [Parameter(ParameterSetName = 'UriTemplate', Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]] $UriTemplate,

        [object] $Server
    )

    process {
        $target = Resolve-McpServer -Server $Server
        $registry = if ($PSCmdlet.ParameterSetName -eq 'Uri') { $target.Resources } else { $target.ResourceTemplates }
        foreach ($item in $(if ($PSCmdlet.ParameterSetName -eq 'Uri') { $Uri } else { $UriTemplate })) {
            if (-not $registry.Contains($item)) { throw [System.ArgumentException]::new("No resource or template '$item' is registered.") }
            if ($PSCmdlet.ShouldProcess($item, 'Unregister MCP resource')) {
                $registry.Remove($item)
                $null = Send-McpServerNotification -Method 'notifications/resources/list_changed' -Server $target
            }
        }
    }
}
