function New-McpContent {
    <#
    .SYNOPSIS
        Creates a content block (text, image, audio, resource link or embedded resource) for tool results.
    .DESCRIPTION
        Content blocks are the items of CallToolResult.content. Return them from a tool handler, or pass them
        to New-McpToolResult. Binary data may be given as byte[] or as a base64 string.
    .PARAMETER Text
        The text of a text block.
    .PARAMETER Image
        Image data (byte[] or base64 string) of an image block; -MimeType is required.
    .PARAMETER Audio
        Audio data (byte[] or base64 string) of an audio block; -MimeType is required.
    .PARAMETER ResourceLink
        The URI of a resource link block; -Name is required.
    .PARAMETER EmbeddedResource
        The URI of an embedded resource block; give its contents with -ResourceText or -ResourceBlob.
    .PARAMETER Name
        The resource name of a resource link.
    .PARAMETER Title
        The title of a resource link.
    .PARAMETER Description
        The description of a resource link.
    .PARAMETER MimeType
        The MIME type of image or audio data, of a resource link or of an embedded resource.
    .PARAMETER Size
        The size in bytes of a linked resource.
    .PARAMETER ResourceText
        The text contents of an embedded resource.
    .PARAMETER ResourceBlob
        The binary contents (byte[] or base64 string) of an embedded resource.
    .PARAMETER Annotations
        Annotations (audience, priority, lastModified) of the block.
    .PARAMETER Meta
        Additional _meta members of the block.
    .EXAMPLE
        New-McpContent -Text 'Hello'
    .EXAMPLE
        New-McpContent -Image (Get-Content ./chart.png -AsByteStream -Raw) -MimeType image/png
    .OUTPUTS
        Mcp.Content
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    [OutputType('Mcp.Content')]
    param(
        [Parameter(ParameterSetName = 'Text', Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(ParameterSetName = 'Image', Mandatory)]
        [ValidateNotNull()]
        [object] $Image,

        [Parameter(ParameterSetName = 'Audio', Mandatory)]
        [ValidateNotNull()]
        [object] $Audio,

        [Parameter(ParameterSetName = 'ResourceLink', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ResourceLink,

        [Parameter(ParameterSetName = 'EmbeddedResource', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $EmbeddedResource,

        [Parameter(ParameterSetName = 'ResourceLink', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(ParameterSetName = 'ResourceLink')]
        [string] $Title,

        [Parameter(ParameterSetName = 'ResourceLink')]
        [string] $Description,

        [Parameter(ParameterSetName = 'Image', Mandatory)]
        [Parameter(ParameterSetName = 'Audio', Mandatory)]
        [Parameter(ParameterSetName = 'ResourceLink')]
        [Parameter(ParameterSetName = 'EmbeddedResource')]
        [ValidateNotNullOrEmpty()]
        [string] $MimeType,

        [Parameter(ParameterSetName = 'ResourceLink')]
        [ValidateRange(0, [long]::MaxValue)]
        [long] $Size = -1,

        [Parameter(ParameterSetName = 'EmbeddedResource')]
        [string] $ResourceText,

        [Parameter(ParameterSetName = 'EmbeddedResource')]
        [object] $ResourceBlob,

        [hashtable] $Annotations,

        [hashtable] $Meta
    )

    $block = [ordered]@{}
    switch ($PSCmdlet.ParameterSetName) {
        'Text' {
            $block['type'] = 'text'
            $block['text'] = $Text
        }
        'Image' {
            $block['type'] = 'image'
            $block['data'] = ConvertTo-McpBase64 -Data $Image
            $block['mimeType'] = $MimeType
        }
        'Audio' {
            $block['type'] = 'audio'
            $block['data'] = ConvertTo-McpBase64 -Data $Audio
            $block['mimeType'] = $MimeType
        }
        'ResourceLink' {
            $block['type'] = 'resource_link'
            $block['uri'] = $ResourceLink
            $block['name'] = $Name
            if ($Title) { $block['title'] = $Title }
            if ($Description) { $block['description'] = $Description }
            if ($MimeType) { $block['mimeType'] = $MimeType }
            if ($Size -ge 0) { $block['size'] = $Size }
        }
        'EmbeddedResource' {
            if (-not $PSBoundParameters.ContainsKey('ResourceText') -and $null -eq $ResourceBlob) {
                throw [System.ArgumentException]::new('An embedded resource needs -ResourceText or -ResourceBlob.')
            }
            $resource = [ordered]@{ uri = $EmbeddedResource }
            if ($MimeType) { $resource['mimeType'] = $MimeType }
            if ($PSBoundParameters.ContainsKey('ResourceText')) { $resource['text'] = $ResourceText } else { $resource['blob'] = ConvertTo-McpBase64 -Data $ResourceBlob }
            $block['type'] = 'resource'
            $block['resource'] = $resource
        }
    }
    if ($Annotations -and $Annotations.Count -gt 0) { $block['annotations'] = $Annotations }
    if ($Meta -and $Meta.Count -gt 0) { $block['_meta'] = $Meta }
    $object = [pscustomobject] $block
    $object.PSObject.TypeNames.Insert(0, 'Mcp.Content')
    $object
}
