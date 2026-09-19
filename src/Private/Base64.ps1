function ConvertTo-McpBase64 {
    <#
    .SYNOPSIS
        Base64 text for binary content given as byte[] or as an already encoded string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Data
    )

    if ($Data -is [byte[]]) { return [System.Convert]::ToBase64String([byte[]] $Data) }
    if ($Data -is [string]) {
        try {
            $null = [System.Convert]::FromBase64String([string] $Data)
            return [string] $Data
        } catch {
            throw [System.ArgumentException]::new('Binary content must be a byte[] or a valid base64 string.')
        }
    }
    if ($Data -is [System.Collections.IEnumerable]) {
        return [System.Convert]::ToBase64String([byte[]] @($Data))
    }
    throw [System.ArgumentException]::new('Binary content must be a byte[] or a valid base64 string.')
}
