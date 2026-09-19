# JSON Schema support: generation of tool input schemas from PowerShell parameter metadata and validation of
# instances against JSON Schema 2020-12.
#
# Validation prefers the JsonSchema.Net assembly that ships with PowerShell (used through its API, not through
# Test-Json, so that schemas without $schema evaluate as 2020-12 and external $ref values are never fetched).
# A validator written in PowerShell covers the common keyword subset as a fallback and for environments where
# the assembly cannot be loaded; both engines are exercised by the tests.

$script:McpJsonSchemaEngine = $null
$script:McpSchemaMaxDepth = 32
$script:McpSchemaMaxNodes = 16384
$script:McpSupportedSchemaDialects = @(
    'https://json-schema.org/draft/2020-12/schema'
    'https://json-schema.org/draft/2019-09/schema'
    'http://json-schema.org/draft-07/schema#'
    'http://json-schema.org/draft-07/schema'
    'http://json-schema.org/draft-06/schema#'
    'http://json-schema.org/draft-06/schema'
)

function Get-McpJsonSchemaEngine {
    <#
    .SYNOPSIS
        The validation engine in use: JsonSchemaNet when the bundled assembly loads, otherwise PowerShell.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($script:McpJsonSchemaEngine) { return $script:McpJsonSchemaEngine }
    $engine = 'PowerShell'
    try {
        $type = 'Json.Schema.JsonSchema' -as [type]
        if (-not $type) {
            $assemblyPath = Join-Path $PSHOME 'JsonSchema.Net.dll'
            if (Test-Path -Path $assemblyPath) {
                Add-Type -Path $assemblyPath -ErrorAction Stop
                $type = 'Json.Schema.JsonSchema' -as [type]
            }
        }
        if ($type -and ('Json.Schema.EvaluationOptions' -as [type]) -and ([Json.Schema.EvaluationOptions].GetProperty('EvaluateAs'))) {
            $engine = 'JsonSchemaNet'
        }
    } catch {
        $engine = 'PowerShell'
    }
    $script:McpJsonSchemaEngine = $engine
    $engine
}

function ConvertTo-McpSchemaObject {
    <#
    .SYNOPSIS
        Normalises a schema given as JSON text, hashtable or PSObject into ordered dictionaries.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Schema
    )

    if ($Schema -is [string]) {
        return ConvertFrom-McpJson -Json $Schema -MaxDepth 256
    }
    ConvertFrom-McpJson -Json (ConvertTo-McpJson -InputObject $Schema -MaxDepth 256) -MaxDepth 256
}

function Test-McpSchemaLimit {
    <#
    .SYNOPSIS
        Rejects schemas that are too deep or too large and schemas with external $ref values or unsupported dialects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Schema
    )

    if ($Schema -is [System.Collections.IDictionary] -and $Schema.Contains('$schema')) {
        $dialect = [string] $Schema['$schema']
        if ($dialect -notin $script:McpSupportedSchemaDialects) {
            throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "Unsupported JSON Schema dialect '$dialect'. Supported: 2020-12 (default), 2019-09, draft-07, draft-06.")
        }
    }
    $count = 0
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push(@{ Node = $Schema; Depth = 0 })
    while ($stack.Count -gt 0) {
        $entry = $stack.Pop()
        $node = $entry.Node
        if ($entry.Depth -gt $script:McpSchemaMaxDepth) {
            throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "The JSON Schema is nested deeper than $($script:McpSchemaMaxDepth) levels.")
        }
        if ($node -is [System.Collections.IDictionary]) {
            $count++
            if ($count -gt $script:McpSchemaMaxNodes) {
                throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "The JSON Schema has more than $($script:McpSchemaMaxNodes) subschemas.")
            }
            if ($node.Contains('$ref') -and $node['$ref'] -is [string]) {
                $reference = [string] $node['$ref']
                if (-not $reference.StartsWith('#')) {
                    throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "The JSON Schema references '$reference'; only local references (#/...) are supported and external references are never fetched.")
                }
            }
            foreach ($value in $node.Values) {
                if ($value -is [System.Collections.IDictionary] -or ($value -is [System.Collections.IList] -and $value -isnot [string])) {
                    $stack.Push(@{ Node = $value; Depth = $entry.Depth + 1 })
                }
            }
        } elseif ($node -is [System.Collections.IList]) {
            foreach ($value in $node) {
                if ($value -is [System.Collections.IDictionary] -or ($value -is [System.Collections.IList] -and $value -isnot [string])) {
                    $stack.Push(@{ Node = $value; Depth = $entry.Depth + 1 })
                }
            }
        }
    }
}

function Test-McpJsonSchema {
    <#
    .SYNOPSIS
        Validates an instance against a JSON Schema and returns IsValid plus a list of error messages.
    .DESCRIPTION
        The schema may be JSON text, a hashtable or a PSObject. Schemas without $schema are evaluated as JSON
        Schema 2020-12. External $ref values are rejected before evaluation. -Engine selects the engine
        explicitly (JsonSchemaNet, PowerShell); Auto uses JsonSchema.Net when it is available.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Schema,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Instance,

        [ValidateSet('Auto', 'JsonSchemaNet', 'PowerShell')]
        [string] $Engine = 'Auto'
    )

    $schemaObject = ConvertTo-McpSchemaObject -Schema $Schema
    Test-McpSchemaLimit -Schema $schemaObject
    if ($Engine -eq 'Auto') {
        $Engine = Get-McpJsonSchemaEngine
    }
    if ($Engine -eq 'JsonSchemaNet') {
        if ((Get-McpJsonSchemaEngine) -ne 'JsonSchemaNet') {
            throw [System.InvalidOperationException]::new('JsonSchema.Net is not available in this PowerShell installation.')
        }
        return Test-McpJsonSchemaWithJsonSchemaNet -Schema $schemaObject -Instance $Instance
    }
    Test-McpJsonSchemaWithPowerShell -Schema $schemaObject -Instance $Instance
}

function Test-McpJsonSchemaWithJsonSchemaNet {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Schema,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Instance
    )

    $schemaText = ConvertTo-McpJson -InputObject $Schema
    $instanceText = ConvertTo-McpJson -InputObject $Instance
    $jsonSchema = [Json.Schema.JsonSchema]::FromText($schemaText)
    $node = [System.Text.Json.Nodes.JsonNode]::Parse($instanceText)
    $options = [Json.Schema.EvaluationOptions]::new()
    $options.OutputFormat = [Json.Schema.OutputFormat]::List
    $options.EvaluateAs = [Json.Schema.SpecVersion]::Draft202012
    $options.SchemaRegistry.Fetch = [System.Func[System.Uri, Json.Schema.IBaseDocument]] {
        param($uri)
        throw [System.InvalidOperationException]::new("Refusing to fetch the external schema '$uri'.")
    }
    $results = $null
    try {
        $results = $jsonSchema.Evaluate($node, $options)
    } catch {
        # JsonSchema.Net 7.0 (PowerShell 7.4) reports a circular reference for valid recursive schemas such as
        # the specification's JSONValue/JSONObject pair; the PowerShell engine evaluates them depth-limited.
        $message = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        if ($message -like '*circular reference*') {
            return Test-McpJsonSchemaWithPowerShell -Schema $Schema -Instance $Instance
        }
        throw
    }
    $errors = [System.Collections.Generic.List[string]]::new()
    if (-not $results.IsValid) {
        foreach ($detail in $results.Details) {
            if (-not $detail.HasErrors) { continue }
            $location = [string] $detail.InstanceLocation
            if ([string]::IsNullOrEmpty($location)) { $location = '/' } elseif (-not $location.StartsWith('/')) { $location = '/' + $location }
            foreach ($entry in $detail.Errors.GetEnumerator()) {
                $errors.Add(('{0}: {1}' -f $location, $entry.Value))
            }
        }
        if ($errors.Count -eq 0) { $errors.Add('/: the instance is not valid against the schema') }
    }
    [pscustomobject]@{
        IsValid = [bool] $results.IsValid
        Errors  = $errors.ToArray()
        Engine  = 'JsonSchemaNet'
    }
}

function Test-McpJsonSchemaWithPowerShell {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Schema,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Instance
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    Test-McpSchemaNode -Schema $Schema -Instance $Instance -Path '' -Root $Schema -Errors $errors -Depth 0
    [pscustomobject]@{
        IsValid = ($errors.Count -eq 0)
        Errors  = $errors.ToArray()
        Engine  = 'PowerShell'
    }
}

function Get-McpJsonType {
    <#
    .SYNOPSIS
        The JSON type name of a decoded value: null, boolean, integer, number, string, array or object.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool] -or $Value -is [switch]) { return 'boolean' }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [datetime] -or $Value -is [guid] -or $Value -is [uri] -or $Value -is [enum]) { return 'string' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [ulong] -or $Value -is [System.Numerics.BigInteger]) { return 'integer' }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        $number = [double] $Value
        if ([math]::Floor($number) -eq $number -and -not [double]::IsInfinity($number)) { return 'integer' }
        return 'number'
    }
    if ($Value -is [System.Collections.IDictionary]) { return 'object' }
    if ($Value -is [System.Collections.IEnumerable]) { return 'array' }
    'object'
}

function Resolve-McpSchemaReference {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string] $Reference,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Root
    )

    if ($Reference -eq '#' -or $Reference -eq '#/') { return $Root }
    if (-not $Reference.StartsWith('#/')) {
        throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "Unsupported JSON Schema reference '$Reference'.")
    }
    $current = $Root
    foreach ($segment in $Reference.Substring(2).Split('/')) {
        $key = $segment.Replace('~1', '/').Replace('~0', '~')
        $key = [System.Uri]::UnescapeDataString($key)
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($key)) {
                throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "The JSON Schema reference '$Reference' cannot be resolved.")
            }
            $current = $current[$key]
        } elseif ($current -is [System.Collections.IList]) {
            $index = 0
            if (-not [int]::TryParse($key, [ref] $index) -or $index -lt 0 -or $index -ge $current.Count) {
                throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "The JSON Schema reference '$Reference' cannot be resolved.")
            }
            $current = $current[$index]
        } else {
            throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "The JSON Schema reference '$Reference' cannot be resolved.")
        }
    }
    $current
}

function Get-McpSchemaInstanceValue {
    <#
    .SYNOPSIS
        A member of an object instance (dictionary or PSObject) without unrolling array values.
    #>
    [CmdletBinding()]
    [OutputType([object], [object[]])]
    param(
        [Parameter(Mandatory)]
        [object] $Instance,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($Instance -is [System.Collections.IDictionary]) {
        return , $Instance[$Name]
    }
    return , $Instance.PSObject.Properties[$Name].Value
}

function Test-McpSchemaValueEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Left,

        [AllowNull()]
        [object] $Right
    )

    (ConvertTo-McpJson -InputObject $Left) -ceq (ConvertTo-McpJson -InputObject $Right)
}

function Test-McpSchemaNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Schema,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Instance,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Root,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $Errors,

        [Parameter(Mandatory)]
        [int] $Depth
    )

    $location = if ($Path) { $Path } else { '/' }
    if ($Depth -gt 64) {
        $Errors.Add("${location}: schema evaluation exceeded the maximum depth")
        return
    }
    if ($Schema -is [bool]) {
        if (-not $Schema) { $Errors.Add("${location}: the schema 'false' rejects every value") }
        return
    }
    if ($Schema -isnot [System.Collections.IDictionary]) {
        return
    }
    if ($Schema.Contains('$ref')) {
        $target = Resolve-McpSchemaReference -Reference ([string] $Schema['$ref']) -Root $Root
        Test-McpSchemaNode -Schema $target -Instance $Instance -Path $Path -Root $Root -Errors $Errors -Depth ($Depth + 1)
    }

    $instanceType = Get-McpJsonType -Value $Instance

    if ($Schema.Contains('type')) {
        $allowed = @($Schema['type'])
        $typeMatches = $false
        foreach ($candidate in $allowed) {
            if ($candidate -eq $instanceType) { $typeMatches = $true }
            if ($candidate -eq 'number' -and $instanceType -eq 'integer') { $typeMatches = $true }
        }
        if (-not $typeMatches) {
            $Errors.Add(("{0}: value is '{1}' but should be '{2}'" -f $location, $instanceType, ($allowed -join ' or ')))
            return
        }
    }
    if ($Schema.Contains('enum')) {
        $found = $false
        foreach ($candidate in @($Schema['enum'])) {
            if (Test-McpSchemaValueEqual -Left $candidate -Right $Instance) { $found = $true; break }
        }
        if (-not $found) { $Errors.Add("${location}: value is not one of the allowed values") }
    }
    if ($Schema.Contains('const')) {
        if (-not (Test-McpSchemaValueEqual -Left $Schema['const'] -Right $Instance)) { $Errors.Add("${location}: value does not equal the constant") }
    }

    switch ($instanceType) {
        'string' {
            $text = [string] $Instance
            $length = [System.Globalization.StringInfo]::new($text).LengthInTextElements
            if ($Schema.Contains('minLength') -and $length -lt [int] $Schema['minLength']) { $Errors.Add("${location}: string is shorter than $($Schema['minLength']) characters") }
            if ($Schema.Contains('maxLength') -and $length -gt [int] $Schema['maxLength']) { $Errors.Add("${location}: string is longer than $($Schema['maxLength']) characters") }
            if ($Schema.Contains('pattern') -and -not [regex]::IsMatch($text, [string] $Schema['pattern'], [System.Text.RegularExpressions.RegexOptions]::ECMAScript)) { $Errors.Add("${location}: string does not match the pattern '$($Schema['pattern'])'") }
        }
        { $_ -in 'integer', 'number' } {
            $number = [double] $Instance
            if ($Schema.Contains('minimum') -and $number -lt [double] $Schema['minimum']) { $Errors.Add("${location}: $number is less than the minimum $($Schema['minimum'])") }
            if ($Schema.Contains('maximum') -and $number -gt [double] $Schema['maximum']) { $Errors.Add("${location}: $number is greater than the maximum $($Schema['maximum'])") }
            if ($Schema.Contains('exclusiveMinimum') -and $number -le [double] $Schema['exclusiveMinimum']) { $Errors.Add("${location}: $number is not greater than $($Schema['exclusiveMinimum'])") }
            if ($Schema.Contains('exclusiveMaximum') -and $number -ge [double] $Schema['exclusiveMaximum']) { $Errors.Add("${location}: $number is not less than $($Schema['exclusiveMaximum'])") }
            if ($Schema.Contains('multipleOf')) {
                $divisor = [double] $Schema['multipleOf']
                if ($divisor -gt 0) {
                    $quotient = $number / $divisor
                    if ([math]::Abs($quotient - [math]::Round($quotient)) -gt 1e-9) { $Errors.Add("${location}: $number is not a multiple of $divisor") }
                }
            }
        }
        'array' {
            $items = @($Instance)
            if ($Schema.Contains('minItems') -and $items.Count -lt [int] $Schema['minItems']) { $Errors.Add("${location}: array has fewer than $($Schema['minItems']) items") }
            if ($Schema.Contains('maxItems') -and $items.Count -gt [int] $Schema['maxItems']) { $Errors.Add("${location}: array has more than $($Schema['maxItems']) items") }
            if ($Schema.Contains('uniqueItems') -and [bool] $Schema['uniqueItems']) {
                $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                foreach ($item in $items) {
                    if (-not $seen.Add((ConvertTo-McpJson -InputObject $item))) { $Errors.Add("${location}: array items are not unique"); break }
                }
            }
            $prefixCount = 0
            if ($Schema.Contains('prefixItems')) {
                $prefix = @($Schema['prefixItems'])
                $prefixCount = $prefix.Count
                for ($i = 0; $i -lt [math]::Min($prefixCount, $items.Count); $i++) {
                    Test-McpSchemaNode -Schema $prefix[$i] -Instance $items[$i] -Path "$Path/$i" -Root $Root -Errors $Errors -Depth ($Depth + 1)
                }
            }
            if ($Schema.Contains('items')) {
                for ($i = $prefixCount; $i -lt $items.Count; $i++) {
                    Test-McpSchemaNode -Schema $Schema['items'] -Instance $items[$i] -Path "$Path/$i" -Root $Root -Errors $Errors -Depth ($Depth + 1)
                }
            }
        }
        'object' {
            $keys = @(if ($Instance -is [System.Collections.IDictionary]) { $Instance.Keys } else { $Instance.PSObject.Properties.Name })
            if ($Schema.Contains('required')) {
                foreach ($name in @($Schema['required'])) {
                    if ($name -cnotin $keys) { $Errors.Add("${location}: required property '$name' is missing") }
                }
            }
            if ($Schema.Contains('minProperties') -and $keys.Count -lt [int] $Schema['minProperties']) { $Errors.Add("${location}: object has fewer than $($Schema['minProperties']) properties") }
            if ($Schema.Contains('maxProperties') -and $keys.Count -gt [int] $Schema['maxProperties']) { $Errors.Add("${location}: object has more than $($Schema['maxProperties']) properties") }
            $declared = @{}
            if ($Schema.Contains('properties') -and $Schema['properties'] -is [System.Collections.IDictionary]) {
                foreach ($name in $Schema['properties'].Keys) {
                    $declared[[string] $name] = $true
                    if ($name -cin $keys) {
                        Test-McpSchemaNode -Schema $Schema['properties'][$name] -Instance (Get-McpSchemaInstanceValue -Instance $Instance -Name $name) -Path "$Path/$name" -Root $Root -Errors $Errors -Depth ($Depth + 1)
                    }
                }
            }
            $patternKeys = @()
            if ($Schema.Contains('patternProperties') -and $Schema['patternProperties'] -is [System.Collections.IDictionary]) {
                foreach ($pattern in $Schema['patternProperties'].Keys) {
                    foreach ($name in $keys) {
                        if ([regex]::IsMatch([string] $name, [string] $pattern, [System.Text.RegularExpressions.RegexOptions]::ECMAScript)) {
                            $patternKeys += [string] $name
                            Test-McpSchemaNode -Schema $Schema['patternProperties'][$pattern] -Instance (Get-McpSchemaInstanceValue -Instance $Instance -Name $name) -Path "$Path/$name" -Root $Root -Errors $Errors -Depth ($Depth + 1)
                        }
                    }
                }
            }
            if ($Schema.Contains('additionalProperties')) {
                $additional = $Schema['additionalProperties']
                foreach ($name in $keys) {
                    if ($declared.ContainsKey([string] $name) -or ([string] $name) -cin $patternKeys) { continue }
                    if ($additional -is [bool]) {
                        if (-not $additional) { $Errors.Add("${location}: property '$name' is not allowed") }
                    } else {
                        Test-McpSchemaNode -Schema $additional -Instance (Get-McpSchemaInstanceValue -Instance $Instance -Name $name) -Path "$Path/$name" -Root $Root -Errors $Errors -Depth ($Depth + 1)
                    }
                }
            }
        }
    }

    if ($Schema.Contains('allOf')) {
        foreach ($subschema in @($Schema['allOf'])) {
            Test-McpSchemaNode -Schema $subschema -Instance $Instance -Path $Path -Root $Root -Errors $Errors -Depth ($Depth + 1)
        }
    }
    if ($Schema.Contains('anyOf')) {
        $anyValid = $false
        foreach ($subschema in @($Schema['anyOf'])) {
            $branchErrors = [System.Collections.Generic.List[string]]::new()
            Test-McpSchemaNode -Schema $subschema -Instance $Instance -Path $Path -Root $Root -Errors $branchErrors -Depth ($Depth + 1)
            if ($branchErrors.Count -eq 0) { $anyValid = $true; break }
        }
        if (-not $anyValid) { $Errors.Add("${location}: value does not match any of the anyOf schemas") }
    }
    if ($Schema.Contains('oneOf')) {
        $validCount = 0
        foreach ($subschema in @($Schema['oneOf'])) {
            $branchErrors = [System.Collections.Generic.List[string]]::new()
            Test-McpSchemaNode -Schema $subschema -Instance $Instance -Path $Path -Root $Root -Errors $branchErrors -Depth ($Depth + 1)
            if ($branchErrors.Count -eq 0) { $validCount++ }
        }
        if ($validCount -ne 1) { $Errors.Add("${location}: value matches $validCount of the oneOf schemas instead of exactly one") }
    }
    if ($Schema.Contains('not')) {
        $branchErrors = [System.Collections.Generic.List[string]]::new()
        Test-McpSchemaNode -Schema $Schema['not'] -Instance $Instance -Path $Path -Root $Root -Errors $branchErrors -Depth ($Depth + 1)
        if ($branchErrors.Count -eq 0) { $Errors.Add("${location}: value matches the 'not' schema") }
    }
    if ($Schema.Contains('if')) {
        $conditionErrors = [System.Collections.Generic.List[string]]::new()
        Test-McpSchemaNode -Schema $Schema['if'] -Instance $Instance -Path $Path -Root $Root -Errors $conditionErrors -Depth ($Depth + 1)
        $branch = if ($conditionErrors.Count -eq 0) { 'then' } else { 'else' }
        if ($Schema.Contains($branch)) {
            Test-McpSchemaNode -Schema $Schema[$branch] -Instance $Instance -Path $Path -Root $Root -Errors $Errors -Depth ($Depth + 1)
        }
    }
}

# --- Schema generation from PowerShell parameters ---------------------------------------------------------

$script:McpExcludedParameterNames = @(
    [System.Management.Automation.PSCmdlet]::CommonParameters +
    [System.Management.Automation.PSCmdlet]::OptionalCommonParameters +
    @('Context')
)

function ConvertTo-McpSchemaTypeFragment {
    <#
    .SYNOPSIS
        The JSON Schema fragment for a .NET parameter type (type, format, items, enum).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [type] $Type,

        [int] $Depth = 0
    )

    $fragment = [ordered]@{}
    if ($Depth -gt 8) { return $fragment }
    if ($Type.IsGenericType -and $Type.GetGenericTypeDefinition() -eq [System.Nullable`1]) {
        $inner = ConvertTo-McpSchemaTypeFragment -Type $Type.GetGenericArguments()[0] -Depth ($Depth + 1)
        if ($inner.Contains('type')) { $inner['type'] = @($inner['type'], 'null') }
        return $inner
    }
    if ($Type -in @([System.Security.SecureString], [pscredential], [scriptblock])) {
        throw [System.ArgumentException]::new("Parameters of type $($Type.Name) cannot be exposed as tool arguments.")
    }
    if ($Type -eq [string] -or $Type -eq [char]) { $fragment['type'] = 'string'; return $fragment }
    if ($Type -eq [bool] -or $Type -eq [switch]) { $fragment['type'] = 'boolean'; return $fragment }
    if ($Type -in @([int], [long], [int16], [byte], [sbyte], [uint16], [uint32], [ulong], [System.Numerics.BigInteger])) { $fragment['type'] = 'integer'; return $fragment }
    if ($Type -in @([double], [single], [decimal])) { $fragment['type'] = 'number'; return $fragment }
    if ($Type -eq [datetime] -or $Type -eq [datetimeoffset]) { $fragment['type'] = 'string'; $fragment['format'] = 'date-time'; return $fragment }
    if ($Type -eq [guid]) { $fragment['type'] = 'string'; $fragment['format'] = 'uuid'; return $fragment }
    if ($Type -eq [uri]) { $fragment['type'] = 'string'; $fragment['format'] = 'uri'; return $fragment }
    if ($Type -eq [timespan] -or $Type -eq [version]) { $fragment['type'] = 'string'; return $fragment }
    if ($Type.IsEnum) { $fragment['type'] = 'string'; $fragment['enum'] = @([enum]::GetNames($Type)); return $fragment }
    if ($Type.IsArray) {
        $fragment['type'] = 'array'
        $fragment['items'] = ConvertTo-McpSchemaTypeFragment -Type $Type.GetElementType() -Depth ($Depth + 1)
        return $fragment
    }
    if ([System.Collections.IDictionary].IsAssignableFrom($Type) -or $Type -eq [psobject] -or $Type -eq [object] -or $Type -eq [System.Management.Automation.PSCustomObject]) {
        if ($Type -eq [object]) { return $fragment }
        $fragment['type'] = 'object'
        return $fragment
    }
    if ($Type.IsGenericType -and [System.Collections.IEnumerable].IsAssignableFrom($Type)) {
        $enumerable = @($Type.GetInterfaces() | Where-Object { $_.IsGenericType -and $_.GetGenericTypeDefinition() -eq [System.Collections.Generic.IEnumerable`1] }) + @($Type)
        $elementType = ($enumerable | Where-Object { $_.IsGenericType -and $_.GetGenericTypeDefinition() -eq [System.Collections.Generic.IEnumerable`1] } | Select-Object -First 1)
        $fragment['type'] = 'array'
        if ($elementType) { $fragment['items'] = ConvertTo-McpSchemaTypeFragment -Type $elementType.GetGenericArguments()[0] -Depth ($Depth + 1) }
        return $fragment
    }
    if ([System.Collections.IEnumerable].IsAssignableFrom($Type)) { $fragment['type'] = 'array'; return $fragment }
    # Any other type: accept any JSON value and let the parameter binder convert it.
    $fragment
}

function Get-McpParameterDefaultValue {
    <#
    .SYNOPSIS
        Constant default values of the parameters of a script block or function AST, keyed by parameter name.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [System.Management.Automation.Language.Ast] $Ast
    )

    $defaults = @{}
    if ($null -eq $Ast) { return $defaults }
    $paramBlock = $null
    if ($Ast -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $paramBlock = $Ast.Body.ParamBlock }
    elseif ($Ast -is [System.Management.Automation.Language.ScriptBlockAst]) { $paramBlock = $Ast.ParamBlock }
    if ($null -eq $paramBlock) { return $defaults }
    foreach ($parameter in $paramBlock.Parameters) {
        if ($null -eq $parameter.DefaultValue) { continue }
        try {
            $defaults[$parameter.Name.VariablePath.UserPath] = $parameter.DefaultValue.SafeGetValue()
        } catch {
            Write-Debug "The default value of parameter '$($parameter.Name.VariablePath.UserPath)' is not a constant; it is not part of the schema."
        }
    }
    $defaults
}

function Get-McpCommandHelp {
    <#
    .SYNOPSIS
        Synopsis, description and parameter descriptions from comment-based help of a function, script or script block.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [System.Management.Automation.Language.Ast] $Ast
    )

    $help = @{ Synopsis = $null; Description = $null; Parameters = @{} }
    if ($null -eq $Ast) { return $help }
    $content = $null
    try { $content = $Ast.GetHelpContent() } catch { $content = $null }
    if ($null -eq $content) { return $help }
    if ($content.Synopsis) { $help.Synopsis = $content.Synopsis.Trim() }
    if ($content.Description) { $help.Description = $content.Description.Trim() }
    if ($content.Parameters) {
        # CommentHelpInfo upper-cases the parameter names.
        foreach ($entry in $content.Parameters.GetEnumerator()) {
            $help.Parameters[[string] $entry.Key] = ([string] $entry.Value).Trim()
        }
    }
    $help
}

function New-McpToolInputSchema {
    <#
    .SYNOPSIS
        Builds the JSON Schema of a tool's arguments from parameter metadata, help content and default values.
    .OUTPUTS
        A hashtable with Schema (ordered dictionary) and ParameterTypes (name -> type) for typed binding.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory schema.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Parameters,

        [hashtable] $Help = @{ Parameters = @{} },

        [hashtable] $Defaults = @{},

        [switch] $AllowAdditionalProperties
    )

    $properties = [ordered]@{}
    $required = [System.Collections.Generic.List[string]]::new()
    $types = @{}
    foreach ($entry in $Parameters.GetEnumerator()) {
        $metadata = $entry.Value
        $name = [string] $metadata.Name
        if ($name -in $script:McpExcludedParameterNames) { continue }
        $property = ConvertTo-McpSchemaTypeFragment -Type $metadata.ParameterType
        $types[$name] = $metadata.ParameterType

        $description = $null
        foreach ($helpKey in $Help.Parameters.Keys) {
            if ($helpKey -ieq $name) { $description = $Help.Parameters[$helpKey] }
        }
        $mandatorySets = 0
        $sets = 0
        foreach ($attribute in $metadata.Attributes) {
            if ($attribute -is [System.Management.Automation.ParameterAttribute]) {
                $sets++
                if ($attribute.Mandatory) { $mandatorySets++ }
                if (-not $description -and $attribute.HelpMessage) { $description = $attribute.HelpMessage }
            } elseif ($attribute -is [System.Management.Automation.ValidateSetAttribute]) {
                $values = @($attribute.ValidValues)
                if ($property['type'] -eq 'integer') { $property['enum'] = @($values | ForEach-Object { [long] $_ }) }
                elseif ($property['type'] -eq 'number') { $property['enum'] = @($values | ForEach-Object { [double] $_ }) }
                else { $property['enum'] = @($values | ForEach-Object { [string] $_ }) }
            } elseif ($attribute -is [System.Management.Automation.ValidateRangeAttribute]) {
                $kind = $null
                if ($attribute.PSObject.Properties['RangeKind']) { $kind = $attribute.RangeKind }
                if ($null -ne $kind) {
                    switch ([string] $kind) {
                        'Positive' { $property['exclusiveMinimum'] = 0 }
                        'NonNegative' { $property['minimum'] = 0 }
                        'Negative' { $property['exclusiveMaximum'] = 0 }
                        'NonPositive' { $property['maximum'] = 0 }
                    }
                } else {
                    if ($null -ne $attribute.MinRange) { $property['minimum'] = $attribute.MinRange }
                    if ($null -ne $attribute.MaxRange) { $property['maximum'] = $attribute.MaxRange }
                }
            } elseif ($attribute -is [System.Management.Automation.ValidateLengthAttribute]) {
                $property['minLength'] = $attribute.MinLength
                $property['maxLength'] = $attribute.MaxLength
            } elseif ($attribute -is [System.Management.Automation.ValidatePatternAttribute]) {
                $property['pattern'] = $attribute.RegexPattern
            } elseif ($attribute -is [System.Management.Automation.ValidateCountAttribute]) {
                $property['minItems'] = $attribute.MinLength
                $property['maxItems'] = $attribute.MaxLength
            }
        }
        if ($description) { $property['description'] = $description }
        if ($Defaults.ContainsKey($name)) {
            $default = $Defaults[$name]
            if ($null -ne $default) { $property['default'] = $default }
        }
        if ($sets -gt 0 -and $mandatorySets -eq $sets) { $required.Add($name) }
        $properties[$name] = $property
    }

    $schema = [ordered]@{ type = 'object' }
    if ($properties.Count -gt 0) { $schema['properties'] = $properties }
    if ($required.Count -gt 0) { $schema['required'] = $required.ToArray() }
    if (-not $AllowAdditionalProperties) { $schema['additionalProperties'] = $false }
    @{
        Schema         = $schema
        ParameterTypes = $types
    }
}
