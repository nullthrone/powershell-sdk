# Per-request metadata of revision 2026-07-28: every request carries _meta with the protocol version and the
# client capabilities (required), the client info, the log level and a progress token (optional).

$script:McpMetaKey = @{
    ProtocolVersion    = 'io.modelcontextprotocol/protocolVersion'
    ClientCapabilities = 'io.modelcontextprotocol/clientCapabilities'
    ClientInfo         = 'io.modelcontextprotocol/clientInfo'
    LogLevel           = 'io.modelcontextprotocol/logLevel'
    ServerInfo         = 'io.modelcontextprotocol/serverInfo'
    SubscriptionId     = 'io.modelcontextprotocol/subscriptionId'
    ProgressToken      = 'progressToken'
}

$script:McpLoggingLevelNames = @('debug', 'info', 'notice', 'warning', 'error', 'critical', 'alert', 'emergency')

function Get-McpMetaKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ProtocolVersion', 'ClientCapabilities', 'ClientInfo', 'LogLevel', 'ServerInfo', 'SubscriptionId', 'ProgressToken')]
        [string] $Name
    )

    $script:McpMetaKey[$Name]
}

function Get-McpRequestMeta {
    <#
    .SYNOPSIS
        Validates params._meta of a modern request and returns its fields; throws McpProtocolException on violations.
    .DESCRIPTION
        Missing or malformed required fields are an invalid-params error (-32602). A protocol version the server
        does not support is an unsupported-protocol-version error (-32022) whose data lists the supported
        versions and the requested one.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object] $Params,

        [Parameter(Mandatory)]
        [string[]] $SupportedVersions
    )

    $invalidParams = $script:McpErrorCode.InvalidParams
    if ($Params -isnot [System.Collections.IDictionary] -or -not $Params.Contains('_meta') -or $Params['_meta'] -isnot [System.Collections.IDictionary]) {
        throw [McpProtocolException]::new($invalidParams, "Missing required _meta: every request must carry params._meta with '$($script:McpMetaKey.ProtocolVersion)' and '$($script:McpMetaKey.ClientCapabilities)'.")
    }
    $meta = $Params['_meta']

    $versionKey = $script:McpMetaKey.ProtocolVersion
    if (-not $meta.Contains($versionKey) -or $meta[$versionKey] -isnot [string] -or [string]::IsNullOrEmpty($meta[$versionKey])) {
        throw [McpProtocolException]::new($invalidParams, "Missing required _meta field '$versionKey'.")
    }
    $protocolVersion = [string] $meta[$versionKey]

    $capabilitiesKey = $script:McpMetaKey.ClientCapabilities
    if (-not $meta.Contains($capabilitiesKey) -or $meta[$capabilitiesKey] -isnot [System.Collections.IDictionary]) {
        throw [McpProtocolException]::new($invalidParams, "Missing required _meta field '$capabilitiesKey' (an object).")
    }
    $clientCapabilities = $meta[$capabilitiesKey]

    if ($protocolVersion -notin $SupportedVersions) {
        $data = [ordered]@{
            supported = @($SupportedVersions)
            requested = $protocolVersion
        }
        throw [McpProtocolException]::new($script:McpErrorCode.UnsupportedProtocolVersion, "Unsupported protocol version '$protocolVersion'; supported: $($SupportedVersions -join ', ').", $data)
    }

    $clientInfo = $null
    $infoKey = $script:McpMetaKey.ClientInfo
    if ($meta.Contains($infoKey) -and $null -ne $meta[$infoKey]) {
        $clientInfo = $meta[$infoKey]
        if ($clientInfo -isnot [System.Collections.IDictionary] -or -not $clientInfo.Contains('name') -or $clientInfo['name'] -isnot [string] -or -not $clientInfo.Contains('version') -or $clientInfo['version'] -isnot [string]) {
            throw [McpProtocolException]::new($invalidParams, "_meta field '$infoKey' must be an object with string members 'name' and 'version'.")
        }
    }

    $logLevel = $null
    $levelKey = $script:McpMetaKey.LogLevel
    if ($meta.Contains($levelKey) -and $null -ne $meta[$levelKey]) {
        $logLevel = $meta[$levelKey]
        if ($logLevel -isnot [string] -or $logLevel -cnotin $script:McpLoggingLevelNames) {
            throw [McpProtocolException]::new($invalidParams, "_meta field '$levelKey' must be one of: $($script:McpLoggingLevelNames -join ', ').")
        }
    }

    $progressToken = $null
    $tokenKey = $script:McpMetaKey.ProgressToken
    if ($meta.Contains($tokenKey) -and $null -ne $meta[$tokenKey]) {
        $progressToken = $meta[$tokenKey]
        if (-not (Test-McpRequestId -Id $progressToken)) {
            throw [McpProtocolException]::new($invalidParams, "_meta field '$tokenKey' must be a string or an integer.")
        }
    }

    @{
        ProtocolVersion    = $protocolVersion
        ClientCapabilities = $clientCapabilities
        ClientInfo         = $clientInfo
        LogLevel           = $logLevel
        ProgressToken      = $progressToken
    }
}

function Test-McpCapabilityPath {
    <#
    .SYNOPSIS
        True when a dotted capability path (for example 'elicitation.form' or 'extensions.io.modelcontextprotocol/tasks') exists in a capabilities object.
    .DESCRIPTION
        Segments are separated by '.'; a segment that contains '/' is an extension identifier and may itself
        contain dots, so a path is matched greedily: the longest key that starts the remaining path wins.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Capabilities,

        [Parameter(Mandatory)]
        [string] $Path
    )

    $current = $Capabilities
    $remaining = $Path
    while ($remaining.Length -gt 0) {
        if ($current -isnot [System.Collections.IDictionary]) { return $false }
        $match = $null
        foreach ($key in $current.Keys) {
            $keyText = [string] $key
            if ($remaining -ceq $keyText -or $remaining.StartsWith($keyText + '.', [System.StringComparison]::Ordinal)) {
                if ($null -eq $match -or $keyText.Length -gt $match.Length) { $match = $keyText }
            }
        }
        if ($null -eq $match) { return $false }
        $current = $current[$match]
        $remaining = if ($remaining.Length -gt $match.Length) { $remaining.Substring($match.Length + 1) } else { '' }
    }
    $true
}
