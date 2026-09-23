# Cursor pagination of the list methods (tools/list, resources/list, resources/templates/list, prompts/list)
# with the caching hints every page carries. A cursor is opaque to clients; it encodes the list it belongs to
# and the offset of the next page, so a cursor of one list is rejected by another.

function New-McpCursor {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Encodes a value.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Kind,

        [Parameter(Mandatory)]
        [int] $Offset
    )

    [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("mcp-cursor:${Kind}:offset=$Offset"))
}

function Read-McpCursor {
    <#
    .SYNOPSIS
        The offset encoded in a cursor of the given list; -32602 for anything else.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string] $Kind,

        [AllowNull()]
        [object] $Cursor
    )

    if ($null -eq $Cursor) { return 0 }
    if ($Cursor -is [string]) {
        $text = $null
        try {
            $text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Cursor))
        } catch {
            $text = $null
        }
        if ($null -ne $text -and $text -match '^mcp-cursor:([A-Za-z]+):offset=(\d{1,9})$' -and $Matches[1] -ceq $Kind) { return [int] $Matches[2] }
    }
    throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, 'Invalid cursor.')
}

function Get-McpPagedListResult {
    <#
    .SYNOPSIS
        One page of a list result: resultType, the converted items, nextCursor, ttlMs, cacheScope and _meta.
    .DESCRIPTION
        Every page carries the server's default caching hints, so all pages of one list share the same
        cacheScope, as the specification requires. The item member is named after the list kind (tools,
        resources, resourceTemplates, prompts).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [Parameter(Mandatory)]
        [ValidateSet('tools', 'resources', 'resourceTemplates', 'prompts')]
        [string] $Kind,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Items,

        [Parameter(Mandatory)]
        [scriptblock] $Converter,

        [AllowNull()]
        [object] $Cursor
    )

    $offset = Read-McpCursor -Kind $Kind -Cursor $Cursor
    if ($offset -gt $Items.Count) {
        throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, 'Invalid cursor.')
    }
    $pageSize = [int] $Server.Options.PageSize
    $page = @()
    if ($offset -lt $Items.Count) {
        $end = [math]::Min($offset + $pageSize, $Items.Count) - 1
        $page = @($Items[$offset..$end] | ForEach-Object { & $Converter $_ })
    }
    $result = [ordered]@{ resultType = 'complete' }
    $result[$Kind] = $page
    if ($offset + $pageSize -lt $Items.Count) {
        $result['nextCursor'] = New-McpCursor -Kind $Kind -Offset ($offset + $pageSize)
    }
    $result['ttlMs'] = [long] $Server.Options.DefaultTtlMs
    $result['cacheScope'] = $Server.Options.DefaultCacheScope
    Add-McpResultMeta -Result $result -Server $Server
}
