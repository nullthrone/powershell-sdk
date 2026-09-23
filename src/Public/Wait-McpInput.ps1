function Wait-McpInput {
    <#
    .SYNOPSIS
        Asks the client for all input requests deferred with -Defer in one round, when any answer is missing.
    .DESCRIPTION
        Request-McpElicitation, Request-McpSampling and Request-McpRoot with -Defer record a missing input
        request instead of throwing. Wait-McpInput then throws once for all of them, so the client receives
        them together in one InputRequiredResult; when every answer is there, it returns without output and
        the deferred commands, called again on the retry, return their answers.
    .PARAMETER Context
        The request context (the handler's Context parameter).
    .EXAMPLE
        $name = Request-McpElicitation -Context $Context -Key 'name' -Message 'Name?' -Schema @{ name = @{ type = 'string' } } -Defer
        $roots = Request-McpRoot -Context $Context -Key 'roots' -Defer
        Wait-McpInput -Context $Context
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Context
    )

    Test-McpContextInput -Context $Context
    if ($Context.PendingInput.Count -gt 0) {
        throw [McpInputRequiredException]::new($Context.PendingInput)
    }
}
