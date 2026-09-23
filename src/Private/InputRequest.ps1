# Input requests of multi-round-trip requests (MRTR): the shared flow behind Request-McpElicitation,
# Request-McpSampling and Request-McpRoot (answer present -> validate and return it; otherwise check the
# client capability, record the request and throw McpInputRequiredException), the validation of elicitation
# schemas and of the client's answers, and the InputRequiredResult the worker builds from the exception.

$script:McpElicitationStringFormats = @('email', 'uri', 'date', 'date-time')

function Test-McpContextInput {
    <#
    .SYNOPSIS
        Throws unless the context belongs to a request that can ask for input (a handler of tools/call, prompts/get or resources/read).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Context
    )

    if ($null -eq $Context -or -not $Context.PSObject.Properties['PendingInput'] -or $null -eq $Context.PendingInput) {
        throw [System.InvalidOperationException]::new('Input requests need the request context of a tools/call, prompts/get or resources/read handler (its Context parameter).')
    }
}

function Test-McpElicitationFormCapability {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Capabilities
    )

    if (-not (Test-McpCapabilityPath -Capabilities $Capabilities -Path 'elicitation')) { return $false }
    $elicitation = $Capabilities['elicitation']
    # An empty elicitation object means form mode only; with modes listed, form must be one of them.
    if ($elicitation -isnot [System.Collections.IDictionary] -or $elicitation.Count -eq 0) { return $true }
    $elicitation.Contains('form')
}

function Assert-McpInputCapability {
    <#
    .SYNOPSIS
        Throws -32021 with data.requiredCapabilities when the client did not declare what an input request needs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Context,

        [Parameter(Mandatory)]
        [ValidateSet('elicitation.form', 'elicitation.url', 'sampling', 'sampling.tools', 'sampling.context', 'roots')]
        [string] $Capability
    )

    $capabilities = $Context.ClientCapabilities
    $declared = switch ($Capability) {
        'elicitation.form' { Test-McpElicitationFormCapability -Capabilities $capabilities }
        default { Test-McpCapabilityPath -Capabilities $capabilities -Path $Capability }
    }
    if ($declared) { return }
    $required = [ordered]@{}
    $node = $required
    $segments = $Capability.Split('.')
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $node[$segments[$i]] = [ordered]@{}
        $node = $node[$segments[$i]]
    }
    throw [McpProtocolException]::new($script:McpErrorCode.MissingRequiredClientCapability, "This request needs the client capability '$Capability', which the client did not declare.", [ordered]@{ requiredCapabilities = $required })
}

function ConvertTo-McpElicitationSchema {
    <#
    .SYNOPSIS
        Normalises and validates a requested schema of form elicitation: the restricted, flat subset of JSON Schema.
    .DESCRIPTION
        Accepts a full schema ({ type = 'object'; properties = ...; required = ... }) or a table of properties.
        Properties must be primitive: string (optionally with format email, uri, date or date-time), number,
        integer, boolean, single-select enums (enum, oneOf of const/title, or the legacy enum with enumNames)
        and multi-select enums (arrays of enum or anyOf items).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object] $Schema,

        [string[]] $Required
    )

    $source = ConvertTo-McpSchemaObject -Schema $Schema
    if ($source -isnot [System.Collections.IDictionary]) { throw [System.ArgumentException]::new('The elicitation schema must be an object.') }
    $isFull = $source.Contains('properties') -and ($source['type'] -eq 'object' -or -not $source.Contains('type')) -and $source['properties'] -is [System.Collections.IDictionary]
    $properties = if ($isFull) { $source['properties'] } else { $source }
    $schema = [ordered]@{ type = 'object'; properties = [ordered]@{} }
    foreach ($name in $properties.Keys) {
        $property = $properties[$name]
        if ($property -isnot [System.Collections.IDictionary]) { throw [System.ArgumentException]::new("Elicitation property '$name' must be a schema object.") }
        $type = $property['type']
        switch ($type) {
            'string' {
                if ($property.Contains('format') -and $property['format'] -notin $script:McpElicitationStringFormats) {
                    throw [System.ArgumentException]::new("Elicitation property '$name' has the format '$($property['format'])'; allowed are $($script:McpElicitationStringFormats -join ', ').")
                }
            }
            { $_ -in @('number', 'integer', 'boolean') } { }
            'array' {
                $items = $property['items']
                if ($items -isnot [System.Collections.IDictionary] -or -not ($items.Contains('enum') -or $items.Contains('anyOf'))) {
                    throw [System.ArgumentException]::new("Elicitation property '$name' is an array; only multi-select enums (items with enum or anyOf) are allowed.")
                }
            }
            default {
                throw [System.ArgumentException]::new("Elicitation property '$name' has the type '$type'; only string, number, integer, boolean and enum arrays are allowed (no nesting).")
            }
        }
        $schema['properties'][[string] $name] = $property
    }
    $requiredNames = if ($PSBoundParameters.ContainsKey('Required')) { $Required } elseif ($isFull -and $source.Contains('required')) { @($source['required']) } else { @() }
    foreach ($name in $requiredNames) {
        if (-not $schema['properties'].Contains([string] $name)) { throw [System.ArgumentException]::new("The required elicitation property '$name' is not defined.") }
    }
    if (@($requiredNames).Count -gt 0) { $schema['required'] = [string[]] @($requiredNames) }
    $schema
}

function Test-McpInputResponse {
    <#
    .SYNOPSIS
        Validates the client's answer to an input request against the request; -32602 when it does not fit.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [string] $Key,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Request,

        [AllowNull()]
        [object] $Response
    )

    $prefix = "Invalid input response '$Key'"
    $errorData = [ordered]@{ key = $Key }
    $invalid = { param($reason) [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "${prefix}: $reason", $errorData) }
    if ($Response -isnot [System.Collections.IDictionary]) { throw (& $invalid 'it must be an object.') }
    $params = $Request['params']
    switch ($Request['method']) {
        'elicitation/create' {
            if ($Response['action'] -notin @('accept', 'decline', 'cancel')) { throw (& $invalid "action must be accept, decline or cancel.") }
            if ($Response['action'] -eq 'accept' -and $params['mode'] -ne 'url') {
                $content = if ($Response.Contains('content')) { $Response['content'] } else { [ordered]@{} }
                if ($content -isnot [System.Collections.IDictionary]) { throw (& $invalid 'content must be an object.') }
                $validation = Test-McpJsonSchema -Schema $params['requestedSchema'] -Instance $content
                if (-not $validation.IsValid) { throw (& $invalid ("the content does not match the requested schema: " + ($validation.Errors -join '; '))) }
            }
        }
        'sampling/createMessage' {
            if ($Response['role'] -notin @('user', 'assistant')) { throw (& $invalid 'role must be user or assistant.') }
            if ($Response['model'] -isnot [string]) { throw (& $invalid 'model must be a string.') }
            $content = $Response['content']
            if ($content -isnot [System.Collections.IDictionary] -and -not ($content -is [System.Collections.IList] -and @($content | Where-Object { $_ -isnot [System.Collections.IDictionary] }).Count -eq 0)) {
                throw (& $invalid 'content must be a content block or an array of content blocks.')
            }
        }
        'roots/list' {
            $roots = $Response['roots']
            if ($roots -isnot [System.Collections.IList]) { throw (& $invalid 'roots must be an array.') }
            foreach ($root in $roots) {
                if ($root -isnot [System.Collections.IDictionary] -or $root['uri'] -isnot [string]) { throw (& $invalid 'every root needs a uri.') }
            }
        }
    }
    $Response
}

function Invoke-McpInputRequest {
    <#
    .SYNOPSIS
        The answer to an input request when the client sent it; otherwise records the request and, unless deferred, throws McpInputRequiredException.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [object] $Context,

        [Parameter(Mandatory)]
        [string] $Key,

        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary] $Request,

        [Parameter(Mandatory)]
        [string[]] $Capability,

        [switch] $Defer
    )

    Test-McpContextInput -Context $Context
    if ($Context.InputResponses.Contains($Key)) {
        $response = Test-McpInputResponse -Key $Key -Request $Request -Response $Context.InputResponses[$Key]
        $Context.ConsumedInput[$Key] = $response
        return $response
    }
    foreach ($required in $Capability) { Assert-McpInputCapability -Context $Context -Capability $required }
    $Context.PendingInput[$Key] = $Request
    if (-not $Defer) {
        throw [McpInputRequiredException]::new($Context.PendingInput)
    }
}

function Get-McpInputRequiredResult {
    <#
    .SYNOPSIS
        The InputRequiredResult for the pending input requests of a handler, with a signed requestState for the retry.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary] $InputRequests,

        [Parameter(Mandatory)]
        [object] $Context,

        [Parameter(Mandatory)]
        [hashtable] $Envelope
    )

    $requested = [ordered]@{}
    foreach ($key in $InputRequests.Keys) { $requested[$key] = $InputRequests[$key]['method'] }
    $state = New-McpRequestState -Key $Envelope.RequestStateKey -Method $Envelope.Method -Name $Envelope.Name -Digest $Envelope.RequestDigest -Answers $Context.ConsumedInput -Requested $requested -HandlerState $Context.State -TtlSeconds $Envelope.RequestStateTtlSeconds
    [ordered]@{
        resultType    = 'input_required'
        inputRequests = $InputRequests
        requestState  = $state
    }
}

function Get-McpRequestInput {
    <#
    .SYNOPSIS
        Verifies requestState and inputResponses of a tools/call, prompts/get or resources/read request (in this order) and merges them.
    .OUTPUTS
        A hashtable with InputResponses (the answers of earlier rounds from the state, overlaid with the new ones),
        HandlerState and Digest.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [Parameter(Mandatory)]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Params
    )

    $salient = [ordered]@{}
    foreach ($key in $Params.Keys) { $salient[$key] = $Params[$key] }
    if ($Method -ne 'resources/read' -and ($null -eq $salient['arguments'])) { $salient['arguments'] = [ordered]@{} }
    $digest = Get-McpRequestDigest -Method $Method -Params $salient
    $responses = [ordered]@{}
    $handlerState = $null
    if ($Params.Contains('requestState')) {
        $payload = Read-McpRequestState -Key $Server.Options.RequestStateKey -Token $Params['requestState'] -Method $Method -Name $Name -Digest $digest
        if ($payload['a'] -is [System.Collections.IDictionary]) {
            foreach ($key in $payload['a'].Keys) { $responses[$key] = $payload['a'][$key] }
        }
        if ($payload.Contains('s') -and $payload['s'] -is [System.Collections.IDictionary]) { $handlerState = $payload['s'] }
    }
    if ($Params.Contains('inputResponses')) {
        $given = $Params['inputResponses']
        if ($given -isnot [System.Collections.IDictionary]) {
            throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "$Method 'inputResponses' must be an object.")
        }
        foreach ($key in $given.Keys) {
            if ($given[$key] -isnot [System.Collections.IDictionary]) {
                throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "Input response '$key' must be an object.", [ordered]@{ key = [string] $key })
            }
            $responses[[string] $key] = $given[$key]
        }
    }
    @{
        InputResponses = $responses
        HandlerState   = $handlerState
        Digest         = $digest
    }
}
