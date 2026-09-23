function Request-McpSampling {
    <#
    .SYNOPSIS
        Asks the client's language model for a completion (sampling/createMessage as an input request).
    .DESCRIPTION
        Multi-round-trip request (MRTR), deprecated in revision 2026-07-28 but supported: the first call throws
        and the server answers with an InputRequiredResult; when the client retries with the model's answer,
        the handler runs again and this command returns it (Mcp.SamplingResult: Role, Content, Model,
        StopReason and the Text of text blocks). The client must have declared the sampling capability
        (sampling.tools for -Tools, sampling.context for -IncludeContext other than none); otherwise -32021.
    .PARAMETER Context
        The request context (the handler's Context parameter).
    .PARAMETER Key
        The identifier of this input request within the handler.
    .PARAMETER Messages
        The conversation: strings (user text), content blocks (New-McpContent, user messages) or hashtables
        with role and content.
    .PARAMETER MaxTokens
        The maximum number of tokens to sample.
    .PARAMETER SystemPrompt
        An optional system prompt.
    .PARAMETER Temperature
        The sampling temperature.
    .PARAMETER StopSequences
        Sequences that stop sampling.
    .PARAMETER ModelPreferences
        Model preferences: hints (@(@{ name = '...' })), costPriority, speedPriority, intelligencePriority.
    .PARAMETER Tools
        Tool definitions the model may call (hashtables with name, description and inputSchema).
    .PARAMETER ToolChoice
        How the model uses the tools: auto, none or required.
    .PARAMETER IncludeContext
        Context from MCP servers to include: none, thisServer or allServers (deprecated values).
    .PARAMETER Metadata
        Provider-specific metadata.
    .PARAMETER Defer
        Record the request without throwing when the answer is missing (see Wait-McpInput).
    .EXAMPLE
        (Request-McpSampling -Context $Context -Key 'summary' -Messages "Summarise: $text" -MaxTokens 200).Text
    .OUTPUTS
        Mcp.SamplingResult
    #>
    [CmdletBinding()]
    [OutputType('Mcp.SamplingResult')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Key,

        [Parameter(Mandatory)]
        [object[]] $Messages,

        [ValidateRange(1, [int]::MaxValue)]
        [int] $MaxTokens = 1000,

        [string] $SystemPrompt,

        [double] $Temperature,

        [string[]] $StopSequences,

        [hashtable] $ModelPreferences,

        [object[]] $Tools,

        [ValidateSet('auto', 'none', 'required')]
        [string] $ToolChoice,

        [ValidateSet('none', 'thisServer', 'allServers')]
        [string] $IncludeContext,

        [hashtable] $Metadata,

        [switch] $Defer
    )

    $wireMessages = foreach ($message in $Messages) {
        if ($null -eq $message) { continue }
        if ($message -is [string]) {
            [ordered]@{ role = 'user'; content = [ordered]@{ type = 'text'; text = $message } }
        } elseif (Test-McpContentObject -Value $message) {
            [ordered]@{ role = 'user'; content = $message }
        } elseif ($message -is [System.Collections.IDictionary] -and $message.Contains('role') -and $message.Contains('content')) {
            $content = $message['content']
            if ($content -is [string]) { $content = [ordered]@{ type = 'text'; text = $content } }
            [ordered]@{ role = [string] $message['role']; content = $content }
        } else {
            throw [System.ArgumentException]::new('-Messages accepts strings, content blocks and hashtables with role and content.')
        }
    }
    $params = [ordered]@{ messages = @($wireMessages); maxTokens = $MaxTokens }
    if ($SystemPrompt) { $params['systemPrompt'] = $SystemPrompt }
    if ($PSBoundParameters.ContainsKey('Temperature')) { $params['temperature'] = $Temperature }
    if ($StopSequences) { $params['stopSequences'] = $StopSequences }
    if ($ModelPreferences) { $params['modelPreferences'] = $ModelPreferences }
    if ($Metadata) { $params['metadata'] = $Metadata }
    $capabilities = [System.Collections.Generic.List[string]]::new()
    $capabilities.Add('sampling')
    if ($Tools) {
        $params['tools'] = @($Tools)
        $capabilities.Add('sampling.tools')
    }
    if ($ToolChoice) { $params['toolChoice'] = [ordered]@{ mode = $ToolChoice } }
    if ($IncludeContext) {
        $params['includeContext'] = $IncludeContext
        if ($IncludeContext -ne 'none') { $capabilities.Add('sampling.context') }
    }
    $request = [ordered]@{ method = 'sampling/createMessage'; params = $params }
    $response = Invoke-McpInputRequest -Context $Context -Key $Key -Request $request -Capability $capabilities.ToArray() -Defer:$Defer
    if ($null -eq $response) { return }
    $blocks = @($response['content'])
    [pscustomobject]@{
        PSTypeName = 'Mcp.SamplingResult'
        Key        = $Key
        Role       = [string] $response['role']
        Content    = $response['content']
        Model      = [string] $response['model']
        StopReason = if ($response.Contains('stopReason')) { $response['stopReason'] } else { $null }
        Text       = (@($blocks | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['type'] -eq 'text' } | ForEach-Object { [string] $_['text'] })) -join "`n"
        Raw        = $response
    }
}
