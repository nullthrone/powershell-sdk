# Argument completion (completion/complete) for prompt arguments and resource template variables: completion
# sources registered with -Completion (value lists filtered by prefix, or handlers), request validation and
# the CompleteResult with its 100-value cap.

$script:McpCompletionMaxValues = 100

function ConvertTo-McpCompletionSource {
    <#
    .SYNOPSIS
        Normalises a -Completion table (argument name -> value list or script block) to completion sources.
    .OUTPUTS
        An ordinal ordered dictionary of argument name -> @{ Values } or @{ Handler }.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $Completion,

        # The argument (or template variable) names that may be completed.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $ArgumentNames,

        # Identifies the owner (prompt name or URI template) in the worker function names of handlers.
        [Parameter(Mandatory)]
        [string] $Key
    )

    $sources = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    if ($null -eq $Completion) { return $sources }
    foreach ($name in $Completion.Keys) {
        $argumentName = [string] $name
        if ($ArgumentNames -cnotcontains $argumentName) {
            throw [System.ArgumentException]::new("Completion given for '$argumentName', which is not one of the arguments ($($ArgumentNames -join ', ')).")
        }
        $value = $Completion[$name]
        if ($value -is [scriptblock]) {
            $sources[$argumentName] = @{ Values = $null; Handler = (New-McpHandlerDescriptor -Prefix 'McpCompletion' -Key "$Key|$argumentName" -ScriptBlock $value).Handler }
        } elseif ($value -is [System.Management.Automation.CommandInfo]) {
            $sources[$argumentName] = @{ Values = $null; Handler = (New-McpHandlerDescriptor -Prefix 'McpCompletion' -Key "$Key|$argumentName" -CommandInfo $value).Handler }
        } else {
            $sources[$argumentName] = @{ Values = [string[]] @($value | Where-Object { $null -ne $_ } | ForEach-Object { [string] $_ }); Handler = $null }
        }
    }
    $sources
}

function Test-McpCompletionCapability {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server
    )

    foreach ($registration in @($Server.Prompts.Values) + @($Server.ResourceTemplates.Values)) {
        if ($null -ne $registration.Completion -and $registration.Completion.Count -gt 0) { return $true }
    }
    $false
}

function Resolve-McpCompletionRequest {
    <#
    .SYNOPSIS
        Validates completion/complete params and finds the completion source of the referenced argument.
    .OUTPUTS
        A hashtable with Name (the argument), Value, Arguments (context.arguments), Source (or $null) and Label.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [AllowNull()]
        [System.Collections.IDictionary] $Params
    )

    $invalid = { param($message) [McpProtocolException]::new($script:McpErrorCode.InvalidParams, $message) }
    if ($null -eq $Params -or $Params['ref'] -isnot [System.Collections.IDictionary]) { throw (& $invalid "completion/complete requires an object parameter 'ref'.") }
    $argument = $Params['argument']
    if ($argument -isnot [System.Collections.IDictionary] -or $argument['name'] -isnot [string] -or $argument['value'] -isnot [string]) {
        throw (& $invalid "completion/complete requires 'argument' with string members 'name' and 'value'.")
    }
    $contextArguments = [ordered]@{}
    if ($Params.Contains('context') -and $null -ne $Params['context']) {
        $context = $Params['context']
        if ($context -isnot [System.Collections.IDictionary]) { throw (& $invalid "completion/complete 'context' must be an object.") }
        if ($context.Contains('arguments') -and $null -ne $context['arguments']) {
            if ($context['arguments'] -isnot [System.Collections.IDictionary]) { throw (& $invalid "completion/complete 'context.arguments' must be an object.") }
            foreach ($key in $context['arguments'].Keys) {
                if ($context['arguments'][$key] -isnot [string]) { throw (& $invalid "The value of context argument '$key' must be a string.") }
                $contextArguments[[string] $key] = $context['arguments'][$key]
            }
        }
    }

    $reference = $Params['ref']
    $name = $argument['name']
    switch ($reference['type']) {
        'ref/prompt' {
            $registration = Get-McpPromptRegistration -Server $Server -Name $reference['name']
            if (@($registration.Arguments | ForEach-Object { $_['name'] }) -cnotcontains $name) {
                throw (& $invalid "Prompt '$($registration.Name)' has no argument '$name'.")
            }
            $label = "prompt $($registration.Name)"
        }
        'ref/resource' {
            $uri = $reference['uri']
            $registration = $null
            if ($uri -is [string]) {
                $registration = @($Server.ResourceTemplates.Values | Where-Object { $_.UriTemplate -ceq $uri }) | Select-Object -First 1
            }
            if ($null -eq $registration) { throw (& $invalid "Unknown resource template '$uri'.") }
            if ($registration.Template.Variables -cnotcontains $name) {
                throw (& $invalid "Resource template '$uri' has no variable '$name'.")
            }
            $label = "template $uri"
        }
        default {
            throw (& $invalid "Unknown completion reference type '$($reference['type'])'; expected ref/prompt or ref/resource.")
        }
    }
    $source = $null
    if ($null -ne $registration.Completion -and $registration.Completion.Contains($name)) { $source = $registration.Completion[$name] }
    @{
        Name      = $name
        Value     = $argument['value']
        Arguments = $contextArguments
        Source    = $source
        Label     = "$label/$name"
    }
}

function Get-McpCompleteResult {
    <#
    .SYNOPSIS
        The CompleteResult for a list of candidate values: at most 100 values, the total and hasMore.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Values
    )

    $all = @($Values | Where-Object { $null -ne $_ })
    $page = if ($all.Count -gt $script:McpCompletionMaxValues) { $all[0..($script:McpCompletionMaxValues - 1)] } else { $all }
    [ordered]@{
        completion = [ordered]@{
            values  = [string[]] @($page)
            total   = [long] $all.Count
            hasMore = $all.Count -gt $script:McpCompletionMaxValues
        }
        resultType = 'complete'
    }
}

function Get-McpStaticCompletion {
    <#
    .SYNOPSIS
        The values of a value list that start with the typed value (case-insensitive).
    #>
    [CmdletBinding()]
    [OutputType([string[]], [System.Array])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Values,

        [AllowEmptyString()]
        [string] $Value = ''
    )

    , [string[]] @($Values | Where-Object { $_.StartsWith($Value, [System.StringComparison]::OrdinalIgnoreCase) })
}

function Invoke-McpCompletionHandler {
    <#
    .SYNOPSIS
        Runs a completion handler and returns its CompleteResult.
    .DESCRIPTION
        The handler receives the parameters it declares of: Value (the typed text), Argument (the argument
        name), Arguments (the already resolved arguments of context.arguments) and Context. Its string output
        is the candidate list, returned as is (the handler filters).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Request,

        [AllowNull()]
        [object] $Context,

        [switch] $UseCommandName
    )

    $source = $Request.Source
    if ($null -eq $source) { return Get-McpCompleteResult -Values @() }
    if ($null -eq $source.Handler) { return Get-McpCompleteResult -Values (Get-McpStaticCompletion -Values $source.Values -Value $Request.Value) }
    $values = [ordered]@{ Value = $Request.Value; Argument = $Request.Name; Arguments = $Request.Arguments }
    $splat = New-McpHandlerSplat -Handler $source.Handler -Values $values -Context $Context
    $threshold = if ($null -ne $Context -and $null -ne $Context.ServerLogLevel) { $Context.ServerLogLevel } else { $script:McpDefaultLogLevel }
    try {
        $merged = @(Invoke-McpHandlerCommand -Handler $source.Handler -Splat $splat -UseCommandName:$UseCommandName)
    } catch [System.Management.Automation.PipelineStoppedException] {
        throw
    } catch {
        $exception = Get-McpHandlerException -Exception $_.Exception
        if ($exception -is [McpProtocolException]) { throw $exception }
        throw [McpProtocolException]::new($script:McpErrorCode.InternalError, "Completion of $($Request.Label) failed: $($exception.Message)")
    }
    $parts = Split-McpHandlerOutput -Merged $merged
    Write-McpHandlerDiagnostic -Diagnostics $parts.Diagnostics -Name $Request.Label -Threshold $threshold -Context $Context -ErrorRecords $parts.Errors
    Get-McpCompleteResult -Values @($parts.Output | ForEach-Object { [string] $_ })
}
