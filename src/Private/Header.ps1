# Header mirroring of the Streamable HTTP transport (revision 2026-07-28): the standard request headers
# Mcp-Method and Mcp-Name, the Mcp-Param-{Name} headers derived from x-mcp-header annotations in tool input
# schemas, and the Base64 sentinel encoding of values that cannot travel as plain header values. Shared by the
# client (encoding, annotation validation) and the server (decoding, validation against the body).

$script:McpHeaderSentinelPrefix = '=?base64?'
$script:McpHeaderSentinelSuffix = '?='
# tchar of RFC 9110 section 5.6.2: the characters allowed in an HTTP field name.
$script:McpHeaderTokenPattern = '^[!#$%&''*+.^_`|~0-9A-Za-z-]+$'
$script:McpHeaderPrimitiveTypes = @('string', 'integer', 'boolean')
# Methods that mirror a body value into Mcp-Name, and the params member that holds it.
$script:McpNamedMethod = @{
    'tools/call'     = 'name'
    'prompts/get'    = 'name'
    'resources/read' = 'uri'
}

function Get-McpStandardHeaderName {
    <#
    .SYNOPSIS
        The body value that a request mirrors into Mcp-Name (params.name or params.uri), or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Method,

        [AllowNull()]
        [object] $Params
    )

    if (-not $script:McpNamedMethod.ContainsKey($Method)) { return $null }
    $member = $script:McpNamedMethod[$Method]
    if ($Params -is [System.Collections.IDictionary] -and $Params.Contains($member) -and $Params[$member] -is [string]) {
        return [string] $Params[$member]
    }
    $null
}

function Test-McpHeaderValueSafe {
    <#
    .SYNOPSIS
        True when a value can be sent as a plain header value: visible ASCII and spaces, no leading or trailing
        whitespace, and not itself shaped like the Base64 sentinel.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value
    )

    if ($Value.Length -eq 0) { return $true }
    foreach ($char in $Value.ToCharArray()) {
        $code = [int] $char
        if ($code -lt 0x20 -or $code -gt 0x7E) { return $false }
    }
    if ($Value[0] -eq ' ' -or $Value[$Value.Length - 1] -eq ' ') { return $false }
    if ($Value.StartsWith($script:McpHeaderSentinelPrefix, [System.StringComparison]::Ordinal) -and $Value.EndsWith($script:McpHeaderSentinelSuffix, [System.StringComparison]::Ordinal)) { return $false }
    $true
}

function ConvertTo-McpHeaderText {
    <#
    .SYNOPSIS
        The string representation of a mirrored value: strings as they are, integers as decimal digits, booleans as true/false.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $Value,

        [Parameter(Mandatory)]
        [ValidateSet('string', 'integer', 'boolean')]
        [string] $Type
    )

    switch ($Type) {
        'boolean' {
            if ($Value -is [bool] -or $Value -is [switch]) { return $(if ([bool] $Value) { 'true' } else { 'false' }) }
            throw [System.ArgumentException]::new("A boolean header value must be a boolean, not $($Value.GetType().Name).")
        }
        'integer' {
            $number = $null
            try {
                $number = [System.Management.Automation.LanguagePrimitives]::ConvertTo($Value, [decimal])
            } catch {
                throw [System.ArgumentException]::new("An integer header value must be a number, not '$Value'.")
            }
            if ($number -ne [decimal]::Truncate($number)) {
                throw [System.ArgumentException]::new("An integer header value must be integral, not '$Value'.")
            }
            return ([decimal]::Truncate($number)).ToString('0', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        default {
            if ($Value -is [string]) { return $Value }
            return [System.Management.Automation.LanguagePrimitives]::ConvertTo($Value, [string])
        }
    }
}

function ConvertTo-McpHeaderValue {
    <#
    .SYNOPSIS
        Encodes a value for an Mcp-Name or Mcp-Param-{Name} header: plain when safe, otherwise =?base64?...?=.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $Value,

        [ValidateSet('string', 'integer', 'boolean')]
        [string] $Type = 'string'
    )

    $text = ConvertTo-McpHeaderText -Value $Value -Type $Type
    if (Test-McpHeaderValueSafe -Value $text) { return $text }
    $script:McpHeaderSentinelPrefix + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($text)) + $script:McpHeaderSentinelSuffix
}

function ConvertFrom-McpHeaderValue {
    <#
    .SYNOPSIS
        Decodes a received Mcp-Name or Mcp-Param-{Name} header value: trims optional whitespace and decodes the
        Base64 sentinel; a malformed sentinel is a header mismatch (-32020).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value,

        [string] $HeaderName = 'Mcp-Param'
    )

    $trimmed = $Value.Trim(' ', "`t")
    $prefix = $script:McpHeaderSentinelPrefix
    $suffix = $script:McpHeaderSentinelSuffix
    if ($trimmed.Length -ge ($prefix.Length + $suffix.Length) -and $trimmed.StartsWith($prefix, [System.StringComparison]::Ordinal) -and $trimmed.EndsWith($suffix, [System.StringComparison]::Ordinal)) {
        $encoded = $trimmed.Substring($prefix.Length, $trimmed.Length - $prefix.Length - $suffix.Length)
        try {
            return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
        } catch {
            throw [McpProtocolException]::new($script:McpErrorCode.HeaderMismatch, "Header mismatch: the $HeaderName header value is not valid Base64 inside the =?base64?...?= sentinel.")
        }
    }
    foreach ($char in $trimmed.ToCharArray()) {
        $code = [int] $char
        if ($code -lt 0x20 -and $code -ne 0x09) {
            throw [McpProtocolException]::new($script:McpErrorCode.HeaderMismatch, "Header mismatch: the $HeaderName header value contains control characters.")
        }
    }
    $trimmed
}

function Test-McpHeaderValueMatch {
    <#
    .SYNOPSIS
        True when a decoded header value equals the body value of the given primitive type (integers compare numerically).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $HeaderValue,

        [AllowNull()]
        [object] $BodyValue,

        [Parameter(Mandatory)]
        [ValidateSet('string', 'integer', 'boolean')]
        [string] $Type
    )

    if ($null -eq $BodyValue) { return $false }
    switch ($Type) {
        'integer' {
            $headerNumber = [double] 0
            if (-not [double]::TryParse($HeaderValue, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $headerNumber)) { return $false }
            if ($BodyValue -is [string] -or $BodyValue -is [bool]) { return $false }
            $bodyNumber = [double] 0
            try { $bodyNumber = [System.Management.Automation.LanguagePrimitives]::ConvertTo($BodyValue, [double]) } catch { return $false }
            return $headerNumber -eq $bodyNumber
        }
        'boolean' {
            if ($BodyValue -isnot [bool]) { return $false }
            return $HeaderValue -ceq $(if ($BodyValue) { 'true' } else { 'false' })
        }
        default {
            if ($BodyValue -isnot [string]) { return $false }
            return $HeaderValue -ceq [string] $BodyValue
        }
    }
}

function Get-McpToolHeaderParameter {
    <#
    .SYNOPSIS
        The x-mcp-header annotations of a tool input schema as property paths, header names and types.
    .DESCRIPTION
        Walks the schema and collects every property annotated with x-mcp-header that is reachable from the
        root through properties keys alone. An annotation that is empty, not an HTTP field-name token, applied
        to a non-primitive type, not unique (case-insensitively) or placed anywhere else (items, composition
        or conditional keywords, $ref, $defs, the root itself) makes the tool definition invalid: an
        ArgumentException names the reason. Returns an array of hashtables with Path (string[]), Header and Type.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [AllowNull()]
        [object] $InputSchema
    )

    $found = [System.Collections.Generic.List[hashtable]]::new()
    if ($InputSchema -is [System.Collections.IDictionary]) {
        Find-McpHeaderAnnotation -Schema $InputSchema -Path @() -Reachable $true -Found $found
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $found) {
        if (-not $seen.Add($entry.Header)) {
            throw [System.ArgumentException]::new("x-mcp-header '$($entry.Header)' is used more than once (header names are case-insensitive).")
        }
    }
    # The elements are emitted one by one; callers collect them with @( ) (no comma trick, so that a single
    # annotation is not wrapped twice by @( )).
    $found.ToArray()
}

function Find-McpHeaderAnnotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Schema,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Path,

        [Parameter(Mandatory)]
        [bool] $Reachable,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[hashtable]] $Found
    )

    if ($Schema.Contains('x-mcp-header')) {
        $location = if ($Path.Count -gt 0) { $Path -join '.' } else { '(schema root)' }
        if (-not $Reachable -or $Path.Count -eq 0) {
            throw [System.ArgumentException]::new("x-mcp-header at '$location' is not on a property reachable from the schema root through properties keys alone.")
        }
        $name = $Schema['x-mcp-header']
        if ($name -isnot [string] -or $name.Length -eq 0) {
            throw [System.ArgumentException]::new("x-mcp-header at '$location' must be a non-empty string.")
        }
        if ($name -notmatch $script:McpHeaderTokenPattern) {
            throw [System.ArgumentException]::new("x-mcp-header '$name' at '$location' is not a valid HTTP field-name token.")
        }
        $type = if ($Schema.Contains('type')) { $Schema['type'] } else { $null }
        if ($type -isnot [string] -or $type -notin $script:McpHeaderPrimitiveTypes) {
            $typeText = if ($null -eq $type) { 'none' } elseif ($type -is [string]) { $type } else { ConvertTo-McpJson -InputObject $type }
            throw [System.ArgumentException]::new("x-mcp-header '$name' at '$location' is applied to a property of type $typeText; only string, integer and boolean are allowed.")
        }
        $Found.Add(@{ Path = $Path; Header = $name; Type = $type })
    }
    foreach ($key in @($Schema.Keys)) {
        $keyText = [string] $key
        if ($keyText -eq 'x-mcp-header') { continue }
        $value = $Schema[$key]
        if ($keyText -eq 'properties' -and $value -is [System.Collections.IDictionary]) {
            foreach ($property in @($value.Keys)) {
                $child = $value[$property]
                if ($child -is [System.Collections.IDictionary]) {
                    Find-McpHeaderAnnotation -Schema $child -Path ($Path + [string] $property) -Reachable $Reachable -Found $Found
                }
            }
        } elseif ($value -is [System.Collections.IDictionary]) {
            Find-McpHeaderAnnotation -Schema $value -Path $Path -Reachable $false -Found $Found
        } elseif ($value -is [System.Collections.IList] -and $value -isnot [string]) {
            foreach ($item in $value) {
                if ($item -is [System.Collections.IDictionary]) {
                    Find-McpHeaderAnnotation -Schema $item -Path $Path -Reachable $false -Found $Found
                }
            }
        }
    }
}

function Get-McpHeaderArgumentValue {
    <#
    .SYNOPSIS
        The argument value at a property path: a hashtable with Present (a non-null value exists) and Value.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object] $Arguments,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Path
    )

    $current = $Arguments
    foreach ($segment in $Path) {
        if ($current -isnot [System.Collections.IDictionary] -or -not $current.Contains($segment)) { return @{ Present = $false; Value = $null } }
        $current = $current[$segment]
    }
    if ($null -eq $current) { return @{ Present = $false; Value = $null } }
    @{ Present = $true; Value = $current }
}

function Get-McpToolCallHeader {
    <#
    .SYNOPSIS
        The Mcp-Param-{Name} headers a client sends for a tools/call: values at the annotated paths, encoded.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [hashtable[]] $HeaderParameters,

        [AllowNull()]
        [object] $Arguments
    )

    $headers = @{}
    foreach ($parameter in @($HeaderParameters)) {
        if ($null -eq $parameter) { continue }
        $argument = Get-McpHeaderArgumentValue -Arguments $Arguments -Path $parameter.Path
        if (-not $argument.Present) { continue }
        $headers['Mcp-Param-' + $parameter.Header] = ConvertTo-McpHeaderValue -Value $argument.Value -Type $parameter.Type
    }
    $headers
}

function Test-McpToolParameterHeader {
    <#
    .SYNOPSIS
        Validates the Mcp-Param-{Name} headers of a tools/call against the arguments; throws -32020 on mismatch.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [hashtable[]] $HeaderParameters,

        [AllowNull()]
        [object] $Arguments,

        [Parameter(Mandatory)]
        [System.Collections.Specialized.NameValueCollection] $Headers
    )

    foreach ($parameter in @($HeaderParameters)) {
        if ($null -eq $parameter) { continue }
        $headerName = 'Mcp-Param-' + $parameter.Header
        $raw = $Headers[$headerName]
        $argument = Get-McpHeaderArgumentValue -Arguments $Arguments -Path $parameter.Path
        $location = $parameter.Path -join '.'
        if (-not $argument.Present) {
            if ($null -ne $raw) {
                throw [McpProtocolException]::new($script:McpErrorCode.HeaderMismatch, "Header mismatch: $headerName is present but the body has no value for '$location'.")
            }
            continue
        }
        if ($null -eq $raw) {
            throw [McpProtocolException]::new($script:McpErrorCode.HeaderMismatch, "Header mismatch: $headerName is missing although the body carries a value for '$location'.")
        }
        $decoded = ConvertFrom-McpHeaderValue -Value $raw -HeaderName $headerName
        if (-not (Test-McpHeaderValueMatch -HeaderValue $decoded -BodyValue $argument.Value -Type $parameter.Type)) {
            $bodyText = ConvertTo-McpJson -InputObject $argument.Value
            throw [McpProtocolException]::new($script:McpErrorCode.HeaderMismatch, "Header mismatch: $headerName value '$decoded' does not match body value $bodyText for '$location'.")
        }
    }
}

function Add-McpHeaderAnnotation {
    <#
    .SYNOPSIS
        Adds x-mcp-header annotations to the properties of an input schema from a parameter-name to header-name map.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Schema,

        [Parameter(Mandatory)]
        [hashtable] $Header
    )

    $properties = if ($Schema.Contains('properties') -and $Schema['properties'] -is [System.Collections.IDictionary]) { $Schema['properties'] } else { $null }
    foreach ($key in $Header.Keys) {
        $parameterName = [string] $key
        $headerName = [string] $Header[$key]
        $propertyKey = $null
        if ($null -ne $properties) {
            foreach ($candidate in $properties.Keys) {
                if ([string] $candidate -ceq $parameterName) { $propertyKey = $candidate; break }
            }
            if ($null -eq $propertyKey) {
                foreach ($candidate in $properties.Keys) {
                    if ([string] $candidate -ieq $parameterName) { $propertyKey = $candidate; break }
                }
            }
        }
        if ($null -eq $propertyKey -or $properties[$propertyKey] -isnot [System.Collections.IDictionary]) {
            throw [System.ArgumentException]::new("-Header names the parameter '$parameterName', which is not a property of the input schema.")
        }
        $properties[$propertyKey]['x-mcp-header'] = $headerName
    }
}
