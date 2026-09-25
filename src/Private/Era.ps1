# Dual era: the choice between the stateless lifecycle of revision 2026-07-28 (modern) and the initialize
# handshake of the earlier revisions (legacy) for every inbound request, and the era-aware serialization of
# results and errors. Handlers and the result builders produce modern shapes; legacy responses are derived from
# them here, in one place.

function Get-McpServerVersion {
    <#
    .SYNOPSIS
        The protocol versions a server speaks in one era: the modern versions of SupportedVersions, or its legacy versions.
    .DESCRIPTION
        A server that lists any legacy revision also accepts 2025-03-26 in initialize (as a version string
        without features of its own), so that clients of that revision are answered with a revision they know.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [Parameter(Mandatory)]
        [ValidateSet('Modern', 'Legacy')]
        [string] $Era,

        # Legacy: also the versions accepted without being listed (2025-03-26).
        [switch] $Accepted
    )

    if ($Era -eq 'Modern') {
        return [string[]] @($Server.SupportedVersions | Where-Object { $_ -in $script:McpModernProtocolVersions })
    }
    $legacy = [System.Collections.Generic.List[string]]::new()
    foreach ($version in $Server.SupportedVersions) {
        if ($version -in $script:McpLegacyProtocolVersions -and -not $legacy.Contains($version)) { $legacy.Add($version) }
    }
    if ($Accepted -and $legacy.Count -gt 0) {
        foreach ($version in $script:McpLegacyProtocolVersions) {
            if (-not $legacy.Contains($version)) { $legacy.Add($version) }
        }
    }
    [string[]] $legacy.ToArray()
}

function Get-McpMessageEra {
    <#
    .SYNOPSIS
        The era of an inbound request: Legacy for initialize and for requests of an initialized legacy session, Modern otherwise.
    .DESCRIPTION
        Over Streamable HTTP the session is resolved from the Mcp-Session-Id header before (HttpServer.ps1) and
        passed in. Over the line transports (stdio, in memory) a request whose _meta carries the modern protocol
        version is modern; any other request belongs to the process-wide legacy session once one was opened.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [string] $Method,

        [AllowNull()]
        [object] $Params,

        [AllowNull()]
        [hashtable] $Session,

        [switch] $Http
    )

    if ($Method -ceq 'initialize') { return 'Legacy' }
    if ($null -ne $Session) { return 'Legacy' }
    if ($Http) { return 'Modern' }
    if ($Params -is [System.Collections.IDictionary] -and $Params['_meta'] -is [System.Collections.IDictionary] -and $Params['_meta'].Contains($script:McpMetaKey.ProtocolVersion)) {
        return 'Modern'
    }
    if ($null -ne $State.LineSession) { return 'Legacy' }
    'Modern'
}

function ConvertTo-McpLegacyResult {
    <#
    .SYNOPSIS
        The legacy shape of a result: without resultType, ttlMs, cacheScope and the io.modelcontextprotocol/ keys of _meta.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Result
    )

    foreach ($name in 'resultType', 'ttlMs', 'cacheScope') {
        if ($Result.Contains($name)) { $Result.Remove($name) }
    }
    if ($Result.Contains('_meta')) {
        $meta = $Result['_meta']
        if ($meta -is [System.Collections.IDictionary]) {
            foreach ($key in @($meta.Keys)) {
                if (([string] $key).StartsWith('io.modelcontextprotocol/', [System.StringComparison]::Ordinal)) { $meta.Remove($key) }
            }
            if ($meta.Count -eq 0) { $Result.Remove('_meta') }
        }
    }
    $Result
}

function ConvertTo-McpLegacyErrorObject {
    <#
    .SYNOPSIS
        The legacy form of an error object: the codes of revision 2026-07-28 (-32020, -32021, -32022) do not exist before it and become -32600.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ErrorObject
    )

    $modernOnly = @($script:McpErrorCode.HeaderMismatch, $script:McpErrorCode.MissingRequiredClientCapability, $script:McpErrorCode.UnsupportedProtocolVersion)
    if ($ErrorObject.Contains('code') -and [int] $ErrorObject['code'] -in $modernOnly) {
        $ErrorObject['code'] = $script:McpErrorCode.InvalidRequest
    }
    $ErrorObject
}

function ConvertTo-McpEraMessage {
    <#
    .SYNOPSIS
        A response in the shape of an era: modern responses pass unchanged, legacy results and errors are converted.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Message,

        [ValidateSet('Modern', 'Legacy')]
        [string] $Era = 'Modern'
    )

    if ($Era -ne 'Legacy') { return $Message }
    if ($Message.Contains('result') -and $Message['result'] -is [System.Collections.IDictionary]) {
        $null = ConvertTo-McpLegacyResult -Result $Message['result']
    } elseif ($Message.Contains('error') -and $Message['error'] -is [System.Collections.IDictionary]) {
        $null = ConvertTo-McpLegacyErrorObject -ErrorObject $Message['error']
    }
    $Message
}
