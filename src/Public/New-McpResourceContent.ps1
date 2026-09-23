function New-McpResourceContent {
    <#
    .SYNOPSIS
        Creates resource contents (text or binary) to return from a resource handler.
    .DESCRIPTION
        Resource handlers may return strings, byte arrays or objects; use this command to return several
        contents, contents of another URI (for example the files of a directory), or to set the MIME type and
        _meta of a content explicitly.
    .PARAMETER Text
        The text contents.
    .PARAMETER Blob
        The binary contents as byte[] or base64 string.
    .PARAMETER Uri
        The URI of the contents; defaults to the requested URI.
    .PARAMETER MimeType
        The MIME type of the contents.
    .PARAMETER Meta
        Additional _meta members of the contents.
    .EXAMPLE
        New-McpResourceContent -Text '{ "ok": true }' -MimeType application/json
    .OUTPUTS
        Mcp.ResourceContents
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    [OutputType('Mcp.ResourceContents')]
    param(
        [Parameter(ParameterSetName = 'Text', Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(ParameterSetName = 'Blob', Mandatory)]
        [ValidateNotNull()]
        [object] $Blob,

        [string] $Uri,

        [string] $MimeType,

        [object] $Meta
    )

    if ($Uri -and -not (Test-McpResourceUri -Uri $Uri)) {
        throw [System.ArgumentException]::new("'$Uri' is not an absolute URI.")
    }
    $content = [ordered]@{}
    if ($Uri) { $content['uri'] = $Uri }
    if ($MimeType) { $content['mimeType'] = $MimeType }
    if ($PSCmdlet.ParameterSetName -eq 'Text') { $content['text'] = $Text } else { $content['blob'] = ConvertTo-McpBase64 -Data $Blob }
    $metaObject = ConvertTo-McpMetaObject -Meta $Meta
    if ($null -ne $metaObject) { $content['_meta'] = $metaObject }
    $object = [pscustomobject] $content
    $object.PSObject.TypeNames.Insert(0, 'Mcp.ResourceContents')
    $object
}
