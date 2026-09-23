function Get-McpCompletion {
    <#
    .SYNOPSIS
        Asks the server for completions of a prompt argument or a resource template variable (completion/complete).
    .DESCRIPTION
        The server returns at most 100 values; Total and HasMore tell whether it knows more. Servers without
        the completions capability answer with a method-not-found error, which is thrown.
    .PARAMETER PromptName
        The prompt whose argument is completed.
    .PARAMETER ResourceTemplate
        The URI template of the resource template whose variable is completed.
    .PARAMETER Argument
        The argument or variable name.
    .PARAMETER Value
        The text typed so far.
    .PARAMETER ContextArguments
        Values of other arguments that are already known (context.arguments).
    .PARAMETER Session
        The session; defaults to the default session.
    .EXAMPLE
        (Get-McpCompletion -PromptName weather-report -Argument city -Value 'Ber').Values
    .OUTPUTS
        Mcp.Completion
    #>
    [CmdletBinding(DefaultParameterSetName = 'Prompt')]
    [OutputType('Mcp.Completion')]
    param(
        [Parameter(ParameterSetName = 'Prompt', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $PromptName,

        [Parameter(ParameterSetName = 'ResourceTemplate', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ResourceTemplate,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Argument,

        [AllowEmptyString()]
        [string] $Value = '',

        [System.Collections.IDictionary] $ContextArguments,

        [object] $Session
    )

    $target = Resolve-McpSession -Session $Session
    $reference = if ($PSCmdlet.ParameterSetName -eq 'Prompt') {
        [ordered]@{ type = 'ref/prompt'; name = $PromptName }
    } else {
        [ordered]@{ type = 'ref/resource'; uri = $ResourceTemplate }
    }
    $params = [ordered]@{
        ref      = $reference
        argument = [ordered]@{ name = $Argument; value = $Value }
    }
    if ($null -ne $ContextArguments -and $ContextArguments.Count -gt 0) {
        $known = [ordered]@{}
        foreach ($key in $ContextArguments.Keys) { $known[[string] $key] = [string] $ContextArguments[$key] }
        $params['context'] = [ordered]@{ arguments = $known }
    }
    $result = Invoke-McpClientRequest -Session $target -Method 'completion/complete' -Params $params
    if ($result -isnot [System.Collections.IDictionary] -or -not $result.Contains('completion')) {
        throw [System.InvalidOperationException]::new('The completion/complete result has no completion member.')
    }
    ConvertTo-McpCompletionObject -Result $result
}
