# Tool registry: registrations (PSTypeName Mcp.ToolRegistration), the Tool definitions of tools/list, cursor
# pagination, typed argument binding and the shaping of handler output into CallToolResult.

$script:McpToolNamePattern = '^[A-Za-z0-9_.-]{1,128}$'
$script:McpContentTypes = @('text', 'image', 'audio', 'resource_link', 'resource')

function Get-McpToolRegistration {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Name
    )

    if ($Name -isnot [string] -or -not $Server.Tools.Contains([string] $Name)) {
        throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "Unknown tool '$Name'.")
    }
    $Server.Tools[[string] $Name]
}

function ConvertTo-McpToolDefinition {
    <#
    .SYNOPSIS
        The Tool object (as sent in tools/list) of a registration.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Registration
    )

    $tool = [ordered]@{ name = $Registration.Name }
    if ($Registration.Title) { $tool['title'] = $Registration.Title }
    if ($Registration.Description) { $tool['description'] = $Registration.Description }
    $tool['inputSchema'] = $Registration.InputSchema
    if ($null -ne $Registration.OutputSchema) { $tool['outputSchema'] = $Registration.OutputSchema }
    if ($null -ne $Registration.Annotations -and $Registration.Annotations.Count -gt 0) { $tool['annotations'] = $Registration.Annotations }
    if ($null -ne $Registration.Icons -and @($Registration.Icons).Count -gt 0) { $tool['icons'] = @($Registration.Icons) }
    if ($null -ne $Registration.Meta -and $Registration.Meta.Count -gt 0) { $tool['_meta'] = $Registration.Meta }
    $tool
}

function ConvertTo-McpAnnotationObject {
    <#
    .SYNOPSIS
        Normalises ToolAnnotations given with PowerShell-style keys (ReadOnlyHint) to the wire keys (readOnlyHint).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $Annotations
    )

    $result = [ordered]@{}
    if ($null -eq $Annotations) { return $result }
    $known = @{ title = 'title'; readonlyhint = 'readOnlyHint'; destructivehint = 'destructiveHint'; idempotenthint = 'idempotentHint'; openworldhint = 'openWorldHint' }
    foreach ($key in $Annotations.Keys) {
        $lower = ([string] $key).ToLowerInvariant()
        $wireKey = if ($known.ContainsKey($lower)) { $known[$lower] } else { [string] $key }
        $value = $Annotations[$key]
        if ($wireKey -ne 'title' -and $known.ContainsKey($lower)) { $value = [bool] $value }
        $result[$wireKey] = $value
    }
    $result
}

function New-McpCursor {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Encodes a value.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [int] $Offset
    )

    [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("mcp-cursor:offset=$Offset"))
}

function Read-McpCursor {
    [CmdletBinding()]
    [OutputType([int])]
    param(
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
        if ($null -ne $text -and $text -match '^mcp-cursor:offset=(\d{1,9})$') { return [int] $Matches[1] }
    }
    throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, 'Invalid cursor.')
}

function Get-McpToolListResult {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [AllowNull()]
        [object] $Cursor
    )

    $offset = Read-McpCursor -Cursor $Cursor
    $registrations = @($Server.Tools.Values)
    if ($offset -gt $registrations.Count) {
        throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, 'Invalid cursor.')
    }
    $pageSize = [int] $Server.Options.PageSize
    $page = @()
    if ($offset -lt $registrations.Count) {
        $end = [math]::Min($offset + $pageSize, $registrations.Count) - 1
        $page = @($registrations[$offset..$end] | ForEach-Object { ConvertTo-McpToolDefinition -Registration $_ })
    }
    $result = [ordered]@{
        resultType = 'complete'
        tools      = $page
    }
    if ($offset + $pageSize -lt $registrations.Count) {
        $result['nextCursor'] = New-McpCursor -Offset ($offset + $pageSize)
    }
    $result['ttlMs'] = [long] $Server.Options.DefaultTtlMs
    $result['cacheScope'] = $Server.Options.DefaultCacheScope
    Add-McpResultMeta -Result $result -Server $Server
}

function ConvertTo-McpToolArgument {
    <#
    .SYNOPSIS
        Binds validated JSON arguments to the handler's parameters: a splatting table with converted values.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Registration,

        [AllowNull()]
        [System.Collections.IDictionary] $Arguments,

        [AllowNull()]
        [object] $Context
    )

    $handler = $Registration.Handler
    $splat = @{}
    if ($handler.ArgumentStyle -eq 'Arguments') {
        $splat['Arguments'] = if ($null -ne $Arguments) { $Arguments } else { [ordered]@{} }
    } elseif ($null -ne $Arguments) {
        $types = $handler.ParameterTypes
        foreach ($key in $Arguments.Keys) {
            $name = [string] $key
            $parameterName = $null
            if ($types.ContainsKey($name)) {
                $parameterName = $name
            } else {
                foreach ($candidate in $types.Keys) {
                    if ($candidate -ieq $name) { $parameterName = $candidate; break }
                }
            }
            $value = $Arguments[$key]
            if ($null -eq $parameterName) {
                $splat[$name] = $value
                continue
            }
            $splat[$parameterName] = ConvertTo-McpParameterValue -Value $value -Type $types[$parameterName] -Name $parameterName
        }
    }
    if ($handler.ContextParameter -and $null -ne $Context) {
        $splat[$handler.ContextParameter] = $Context
    }
    $splat
}

function ConvertTo-McpParameterValue {
    [CmdletBinding()]
    [OutputType([object], [switch], [hashtable])]
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [type] $Type,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $Value) { return $null }
    if ($Type -eq [object] -or $Type -eq [psobject]) { return $Value }
    if ($Type -eq [switch]) { return [switch] ([bool] $Value) }
    if ($Type -eq [hashtable] -and $Value -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $Value.Keys) { $table[[string] $key] = $Value[$key] }
        return $table
    }
    try {
        return [System.Management.Automation.LanguagePrimitives]::ConvertTo($Value, $Type)
    } catch {
        throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "Argument '$Name' cannot be converted to $($Type.Name): $($_.Exception.Message)")
    }
}

function Test-McpContentObject {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) { return $false }
    if ($Value.PSObject.TypeNames -contains 'Mcp.Content') { return $true }
    if ($Value -is [System.Collections.IDictionary] -and $Value.Contains('type') -and $Value['type'] -in $script:McpContentTypes) { return $true }
    $false
}

function ConvertTo-McpTextBlock {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    [ordered]@{ type = 'text'; text = $Text }
}

function ConvertTo-McpCallToolResult {
    <#
    .SYNOPSIS
        Shapes handler output into a CallToolResult.
    .DESCRIPTION
        A single Mcp.ToolResult (New-McpToolResult) is taken as is. Otherwise content blocks pass through,
        strings and primitives become text blocks, and other objects become JSON text blocks; a single object
        also becomes structuredContent. Non-terminating errors of the handler are appended as text and mark
        the result as an error. When the tool declares an outputSchema, structuredContent is required and
        validated against it.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Output,

        [Parameter(Mandatory)]
        [pscustomobject] $Registration,

        [AllowNull()]
        [AllowEmptyCollection()]
        [System.Management.Automation.ErrorRecord[]] $ErrorRecords
    )

    $content = [System.Collections.Generic.List[object]]::new()
    $structured = $null
    $hasStructured = $false
    $isError = $false
    $meta = $null
    $items = @($Output | Where-Object { $null -ne $_ })

    if ($items.Count -eq 1 -and $items[0].PSObject.TypeNames -contains 'Mcp.ToolResult') {
        $given = $items[0]
        foreach ($block in @($given.content)) { $content.Add($block) }
        if ($given.PSObject.Properties['structuredContent'] -and $null -ne $given.structuredContent) { $structured = $given.structuredContent; $hasStructured = $true }
        if ($given.PSObject.Properties['isError'] -and $given.isError) { $isError = $true }
        if ($given.PSObject.Properties['_meta'] -and $null -ne $given._meta) { $meta = $given._meta }
    } else {
        $objects = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $items) {
            if (Test-McpContentObject -Value $item) {
                $content.Add($item)
            } elseif ($item -is [string]) {
                $content.Add((ConvertTo-McpTextBlock -Text $item))
            } elseif ($item -is [bool] -or $item -is [switch]) {
                $content.Add((ConvertTo-McpTextBlock -Text ([bool] $item).ToString().ToLowerInvariant()))
            } elseif ($item -is [valuetype] -or $item -is [enum] -or $item -is [uri] -or $item -is [version]) {
                $content.Add((ConvertTo-McpTextBlock -Text ([System.Management.Automation.LanguagePrimitives]::ConvertTo($item, [string]))))
            } else {
                $objects.Add($item)
            }
        }
        if ($objects.Count -eq 1 -and ($objects[0] -is [System.Collections.IDictionary] -or $objects[0] -is [System.Management.Automation.PSCustomObject] -or $objects[0] -isnot [System.Collections.IEnumerable])) {
            $structured = $objects[0]
            $hasStructured = $true
            $content.Add((ConvertTo-McpTextBlock -Text (ConvertTo-McpJson -InputObject $structured)))
        } else {
            foreach ($object in $objects) {
                $content.Add((ConvertTo-McpTextBlock -Text (ConvertTo-McpJson -InputObject $object)))
            }
        }
    }

    foreach ($record in @($ErrorRecords | Where-Object { $null -ne $_ })) {
        $content.Add((ConvertTo-McpTextBlock -Text ('Error: ' + $record.ToString())))
        $isError = $true
    }

    if ($null -ne $Registration.OutputSchema -and -not $isError) {
        if (-not $hasStructured) {
            $content.Add((ConvertTo-McpTextBlock -Text "Error: the tool '$($Registration.Name)' declares an output schema but returned no structured content."))
            $isError = $true
        } else {
            $validation = Test-McpJsonSchema -Schema $Registration.OutputSchema -Instance $structured
            if (-not $validation.IsValid) {
                $content.Add((ConvertTo-McpTextBlock -Text ("Error: the structured content of tool '{0}' does not match its output schema: {1}" -f $Registration.Name, ($validation.Errors -join '; '))))
                $isError = $true
            }
        }
    }

    $result = [ordered]@{ content = $content.ToArray() }
    if ($hasStructured) { $result['structuredContent'] = $structured }
    if ($isError) { $result['isError'] = $true }
    $result['resultType'] = 'complete'
    if ($null -ne $meta) { $result['_meta'] = $meta }
    $result
}

function Split-McpHandlerOutput {
    <#
    .SYNOPSIS
        Separates merged handler output into output objects, error records and diagnostic records.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Merged
    )

    $output = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[System.Management.Automation.ErrorRecord]]::new()
    $diagnostics = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Merged)) {
        if ($item -is [System.Management.Automation.ErrorRecord]) { $errors.Add($item) }
        elseif ($item -is [System.Management.Automation.WarningRecord] -or $item -is [System.Management.Automation.VerboseRecord] -or $item -is [System.Management.Automation.DebugRecord] -or $item -is [System.Management.Automation.InformationRecord]) { $diagnostics.Add($item) }
        else { $output.Add($item) }
    }
    @{
        Output      = $output.ToArray()
        Errors      = $errors.ToArray()
        Diagnostics = $diagnostics.ToArray()
    }
}

function Write-McpHandlerDiagnostic {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Diagnostics,

        [Parameter(Mandatory)]
        [string] $ToolName,

        [object] $Threshold = $script:McpDefaultLogLevel
    )

    foreach ($record in @($Diagnostics)) {
        $level = switch ($record) {
            { $_ -is [System.Management.Automation.WarningRecord] } { [McpLoggingLevel]::Warning }
            { $_ -is [System.Management.Automation.VerboseRecord] } { [McpLoggingLevel]::Debug }
            { $_ -is [System.Management.Automation.DebugRecord] } { [McpLoggingLevel]::Debug }
            default { [McpLoggingLevel]::Info }
        }
        $text = if ($record -is [System.Management.Automation.InformationRecord]) { [string] $record.MessageData } else { $record.Message }
        Write-McpStderr -Level $level -Threshold $Threshold -Logger $ToolName -Message $text
    }
}
