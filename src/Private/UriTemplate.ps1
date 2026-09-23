# RFC 6570 URI templates of resource templates: parsing and matching a concrete URI against a template to
# extract its variables. Levels 1 to 3 are supported (the operators none, +, #, ., /, ;, ? and &); the level 4
# modifiers (prefix :n and explode *) are rejected at registration, because matching them in reverse is
# ambiguous.

$script:McpUriTemplateOperators = @('', '+', '#', '.', '/', ';', '?', '&')
$script:McpUriTemplateVariablePattern = '^(?:[A-Za-z0-9_]|%[0-9A-Fa-f]{2})(?:\.?(?:[A-Za-z0-9_]|%[0-9A-Fa-f]{2}))*$'
# Unreserved characters and percent-encoded octets; the reserved expansions (+, #) also allow reserved characters.
$script:McpUriTemplateUnreserved = '(?:[A-Za-z0-9\-._~]|%[0-9A-Fa-f]{2})'
$script:McpUriTemplateReserved = '(?:[A-Za-z0-9\-._~:/?#\[\]@!$&''()*+,;=]|%[0-9A-Fa-f]{2})'

function ConvertFrom-McpUriTemplate {
    <#
    .SYNOPSIS
        Parses a URI template into literal and expression parts and compiles the regular expression that matches it.
    .OUTPUTS
        A hashtable with Template, Variables (names in order), Regex and Groups (group name -> variable and operator).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $Template
    )

    $pattern = [System.Text.StringBuilder]::new('^')
    $variables = [System.Collections.Generic.List[string]]::new()
    $groups = [ordered]@{}
    $position = 0
    $groupIndex = 0
    while ($position -lt $Template.Length) {
        $open = $Template.IndexOf('{', $position)
        $closeBefore = $Template.IndexOf('}', $position)
        if ($closeBefore -ge 0 -and ($open -lt 0 -or $closeBefore -lt $open)) {
            throw [System.ArgumentException]::new("URI template '$Template' has an unmatched '}'.")
        }
        if ($open -lt 0) {
            $null = $pattern.Append([regex]::Escape($Template.Substring($position)))
            break
        }
        $null = $pattern.Append([regex]::Escape($Template.Substring($position, $open - $position)))
        $close = $Template.IndexOf('}', $open)
        if ($close -lt 0) { throw [System.ArgumentException]::new("URI template '$Template' has an unmatched '{'.") }
        $expression = $Template.Substring($open + 1, $close - $open - 1)
        $position = $close + 1
        if ($expression.Length -eq 0) { throw [System.ArgumentException]::new("URI template '$Template' has an empty expression.") }
        $operator = ''
        if ('+#./;?&=,!@|'.Contains($expression[0])) {
            $operator = [string] $expression[0]
            $expression = $expression.Substring(1)
        }
        if ($operator -notin $script:McpUriTemplateOperators) {
            throw [System.ArgumentException]::new("URI template '$Template' uses the reserved operator '$operator'.")
        }
        $names = @($expression.Split(','))
        foreach ($name in $names) {
            if ($name -match '[:*]') {
                throw [System.ArgumentException]::new("URI template '$Template' uses the level 4 modifier in '$name'; prefix (:n) and explode (*) modifiers are not supported.")
            }
            if ($name -notmatch $script:McpUriTemplateVariablePattern) {
                throw [System.ArgumentException]::new("URI template '$Template' has an invalid variable name '$name'.")
            }
            if ($variables.Contains($name)) {
                throw [System.ArgumentException]::new("URI template '$Template' uses the variable '$name' more than once.")
            }
            $variables.Add($name)
        }

        if ($operator -in @('?', '&')) {
            # Query expansions are matched as a whole and parsed into name=value pairs.
            $group = 'q' + $groupIndex++
            $groups[$group] = @{ Operator = $operator; Names = $names }
            $lead = if ($operator -eq '?') { '\?' } else { '&' }
            $null = $pattern.Append("(?:$lead(?<$group>[^#]*?))?")
            continue
        }
        $value = if ($operator -in @('+', '#')) { $script:McpUriTemplateReserved } else { $script:McpUriTemplateUnreserved }
        if ($operator -eq '.') { $value = '(?:[A-Za-z0-9\-_~]|%[0-9A-Fa-f]{2})' }
        $first = $true
        foreach ($name in $names) {
            $group = 'v' + $groupIndex++
            $groups[$group] = @{ Operator = $operator; Names = @($name) }
            switch ($operator) {
                { $_ -in @('', '+') } {
                    if ($first -and $names.Count -eq 1) { $null = $pattern.Append("(?<$group>$value+)") }
                    elseif ($first) { $null = $pattern.Append("(?<$group>$value*)") }
                    else { $null = $pattern.Append("(?:,(?<$group>$value*))?") }
                }
                '#' {
                    if ($first) { $null = $pattern.Append("(?:#(?<$group>$value*)") }
                    else { $null = $pattern.Append("(?:,(?<$group>$value*))?") }
                }
                '.' { $null = $pattern.Append("(?:\.(?<$group>$value*))?") }
                '/' { $null = $pattern.Append("(?:/(?<$group>$value*))?") }
                ';' { $null = $pattern.Append("(?:;$([regex]::Escape($name))(?:=(?<$group>$value*))?)?") }
            }
            $first = $false
        }
        if ($operator -eq '#') { $null = $pattern.Append(')?') }
    }
    $null = $pattern.Append('$')
    @{
        Template  = $Template
        Variables = $variables.ToArray()
        Regex     = [regex]::new($pattern.ToString(), [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
        Groups    = $groups
    }
}

function Test-McpUriTemplateMatch {
    <#
    .SYNOPSIS
        Matches a URI against a parsed template; returns the decoded variables, or $null when it does not match.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Template,

        [Parameter(Mandatory)]
        [string] $Uri
    )

    $match = $Template.Regex.Match($Uri)
    if (-not $match.Success) { return $null }
    $variables = [ordered]@{}
    foreach ($entry in $Template.Groups.GetEnumerator()) {
        $group = $match.Groups[$entry.Key]
        if (-not $group.Success) { continue }
        if ($entry.Value.Operator -in @('?', '&')) {
            $query = $group.Value
            if ($entry.Value.Operator -eq '&' -and $query.StartsWith('&')) { $query = $query.Substring(1) }
            foreach ($pair in $query.Split('&')) {
                if ($pair.Length -eq 0) { continue }
                $parts = $pair.Split('=', 2)
                $name = [System.Uri]::UnescapeDataString($parts[0])
                if ($name -notin $entry.Value.Names -or $variables.Contains($name)) { continue }
                $variables[$name] = if ($parts.Count -eq 2) { [System.Uri]::UnescapeDataString($parts[1]) } else { '' }
            }
            continue
        }
        $variables[$entry.Value.Names[0]] = [System.Uri]::UnescapeDataString($group.Value)
    }
    $variables
}
