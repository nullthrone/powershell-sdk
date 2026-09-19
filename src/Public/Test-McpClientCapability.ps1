function Test-McpClientCapability {
    <#
    .SYNOPSIS
        True when the client of the current request declared a capability, given as a dotted path.
    .DESCRIPTION
        Capabilities are declared per request in _meta. Paths use '.' between levels, for example
        'elicitation.form', 'sampling' or 'extensions.io.modelcontextprotocol/tasks'.
    .PARAMETER Context
        The request context (the handler's Context parameter).
    .PARAMETER Path
        The dotted capability path.
    .EXAMPLE
        if (Test-McpClientCapability -Context $Context -Path 'elicitation.form') { ... }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $capabilities = if ($Context.PSObject.Properties['ClientCapabilities']) { $Context.ClientCapabilities } else { $null }
    Test-McpCapabilityPath -Capabilities $capabilities -Path $Path
}
