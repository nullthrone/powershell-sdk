function Request-McpElicitation {
    <#
    .SYNOPSIS
        Asks the user, through the client, for input: a form (elicitation/create in form mode) or a URL to visit (URL mode).
    .DESCRIPTION
        Multi-round-trip request (MRTR): the first time a handler calls this command, the answer is not there
        yet; the command throws, the server answers the request with an InputRequiredResult carrying this
        elicitation, and the client retries the request with the user's answer. The handler then runs again
        from the start and this command returns the answer (Mcp.ElicitResult: Action accept, decline or cancel,
        and Content with the form values). A handler must therefore be idempotent up to its last input request;
        answers of earlier rounds are kept in the signed requestState.

        The client must have declared the elicitation capability (form mode) or elicitation.url (URL mode);
        otherwise the request fails with -32021 and the required capability. Check with
        Test-McpClientCapability first to offer a fallback. Accepted form content is validated against -Schema.
    .PARAMETER Context
        The request context (the handler's Context parameter).
    .PARAMETER Key
        The identifier of this input request within the handler; the answer is looked up by it.
    .PARAMETER Message
        The message shown to the user.
    .PARAMETER Schema
        The form: a table of properties (name = @{ type = 'string'; title = ...; ... }) or a full schema
        (@{ type = 'object'; properties = @{ ... }; required = @(...) }). Only flat primitive properties are
        allowed: string (format email, uri, date, date-time), number, integer, boolean and enums.
    .PARAMETER Required
        The names of required form properties (overrides required of a full schema).
    .PARAMETER Url
        The URL the user should open (URL mode), for interactions that must not pass through the client.
    .PARAMETER Defer
        Record the request without throwing and return nothing when the answer is missing; call Wait-McpInput
        after deferring several requests to ask for all of them in one round.
    .EXAMPLE
        $answer = Request-McpElicitation -Context $Context -Key 'confirm' -Message 'Delete 3 files?' -Schema @{ ok = @{ type = 'boolean' } } -Required ok
        if ($answer.Action -ne 'accept' -or -not $answer.Content.ok) { return 'Cancelled.' }
    .OUTPUTS
        Mcp.ElicitResult
    #>
    [CmdletBinding(DefaultParameterSetName = 'Form')]
    [OutputType('Mcp.ElicitResult')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Key,

        [Parameter(Mandatory)]
        [string] $Message,

        [Parameter(ParameterSetName = 'Form', Mandatory)]
        [ValidateNotNull()]
        [object] $Schema,

        [Parameter(ParameterSetName = 'Form')]
        [string[]] $Required,

        [Parameter(ParameterSetName = 'Url', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Url,

        [switch] $Defer
    )

    $params = [ordered]@{}
    if ($PSCmdlet.ParameterSetName -eq 'Url') {
        $parsed = $null
        if (-not [uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref] $parsed)) { throw [System.ArgumentException]::new("'$Url' is not an absolute URL.") }
        $params['mode'] = 'url'
        $params['message'] = $Message
        $params['url'] = $Url
        $capability = 'elicitation.url'
    } else {
        $schemaParameters = @{ Schema = $Schema }
        if ($PSBoundParameters.ContainsKey('Required')) { $schemaParameters['Required'] = $Required }
        $params['mode'] = 'form'
        $params['message'] = $Message
        $params['requestedSchema'] = ConvertTo-McpElicitationSchema @schemaParameters
        $capability = 'elicitation.form'
    }
    $request = [ordered]@{ method = 'elicitation/create'; params = $params }
    $response = Invoke-McpInputRequest -Context $Context -Key $Key -Request $request -Capability $capability -Defer:$Defer
    if ($null -eq $response) { return }
    [pscustomobject]@{
        PSTypeName = 'Mcp.ElicitResult'
        Key        = $Key
        Action     = [string] $response['action']
        Accepted   = $response['action'] -eq 'accept'
        Content    = if ($response.Contains('content')) { $response['content'] } else { $null }
    }
}
