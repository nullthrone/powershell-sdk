function New-McpPromptMessage {
    <#
    .SYNOPSIS
        Creates a prompt message (role and one content block) to return from a prompt handler.
    .DESCRIPTION
        Prompt handlers return messages; plain strings and content blocks already become user messages. Use
        this command for assistant messages or to set the content block explicitly.
    .PARAMETER Role
        The speaker: user (default) or assistant.
    .PARAMETER Text
        The text of a text content block.
    .PARAMETER Content
        A content block from New-McpContent (text, image, audio, resource link or embedded resource).
    .EXAMPLE
        New-McpPromptMessage -Role assistant -Text 'Which city do you mean?'
    .EXAMPLE
        New-McpPromptMessage -Content (New-McpContent -Image $bytes -MimeType image/png)
    .OUTPUTS
        Mcp.PromptMessage
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    [OutputType('Mcp.PromptMessage')]
    param(
        [ValidateSet('user', 'assistant')]
        [string] $Role = 'user',

        [Parameter(ParameterSetName = 'Text', Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(ParameterSetName = 'Content', Mandatory)]
        [ValidateNotNull()]
        [object] $Content
    )

    if ($PSCmdlet.ParameterSetName -eq 'Content' -and -not (Test-McpContentObject -Value $Content)) {
        throw [System.ArgumentException]::new('-Content must be a content block (New-McpContent).')
    }
    $message = [pscustomobject]@{
        role    = $Role.ToLowerInvariant()
        content = if ($PSCmdlet.ParameterSetName -eq 'Text') { New-McpContent -Text $Text } else { $Content }
    }
    $message.PSObject.TypeNames.Insert(0, 'Mcp.PromptMessage')
    $message
}
