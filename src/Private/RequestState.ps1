# requestState of multi-round-trip requests: an opaque token the server hands to the client with an
# InputRequiredResult and gets back verbatim on the retry. It carries the answers collected in earlier rounds
# and the handler's own state, bound to the method, the target (tool or prompt name, resource URI), a digest
# of the arguments and an expiry, and is signed with HMAC-SHA256. It is integrity-protected, not encrypted.
#
# Format: base64url(UTF-8 JSON payload) '.' base64url(HMAC-SHA256(key, first part)).

function ConvertTo-McpBase64Url {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes
    )

    [System.Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-McpBase64Url {
    [CmdletBinding()]
    [OutputType([byte[]], [System.Array])]
    param(
        [Parameter(Mandatory)]
        [string] $Text
    )

    if ($Text -notmatch '^[A-Za-z0-9_-]*$') { throw [System.FormatException]::new('Not base64url.') }
    $base64 = $Text.Replace('-', '+').Replace('_', '/')
    switch ($base64.Length % 4) {
        2 { $base64 += '==' }
        3 { $base64 += '=' }
        1 { throw [System.FormatException]::new('Not base64url.') }
    }
    , [System.Convert]::FromBase64String($base64)
}

function ConvertTo-McpRequestStateKey {
    <#
    .SYNOPSIS
        The 32-byte signing key of requestState: from a SecureString or string (hashed with SHA-256), a byte[] of at least 32 bytes, or random.
    #>
    [CmdletBinding()]
    [OutputType([byte[]], [System.Object[]], [System.Array])]
    param(
        [AllowNull()]
        [object] $Key
    )

    if ($null -eq $Key) { return , [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32) }
    if ($Key -is [byte[]]) {
        if ($Key.Length -lt 32) { throw [System.ArgumentException]::new('-RequestStateKey must have at least 32 bytes.') }
        return , [byte[]] $Key.Clone()
    }
    $text = if ($Key -is [System.Security.SecureString]) { [System.Net.NetworkCredential]::new('', $Key).Password } elseif ($Key -is [string]) { $Key } else { throw [System.ArgumentException]::new('-RequestStateKey must be a SecureString, a string or a byte[] of at least 32 bytes.') }
    if ($text.Length -lt 16) { throw [System.ArgumentException]::new('-RequestStateKey must have at least 16 characters.') }
    , [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))
}

function ConvertTo-McpCanonicalValue {
    <#
    .SYNOPSIS
        A copy of a JSON value with the members of every object sorted ordinally, for digests that do not depend on member order.
    #>
    [CmdletBinding()]
    [OutputType([object], [System.Collections.Specialized.OrderedDictionary], [System.Array])]
    param(
        [AllowNull()]
        [object] $Value,

        [int] $Depth = 0
    )

    if ($Depth -gt 64) { throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, 'The arguments are nested too deeply.') }
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $sorted = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string] $_ } | Sort-Object -Culture ([cultureinfo]::InvariantCulture) -CaseSensitive)) {
            $sorted[$key] = ConvertTo-McpCanonicalValue -Value $Value[$key] -Depth ($Depth + 1)
        }
        return $sorted
    }
    if ($Value -is [string] -or $Value -isnot [System.Collections.IEnumerable]) { return $Value }
    , @(foreach ($item in $Value) { ConvertTo-McpCanonicalValue -Value $item -Depth ($Depth + 1) })
}

function Get-McpRequestDigest {
    <#
    .SYNOPSIS
        A SHA-256 digest (base64url) of the salient params of a request: arguments of tools/call and prompts/get, the URI of resources/read.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Method,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Params
    )

    $salient = [ordered]@{ method = $Method }
    foreach ($key in 'name', 'uri', 'arguments') {
        if ($Params.Contains($key)) { $salient[$key] = $Params[$key] }
    }
    $json = ConvertTo-McpJson -InputObject (ConvertTo-McpCanonicalValue -Value $salient)
    ConvertTo-McpBase64Url -Bytes ([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($json)))
}

function New-McpRequestState {
    <#
    .SYNOPSIS
        Signs a requestState for the next round of a request.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a token.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [byte[]] $Key,

        [Parameter(Mandatory)]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $Digest,

        # The input responses the handler accepted so far (key -> response).
        [System.Collections.IDictionary] $Answers = [ordered]@{},

        # The input requests of this round (key -> method).
        [System.Collections.IDictionary] $Requested = [ordered]@{},

        # The handler's own state (Context.State).
        [AllowNull()]
        [System.Collections.IDictionary] $HandlerState,

        [int] $TtlSeconds = 600
    )

    $payload = [ordered]@{
        v     = 1
        m     = $Method
        n     = $Name
        d     = $Digest
        exp   = [System.DateTimeOffset]::UtcNow.AddSeconds($TtlSeconds).ToUnixTimeMilliseconds()
        nonce = ConvertTo-McpBase64Url -Bytes ([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(12))
        a     = $Answers
        r     = $Requested
    }
    if ($null -ne $HandlerState -and $HandlerState.Count -gt 0) { $payload['s'] = $HandlerState }
    $body = ConvertTo-McpBase64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes((ConvertTo-McpJson -InputObject $payload)))
    $mac = [System.Security.Cryptography.HMACSHA256]::HashData($Key, [System.Text.Encoding]::ASCII.GetBytes($body))
    $body + '.' + (ConvertTo-McpBase64Url -Bytes $mac)
}

function Read-McpRequestState {
    <#
    .SYNOPSIS
        Verifies a requestState (signature, expiry, method, target, argument digest) and returns its payload; -32602 otherwise.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [byte[]] $Key,

        [AllowNull()]
        [object] $Token,

        [Parameter(Mandatory)]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $Digest
    )

    $invalid = { param($reason) [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "Invalid requestState: $reason.") }
    if ($Token -isnot [string] -or $Token.Length -gt 1MB) { throw (& $invalid 'not a string of acceptable length') }
    $parts = $Token.Split('.')
    if ($parts.Count -ne 2) { throw (& $invalid 'malformed') }
    $expected = [System.Security.Cryptography.HMACSHA256]::HashData($Key, [System.Text.Encoding]::ASCII.GetBytes($parts[0]))
    $given = $null
    try { $given = ConvertFrom-McpBase64Url -Text $parts[1] } catch { $given = $null }
    if ($null -eq $given -or -not [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($expected, $given)) {
        throw (& $invalid 'the signature does not match')
    }
    $payload = $null
    try {
        $payload = ConvertFrom-McpJson -Json ([System.Text.Encoding]::UTF8.GetString((ConvertFrom-McpBase64Url -Text $parts[0])))
    } catch {
        $payload = $null
    }
    if ($payload -isnot [System.Collections.IDictionary] -or $payload['v'] -ne 1) { throw (& $invalid 'unknown format') }
    if ([long] $payload['exp'] -lt [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) { throw (& $invalid 'it has expired') }
    if ($payload['m'] -cne $Method -or $payload['n'] -cne $Name) { throw (& $invalid 'it belongs to another request') }
    if ($payload['d'] -cne $Digest) { throw (& $invalid 'the arguments differ from the original request') }
    $payload
}
