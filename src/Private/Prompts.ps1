# Prompt registry: registrations (PSTypeName Mcp.PromptRegistration), the Prompt definitions of prompts/list,
# argument validation of prompts/get and the shaping of handler output into GetPromptResult.

function Get-McpPromptRegistration {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Name
    )

    if ($Name -isnot [string] -or -not $Server.Prompts.Contains([string] $Name)) {
        throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "Unknown prompt '$Name'.")
    }
    $Server.Prompts[[string] $Name]
}

function ConvertTo-McpPromptDefinition {
    <#
    .SYNOPSIS
        The Prompt object (as sent in prompts/list) of a registration.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Registration
    )

    $prompt = [ordered]@{ name = $Registration.Name }
    if ($Registration.Title) { $prompt['title'] = $Registration.Title }
    if ($Registration.Description) { $prompt['description'] = $Registration.Description }
    if (@($Registration.Arguments).Count -gt 0) { $prompt['arguments'] = @($Registration.Arguments) }
    if ($null -ne $Registration.Icons) { $prompt['icons'] = @($Registration.Icons) }
    if ($null -ne $Registration.Meta) { $prompt['_meta'] = $Registration.Meta }
    $prompt
}

function Get-McpPromptListResult {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [AllowNull()]
        [object] $Cursor
    )

    Get-McpPagedListResult -Server $Server -Kind 'prompts' -Items @($Server.Prompts.Values) -Cursor $Cursor -Converter { param($registration) ConvertTo-McpPromptDefinition -Registration $registration }
}

function ConvertTo-McpPromptArgumentList {
    <#
    .SYNOPSIS
        Normalises prompt arguments given as hashtables (Name, Title, Description, Required) to PromptArgument wire objects.
    #>
    [CmdletBinding()]
    [OutputType([object[]], [System.Array])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Arguments
    )

    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $list = foreach ($argument in @($Arguments)) {
        if ($null -eq $argument) { continue }
        if ($argument -is [string]) { $argument = @{ name = $argument } }
        $wire = [ordered]@{}
        foreach ($entry in Get-McpDictionaryValue -InputObject $argument) {
            switch (([string] $entry.Key).ToLowerInvariant()) {
                'name' { $wire['name'] = [string] $entry.Value }
                'title' { if ($entry.Value) { $wire['title'] = [string] $entry.Value } }
                'description' { if ($entry.Value) { $wire['description'] = [string] $entry.Value } }
                'required' { $wire['required'] = [bool] $entry.Value }
                default { throw [System.ArgumentException]::new("Unknown prompt argument member '$($entry.Key)'; arguments have Name, Title, Description and Required.") }
            }
        }
        if (-not $wire['name']) { throw [System.ArgumentException]::new('Every prompt argument needs a Name.') }
        if (-not $names.Add($wire['name'])) { throw [System.ArgumentException]::new("The prompt argument '$($wire['name'])' is declared more than once.") }
        $ordered = [ordered]@{ name = $wire['name'] }
        foreach ($key in 'title', 'description', 'required') {
            if ($wire.Contains($key)) { $ordered[$key] = $wire[$key] }
        }
        $ordered
    }
    , @($list)
}

function Test-McpPromptArgument {
    <#
    .SYNOPSIS
        Validates the arguments of a prompts/get request: an object of strings with every required argument.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Registration,

        [AllowNull()]
        [object] $Arguments
    )

    $values = [ordered]@{}
    if ($null -ne $Arguments) {
        if ($Arguments -isnot [System.Collections.IDictionary]) {
            throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "prompts/get 'arguments' must be an object.")
        }
        foreach ($key in $Arguments.Keys) {
            $value = $Arguments[$key]
            if ($value -isnot [string]) {
                throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "The value of prompt argument '$key' must be a string.")
            }
            $values[[string] $key] = $value
        }
    }
    $missing = @($Registration.Arguments | Where-Object { $_.Contains('required') -and $_['required'] -and -not $values.Contains($_['name']) } | ForEach-Object { $_['name'] })
    if ($missing.Count -gt 0) {
        throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "Missing required argument(s) of prompt '$($Registration.Name)': $($missing -join ', ').", [ordered]@{ missing = $missing })
    }
    $values
}

function ConvertTo-McpGetPromptResult {
    <#
    .SYNOPSIS
        Shapes the output of a prompt handler into a GetPromptResult.
    .DESCRIPTION
        New-McpPromptMessage objects pass through; content blocks (New-McpContent) become user messages;
        consecutive strings become one user text message; other objects become a user message with their JSON.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Output,

        [Parameter(Mandatory)]
        [pscustomobject] $Registration
    )

    $messages = [System.Collections.Generic.List[object]]::new()
    $texts = [System.Collections.Generic.List[string]]::new()
    $flush = {
        if ($texts.Count -gt 0) {
            $messages.Add([ordered]@{ role = 'user'; content = (ConvertTo-McpTextBlock -Text ($texts -join "`n")) })
            $texts.Clear()
        }
    }
    foreach ($item in @($Output | Where-Object { $null -ne $_ })) {
        if ($item.PSObject.TypeNames -contains 'Mcp.PromptMessage') {
            . $flush
            $messages.Add($item)
        } elseif ($item -is [System.Collections.IDictionary] -and $item.Contains('role') -and $item.Contains('content')) {
            . $flush
            $messages.Add($item)
        } elseif (Test-McpContentObject -Value $item) {
            . $flush
            $messages.Add([ordered]@{ role = 'user'; content = $item })
        } elseif ($item -is [string]) {
            $texts.Add($item)
        } elseif ($item -is [valuetype] -or $item -is [enum] -or $item -is [uri] -or $item -is [version]) {
            $texts.Add([System.Management.Automation.LanguagePrimitives]::ConvertTo($item, [string]))
        } else {
            . $flush
            $messages.Add([ordered]@{ role = 'user'; content = (ConvertTo-McpTextBlock -Text (ConvertTo-McpJson -InputObject $item)) })
        }
    }
    . $flush
    $result = [ordered]@{}
    if ($Registration.Description) { $result['description'] = $Registration.Description }
    $result['messages'] = $messages.ToArray()
    $result['resultType'] = 'complete'
    $result
}

function Invoke-McpPromptHandler {
    <#
    .SYNOPSIS
        Runs a prompt handler with validated string arguments and returns its GetPromptResult.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Registration,

        [System.Collections.IDictionary] $Arguments = [ordered]@{},

        [AllowNull()]
        [object] $Context,

        [switch] $UseCommandName
    )

    $handler = $Registration.Handler
    if ($handler.ArgumentStyle -eq 'Arguments') {
        $splat = @{ Arguments = $Arguments }
        if ($handler.ContextParameter -and $null -ne $Context) { $splat[$handler.ContextParameter] = $Context }
    } else {
        $splat = New-McpHandlerSplat -Handler $handler -Values $Arguments -Context $Context
    }
    $threshold = if ($null -ne $Context -and $null -ne $Context.ServerLogLevel) { $Context.ServerLogLevel } else { $script:McpDefaultLogLevel }
    try {
        $merged = @(Invoke-McpHandlerCommand -Handler $handler -Splat $splat -UseCommandName:$UseCommandName)
    } catch [System.Management.Automation.PipelineStoppedException] {
        throw
    } catch {
        $exception = Get-McpHandlerException -Exception $_.Exception
        if ($exception -is [McpProtocolException]) { throw $exception }
        throw [McpProtocolException]::new($script:McpErrorCode.InternalError, "Prompt '$($Registration.Name)' failed: $($exception.Message)")
    }
    $parts = Split-McpHandlerOutput -Merged $merged
    Write-McpHandlerDiagnostic -Diagnostics $parts.Diagnostics -Name $Registration.Name -Threshold $threshold -Context $Context -ErrorRecords $parts.Errors
    $result = ConvertTo-McpGetPromptResult -Output $parts.Output -Registration $Registration
    if ($result['messages'].Count -eq 0 -and $parts.Errors.Count -gt 0) {
        throw [McpProtocolException]::new($script:McpErrorCode.InternalError, "Prompt '$($Registration.Name)' failed: $($parts.Errors[0].ToString())")
    }
    $result
}
