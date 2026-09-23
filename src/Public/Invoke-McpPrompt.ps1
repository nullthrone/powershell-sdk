function Invoke-McpPrompt {
    <#
    .SYNOPSIS
        Renders a prompt (prompts/get) with arguments and returns its messages.
    .DESCRIPTION
        Argument values are sent as strings (other values are converted with the invariant culture). The result
        is an Mcp.PromptResult with the prompt's Description, its Messages (Role and an Mcp.Content block) and
        the Text of all text blocks. Protocol errors (unknown prompt, missing required arguments) are thrown.
    .PARAMETER Name
        The prompt name.
    .PARAMETER Arguments
        The argument values.
    .PARAMETER Session
        The session; defaults to the default session.
    .PARAMETER TimeoutSeconds
        The timeout for this request; defaults to the session's request timeout.
    .PARAMETER LogLevel
        Ask for notifications/message at this level and above (see the session's Log).
    .EXAMPLE
        (Invoke-McpPrompt -Name summarize -Arguments @{ Text = $report }).Messages
    .OUTPUTS
        Mcp.PromptResult
    #>
    [CmdletBinding()]
    [OutputType('Mcp.PromptResult')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Position = 1)]
        [System.Collections.IDictionary] $Arguments,

        [object] $Session,

        [ValidateRange(0, 86400)]
        [int] $TimeoutSeconds = 0,

        [McpLoggingLevel] $LogLevel
    )

    $target = Resolve-McpSession -Session $Session
    $params = [ordered]@{ name = $Name }
    if ($null -ne $Arguments -and $Arguments.Count -gt 0) {
        $values = [ordered]@{}
        foreach ($key in $Arguments.Keys) {
            $value = $Arguments[$key]
            $values[[string] $key] = if ($null -eq $value) { '' }
            elseif ($value -is [bool] -or $value -is [switch]) { ([bool] $value).ToString().ToLowerInvariant() }
            else { [System.Management.Automation.LanguagePrimitives]::ConvertTo($value, [string], [cultureinfo]::InvariantCulture) }
        }
        $params['arguments'] = $values
    }
    $level = if ($PSBoundParameters.ContainsKey('LogLevel')) { $LogLevel } else { $target.LogLevel }
    $result = (Invoke-McpClientRequestWithInput -Session $target -Method 'prompts/get' -Params $params -LogLevel $level -TimeoutMs ($TimeoutSeconds * 1000)).Result
    if ($result -isnot [System.Collections.IDictionary] -or -not $result.Contains('messages')) {
        throw [System.InvalidOperationException]::new('The prompts/get result has no messages member.')
    }
    ConvertTo-McpPromptResultObject -Result $result -Name $Name
}
