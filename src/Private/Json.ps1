# JSON codec on System.Text.Json (in-box in every supported PowerShell version).
#
# ConvertFrom-McpJson parses one JSON text into plain PowerShell values: objects become insertion-ordered,
# case-sensitive OrderedDictionary instances, arrays become object[], strings stay strings, numbers become
# Int64 when they are integral and fit and Double otherwise, and null stays $null. Nothing is coerced (no
# DateTime detection, no single-element array unrolling), so the wire shape survives a round trip and the
# JSON type of a request id (string versus number) is preserved.
#
# ConvertTo-McpJson serialises PowerShell values to compact, single-line JSON: dictionaries and PSObjects
# become objects (insertion or property order), enumerables become arrays, [switch] becomes a boolean,
# byte[] becomes base64, DateTime becomes ISO 8601 in round-trip format, enums and Guid/Uri/Version become
# strings. Non-ASCII characters of the basic multilingual plane are written unescaped (UTF-8 on the wire);
# characters outside it (emoji) are written as surrogate-pair escapes because System.Text.Json encoders
# always escape them; control characters are escaped, so the output never contains a raw newline. Depth
# beyond -MaxDepth is an error, never a truncation.

$script:McpJsonWriterOptions = [System.Text.Json.JsonWriterOptions]@{
    Indented       = $false
    Encoder        = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
    SkipValidation = $false
}

function ConvertFrom-McpJson {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [string] $Json,

        [ValidateRange(1, 1024)]
        [int] $MaxDepth = 64
    )

    process {
        $options = [System.Text.Json.JsonDocumentOptions]@{
            MaxDepth        = $MaxDepth
            CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
        }
        $document = [System.Text.Json.JsonDocument]::Parse($Json, $options)
        try {
            ConvertFrom-McpJsonElement -Element $document.RootElement
        } finally {
            $document.Dispose()
        }
    }
}

function ConvertFrom-McpJsonElement {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary], [object[]], [string], [long], [double], [bool])]
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Element
    )

    $kind = $Element.ValueKind
    if ($kind -eq [System.Text.Json.JsonValueKind]::Object) {
        $dictionary = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            $dictionary[$property.Name] = ConvertFrom-McpJsonElement -Element $property.Value
        }
        return $dictionary
    }
    if ($kind -eq [System.Text.Json.JsonValueKind]::Array) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Element.EnumerateArray()) {
            $items.Add((ConvertFrom-McpJsonElement -Element $item))
        }
        return , $items.ToArray()
    }
    if ($kind -eq [System.Text.Json.JsonValueKind]::String) {
        return $Element.GetString()
    }
    if ($kind -eq [System.Text.Json.JsonValueKind]::Number) {
        $integer = [long] 0
        if ($Element.TryGetInt64([ref] $integer)) {
            return $integer
        }
        return $Element.GetDouble()
    }
    if ($kind -eq [System.Text.Json.JsonValueKind]::True) {
        return $true
    }
    if ($kind -eq [System.Text.Json.JsonValueKind]::False) {
        return $false
    }
    return $null
}

function ConvertTo-McpJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        [object] $InputObject,

        [ValidateRange(1, 1024)]
        [int] $MaxDepth = 64
    )

    $stream = [System.IO.MemoryStream]::new()
    $writer = [System.Text.Json.Utf8JsonWriter]::new($stream, $script:McpJsonWriterOptions)
    try {
        Write-McpJsonValue -Writer $writer -Value $InputObject -Depth 0 -MaxDepth $MaxDepth
        $writer.Flush()
        [System.Text.Encoding]::UTF8.GetString($stream.GetBuffer(), 0, [int] $stream.Length)
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function Write-McpJsonValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.Utf8JsonWriter] $Writer,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [int] $Depth,

        [Parameter(Mandatory)]
        [int] $MaxDepth
    )

    if ($null -eq $Value) {
        $Writer.WriteNullValue()
        return
    }
    if ($Value -is [string]) {
        $Writer.WriteStringValue([string] $Value)
        return
    }
    if ($Value -is [bool]) {
        $Writer.WriteBooleanValue([bool] $Value)
        return
    }
    if ($Value -is [switch]) {
        $Writer.WriteBooleanValue($Value.IsPresent)
        return
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [uint16] -or $Value -is [uint32]) {
        $Writer.WriteNumberValue([long] $Value)
        return
    }
    if ($Value -is [ulong]) {
        $Writer.WriteNumberValue([ulong] $Value)
        return
    }
    if ($Value -is [double] -or $Value -is [single]) {
        $number = [double] $Value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
            throw [System.InvalidOperationException]::new("The value '$number' has no JSON representation.")
        }
        $Writer.WriteNumberValue($number)
        return
    }
    if ($Value -is [decimal]) {
        $Writer.WriteNumberValue([decimal] $Value)
        return
    }
    if ($Value -is [System.Numerics.BigInteger]) {
        $Writer.WriteRawValue($Value.ToString(), $true)
        return
    }
    if ($Value -is [datetime]) {
        $Writer.WriteStringValue(([datetime] $Value).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture))
        return
    }
    if ($Value -is [datetimeoffset]) {
        $Writer.WriteStringValue(([datetimeoffset] $Value).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture))
        return
    }
    if ($Value -is [enum] -or $Value -is [guid] -or $Value -is [uri] -or $Value -is [version] -or $Value -is [char] -or $Value -is [timespan]) {
        $Writer.WriteStringValue($Value.ToString())
        return
    }
    if ($Value -is [byte[]]) {
        $Writer.WriteBase64StringValue([byte[]] $Value)
        return
    }
    if ($Value -is [System.Text.Json.Nodes.JsonNode]) {
        $Value.WriteTo($Writer)
        return
    }
    if ($Value -is [System.Text.Json.JsonElement]) {
        $Value.WriteTo($Writer)
        return
    }
    if ($Depth -ge $MaxDepth) {
        throw [System.InvalidOperationException]::new("The object graph is deeper than the maximum depth of $MaxDepth.")
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $Writer.WriteStartObject()
        foreach ($key in $Value.Keys) {
            $Writer.WritePropertyName([string] $key)
            Write-McpJsonValue -Writer $Writer -Value $Value[$key] -Depth ($Depth + 1) -MaxDepth $MaxDepth
        }
        $Writer.WriteEndObject()
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $Writer.WriteStartArray()
        foreach ($item in $Value) {
            Write-McpJsonValue -Writer $Writer -Value $item -Depth ($Depth + 1) -MaxDepth $MaxDepth
        }
        $Writer.WriteEndArray()
        return
    }
    # PSCustomObject and any other object: its (adapted and extended) properties, in order.
    $Writer.WriteStartObject()
    foreach ($property in $Value.PSObject.Properties) {
        $Writer.WritePropertyName($property.Name)
        Write-McpJsonValue -Writer $Writer -Value $property.Value -Depth ($Depth + 1) -MaxDepth $MaxDepth
    }
    $Writer.WriteEndObject()
}
