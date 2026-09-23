# Metadata shared by the primitives: icons (Icon) and the annotations of content blocks and resources
# (Annotations: audience, priority, lastModified), normalised to wire objects and validated at registration.

function Get-McpDictionaryValue {
    <#
    .SYNOPSIS
        The entries of a hashtable, ordered dictionary or PSCustomObject as (key, value) pairs.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.DictionaryEntry])]
    param(
        [Parameter(Mandatory)]
        [object] $InputObject
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) { [System.Collections.DictionaryEntry]::new($key, $InputObject[$key]) }
    } elseif ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $InputObject.PSObject.Properties) { [System.Collections.DictionaryEntry]::new($property.Name, $property.Value) }
    } else {
        throw [System.ArgumentException]::new("Expected a hashtable or object, got $($InputObject.GetType().Name).")
    }
}

function ConvertTo-McpIconList {
    <#
    .SYNOPSIS
        Validates icons (hashtables or objects with src, mimeType, sizes, theme; or plain src strings) and returns wire Icon objects.
    #>
    [CmdletBinding()]
    [OutputType([object[]], [System.Array])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Icons
    )

    if ($null -eq $Icons -or $Icons.Count -eq 0) { return $null }
    $known = @{ src = 'src'; mimetype = 'mimeType'; sizes = 'sizes'; theme = 'theme' }
    $list = foreach ($icon in $Icons) {
        if ($null -eq $icon) { continue }
        $entries = if ($icon -is [string]) { @([System.Collections.DictionaryEntry]::new('src', $icon)) } else { @(Get-McpDictionaryValue -InputObject $icon) }
        $wire = [ordered]@{}
        foreach ($entry in $entries) {
            $lower = ([string] $entry.Key).ToLowerInvariant()
            if (-not $known.ContainsKey($lower)) {
                throw [System.ArgumentException]::new("Unknown icon member '$($entry.Key)'; icons have src, mimeType, sizes and theme.")
            }
            $wire[$known[$lower]] = $entry.Value
        }
        $source = [string] $wire['src']
        $uri = $null
        if (-not $source -or -not [uri]::TryCreate($source, [System.UriKind]::Absolute, [ref] $uri) -or $uri.Scheme -notin @('http', 'https', 'data')) {
            throw [System.ArgumentException]::new("Icon src '$source' must be an absolute http, https or data URI.")
        }
        $wire['src'] = $source
        if ($wire.Contains('mimeType')) { $wire['mimeType'] = [string] $wire['mimeType'] }
        if ($wire.Contains('sizes')) {
            $sizes = @($wire['sizes'] | ForEach-Object { [string] $_ })
            foreach ($size in $sizes) {
                if ($size -notmatch '^(\d+x\d+|any)$') {
                    throw [System.ArgumentException]::new("Icon size '$size' must be 'WIDTHxHEIGHT' (for example 48x48) or 'any'.")
                }
            }
            $wire['sizes'] = $sizes
        }
        if ($wire.Contains('theme')) {
            $theme = ([string] $wire['theme']).ToLowerInvariant()
            if ($theme -notin @('light', 'dark')) { throw [System.ArgumentException]::new("Icon theme '$($wire['theme'])' must be light or dark.") }
            $wire['theme'] = $theme
        }
        $wire
    }
    , @($list)
}

function ConvertTo-McpContentAnnotation {
    <#
    .SYNOPSIS
        Validates annotations of a content block, resource or template and returns the wire Annotations object.
    .DESCRIPTION
        audience is user and/or assistant, priority a number from 0 (least) to 1 (most important), and
        lastModified an ISO 8601 timestamp (a DateTime or DateTimeOffset is converted to UTC).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [object] $Annotations
    )

    if ($null -eq $Annotations) { return $null }
    $wire = [ordered]@{}
    foreach ($entry in Get-McpDictionaryValue -InputObject $Annotations) {
        switch (([string] $entry.Key).ToLowerInvariant()) {
            'audience' {
                $roles = @($entry.Value | ForEach-Object { ([string] $_).ToLowerInvariant() })
                foreach ($role in $roles) {
                    if ($role -notin @('user', 'assistant')) { throw [System.ArgumentException]::new("Annotation audience '$role' must be user or assistant.") }
                }
                $wire['audience'] = $roles
            }
            'priority' {
                $priority = 0.0
                if (-not [double]::TryParse([string] $entry.Value, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref] $priority) -or $priority -lt 0 -or $priority -gt 1) {
                    throw [System.ArgumentException]::new("Annotation priority '$($entry.Value)' must be a number from 0 to 1.")
                }
                $wire['priority'] = $priority
            }
            'lastmodified' {
                $value = $entry.Value
                if ($value -is [datetime]) { $value = [datetimeoffset] $value.ToUniversalTime() }
                if ($value -is [datetimeoffset]) {
                    $wire['lastModified'] = $value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'", [cultureinfo]::InvariantCulture)
                } else {
                    $parsed = [datetimeoffset]::MinValue
                    if (-not [datetimeoffset]::TryParse([string] $value, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref] $parsed)) {
                        throw [System.ArgumentException]::new("Annotation lastModified '$value' must be an ISO 8601 timestamp.")
                    }
                    $wire['lastModified'] = [string] $value
                }
            }
            default {
                throw [System.ArgumentException]::new("Unknown annotation '$($entry.Key)'; content annotations are audience, priority and lastModified.")
            }
        }
    }
    if ($wire.Count -eq 0) { return $null }
    $wire
}

function ConvertTo-McpMetaObject {
    <#
    .SYNOPSIS
        A _meta dictionary given as hashtable or object, as an ordered dictionary; $null when empty.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [object] $Meta
    )

    if ($null -eq $Meta) { return $null }
    $wire = [ordered]@{}
    foreach ($entry in Get-McpDictionaryValue -InputObject $Meta) { $wire[[string] $entry.Key] = $entry.Value }
    if ($wire.Count -eq 0) { return $null }
    $wire
}
