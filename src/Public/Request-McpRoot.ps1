function Request-McpRoot {
    <#
    .SYNOPSIS
        Asks the client for its roots (roots/list as an input request): the directories or files the server may work in.
    .DESCRIPTION
        Multi-round-trip request (MRTR), deprecated in revision 2026-07-28 but supported: the first call throws
        and the server answers with an InputRequiredResult; when the client retries with its roots, the handler
        runs again and this command returns them (Mcp.Root: Uri, Name). The client must have declared the roots
        capability; otherwise -32021.
    .PARAMETER Context
        The request context (the handler's Context parameter).
    .PARAMETER Key
        The identifier of this input request within the handler.
    .PARAMETER Defer
        Record the request without throwing when the answer is missing (see Wait-McpInput).
    .EXAMPLE
        Request-McpRoot -Context $Context -Key 'roots' | Select-Object -ExpandProperty Uri
    .OUTPUTS
        Mcp.Root
    #>
    [CmdletBinding()]
    [OutputType('Mcp.Root')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Key,

        [switch] $Defer
    )

    $request = [ordered]@{ method = 'roots/list'; params = [ordered]@{} }
    $response = Invoke-McpInputRequest -Context $Context -Key $Key -Request $request -Capability 'roots' -Defer:$Defer
    if ($null -eq $response) { return }
    foreach ($root in @($response['roots'])) {
        [pscustomobject]@{
            PSTypeName = 'Mcp.Root'
            Uri        = [string] $root['uri']
            Name       = if ($root.Contains('name')) { [string] $root['name'] } else { $null }
            Meta       = if ($root.Contains('_meta')) { $root['_meta'] } else { $null }
        }
    }
}
