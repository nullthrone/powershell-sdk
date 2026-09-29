# Worker side of a request that runs user code (tools/call, resources/read, prompts/get, completion/complete):
# runs in a runspace of the server's pool, builds the request context, invokes the handler and enqueues the
# response for the dispatcher; a handler that asks for input (McpInputRequiredException) is answered with an
# InputRequiredResult.

$script:McpModuleManifestPath = Join-Path $PSScriptRoot 'ModelContextProtocol.psd1'

# The script the dispatcher adds to a worker PowerShell instance. The nested block runs in the module's scope
# of the worker runspace, where the private worker function is visible.
$script:McpWorkerScript = 'param($Envelope) & (Get-Module -Name ModelContextProtocol) { param($e) Invoke-McpWorkerRequest -Envelope $e } $Envelope'

function New-McpRequestContext {
    <#
    .SYNOPSIS
        The Mcp.RequestContext object handed to handlers (their Context parameter) for one request.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object.')]
    [CmdletBinding()]
    [OutputType('Mcp.RequestContext')]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Envelope
    )

    $meta = $Envelope.Meta
    [pscustomobject]@{
        PSTypeName         = 'Mcp.RequestContext'
        RequestId          = $Envelope.RequestId
        Method             = $Envelope.Method
        Name               = $Envelope.Name
        ToolName           = if ($Envelope.Kind -eq 'Tool') { $Envelope.Name } else { $null }
        Era                = if ($Envelope.Era) { $Envelope.Era } else { 'Modern' }
        ProtocolVersion    = $meta.ProtocolVersion
        ClientInfo         = $meta.ClientInfo
        ClientCapabilities = $meta.ClientCapabilities
        LogLevel           = $meta.LogLevel
        ProgressToken      = $meta.ProgressToken
        CancellationToken  = $Envelope.CancellationToken
        Sink               = $Envelope.Sink
        ServerName         = $Envelope.ServerName
        ServerLogLevel     = $Envelope.ServerLogLevel
        # Legacy sessions: the table of open server-initiated requests and their timeout.
        Legacy             = $Envelope.Legacy
        ProgressState      = @{ Last = $null }
        # Multi-round-trip requests: the answers of this and earlier rounds, the requests of this round, the
        # answers the handler accepted, and handler state that survives the rounds (in the signed requestState).
        InputResponses     = if ($null -ne $Envelope.InputResponses) { $Envelope.InputResponses } else { [ordered]@{} }
        PendingInput       = if ($Envelope.Kind -in @('Tool', 'Resource', 'Prompt')) { [ordered]@{} } else { $null }
        ConsumedInput      = [ordered]@{}
        State              = $(
            $table = @{}
            if ($Envelope.HandlerState -is [System.Collections.IDictionary]) { foreach ($key in $Envelope.HandlerState.Keys) { $table[[string] $key] = $Envelope.HandlerState[$key] } }
            $table
        )
    }
}

function Send-McpSinkMessage {
    <#
    .SYNOPSIS
        Enqueues a serialised message for the dispatcher and wakes it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Sink,

        [Parameter(Mandatory)]
        [ValidateSet('Response', 'Notification')]
        [string] $Kind,

        [AllowNull()]
        [object] $RequestId,

        [Parameter(Mandatory)]
        [string] $Json,

        # The JSON-RPC error code of an error response; the HTTP transport derives the status code from it.
        [AllowNull()]
        [object] $ErrorCode
    )

    # KeyPrefix: requests of a legacy session are keyed per session (request ids are unique per session only).
    $Sink.Queue.Enqueue(@{ Kind = $Kind; RequestId = $RequestId; KeyPrefix = $Sink.KeyPrefix; Json = $Json; ErrorCode = $ErrorCode })
    $null = $Sink.Signal.Set()
}

$script:McpWorkerDefinitions = @{}

function Initialize-McpWorkerHandler {
    <#
    .SYNOPSIS
        Makes a handler callable by name in this worker runspace: defines (or redefines) its function and imports its module.
    .DESCRIPTION
        The pool defines the handlers registered before the start. Handlers registered, or replaced with -Force,
        while the server runs are defined here on first use, so that they can be called too.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [hashtable] $Handler
    )

    if ($null -eq $Handler) { return }
    if ($Handler.Definition -and $Handler.Kind -in @('ScriptBlock', 'Function')) {
        $name = $Handler.CommandName
        if ($script:McpWorkerDefinitions[$name] -cne $Handler.Definition) {
            if (-not $script:McpWorkerDefinitions.ContainsKey($name) -and (Test-Path -Path "function:global:$name")) {
                # Defined by the pool: remember its definition instead of replacing it.
                $script:McpWorkerDefinitions[$name] = (Get-Item -Path "function:global:$name").Definition
            }
            if ($script:McpWorkerDefinitions[$name] -cne $Handler.Definition) {
                # A string value is compiled by the function provider, exactly like the pool's function entries.
                Set-Item -Path "function:global:$name" -Value $Handler.Definition
                $script:McpWorkerDefinitions[$name] = $Handler.Definition
            }
        }
    } elseif ($Handler.ModulePath -and -not (Get-Module -Name $Handler.ModuleName)) {
        Import-Module -Name $Handler.ModulePath -Global
    }
}

function Invoke-McpWorkerRequest {
    <#
    .SYNOPSIS
        Handles one request in a worker runspace and enqueues the response.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Envelope
    )

    $context = New-McpRequestContext -Envelope $Envelope
    $response = $null
    $errorCode = $null
    try {
        switch ($Envelope.Kind) {
            'Completion' { if ($null -ne $Envelope.Completion.Source) { Initialize-McpWorkerHandler -Handler $Envelope.Completion.Source.Handler } }
            default { Initialize-McpWorkerHandler -Handler $Envelope.Registration.Handler }
        }
        $result = switch ($Envelope.Kind) {
            'Tool' { Invoke-McpToolHandler -Registration $Envelope.Registration -Arguments $Envelope.Arguments -Context $context -UseCommandName }
            'Resource' { Invoke-McpResourceHandler -Registration $Envelope.Registration -Uri $Envelope.Name -Variables $Envelope.Variables -Context $context -CacheHint $Envelope.CacheHint -UseCommandName }
            'Prompt' { Invoke-McpPromptHandler -Registration $Envelope.Registration -Arguments $Envelope.Arguments -Context $context -UseCommandName }
            'Completion' { Invoke-McpCompletionHandler -Request $Envelope.Completion -Context $context -UseCommandName }
        }
        if ($Envelope.IncludeServerInfo -and $null -ne $Envelope.ServerInfo) {
            $meta = if ($result.Contains('_meta') -and $result['_meta'] -is [System.Collections.IDictionary]) { $result['_meta'] } else { [ordered]@{} }
            $meta[$script:McpMetaKey.ServerInfo] = $Envelope.ServerInfo
            $result['_meta'] = $meta
        }
        if ($context.Era -eq 'Legacy') { $result = ConvertTo-McpLegacyResult -Result $result }
        $response = New-McpResultResponse -Id $Envelope.RequestId -Result $result
    } catch [System.Management.Automation.PipelineStoppedException] {
        throw
    } catch {
        $exception = Get-McpHandlerException -Exception $_.Exception
        if ($exception -is [McpInputRequiredException] -and $null -ne $context.PendingInput) {
            $result = Get-McpInputRequiredResult -InputRequests $exception.InputRequests -Context $context -Envelope $Envelope
            if ($Envelope.IncludeServerInfo -and $null -ne $Envelope.ServerInfo) {
                $meta = [ordered]@{}
                $meta[$script:McpMetaKey.ServerInfo] = $Envelope.ServerInfo
                $result['_meta'] = $meta
            }
            if ($Envelope.CancellationToken.IsCancellationRequested) { return }
            Send-McpSinkMessage -Sink $Envelope.Sink -Kind Response -RequestId $Envelope.RequestId -Json (ConvertTo-McpJson -InputObject (New-McpResultResponse -Id $Envelope.RequestId -Result $result))
            return
        }
        $errorObject = ConvertTo-McpErrorObject -Exception $exception -Era $context.Era
        $errorCode = $errorObject['code']
        $response = New-McpErrorResponse -Id $Envelope.RequestId -ErrorObject $errorObject
    }
    if ($Envelope.CancellationToken.IsCancellationRequested) { return }
    Send-McpSinkMessage -Sink $Envelope.Sink -Kind Response -RequestId $Envelope.RequestId -Json (ConvertTo-McpJson -InputObject $response) -ErrorCode $errorCode
}
