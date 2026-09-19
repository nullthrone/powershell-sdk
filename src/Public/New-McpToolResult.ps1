function New-McpToolResult {
    <#
    .SYNOPSIS
        Creates a complete tool result (content blocks, structured content, error flag) to return from a handler.
    .DESCRIPTION
        Use it when a handler needs control over the CallToolResult: several content blocks, structured content
        that differs from the text, or an error result (isError) that the model should see and recover from.
        Plain output (strings, objects, New-McpContent blocks) does not need it.
    .PARAMETER Content
        Content blocks (New-McpContent) or strings (text blocks).
    .PARAMETER Text
        A single text block; shorthand for -Content.
    .PARAMETER StructuredContent
        A JSON-serialisable object placed in structuredContent (and, when -Content is empty, also as JSON text).
    .PARAMETER IsError
        Mark the result as a tool execution error.
    .PARAMETER Meta
        Additional _meta members of the result.
    .EXAMPLE
        New-McpToolResult -IsError -Text 'The location is unknown.'
    .OUTPUTS
        Mcp.ToolResult
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    [OutputType('Mcp.ToolResult')]
    param(
        [object[]] $Content,

        [AllowEmptyString()]
        [string] $Text,

        [object] $StructuredContent,

        [switch] $IsError,

        [hashtable] $Meta
    )

    $blocks = [System.Collections.Generic.List[object]]::new()
    if ($PSBoundParameters.ContainsKey('Text')) { $blocks.Add((ConvertTo-McpTextBlock -Text $Text)) }
    foreach ($item in @($Content)) {
        if ($null -eq $item) { continue }
        if (Test-McpContentObject -Value $item) { $blocks.Add($item) }
        elseif ($item -is [string]) { $blocks.Add((ConvertTo-McpTextBlock -Text $item)) }
        else { throw [System.ArgumentException]::new('-Content accepts content blocks (New-McpContent) and strings.') }
    }
    if ($PSBoundParameters.ContainsKey('StructuredContent') -and $blocks.Count -eq 0) {
        $blocks.Add((ConvertTo-McpTextBlock -Text (ConvertTo-McpJson -InputObject $StructuredContent)))
    }
    $result = [ordered]@{ content = $blocks.ToArray() }
    if ($PSBoundParameters.ContainsKey('StructuredContent')) { $result['structuredContent'] = $StructuredContent }
    if ($IsError) { $result['isError'] = $true }
    if ($Meta -and $Meta.Count -gt 0) { $result['_meta'] = $Meta }
    $object = [pscustomobject] $result
    $object.PSObject.TypeNames.Insert(0, 'Mcp.ToolResult')
    $object
}
