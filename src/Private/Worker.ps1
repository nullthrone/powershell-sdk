# Worker side of a tools/call request: runs in a runspace of the server's pool, builds the request context,
# invokes the handler through Invoke-McpToolHandler and enqueues the response for the dispatcher.

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
        ToolName           = $Envelope.ToolName
        Era                = 'Modern'
        ProtocolVersion    = $meta.ProtocolVersion
        ClientInfo         = $meta.ClientInfo
        ClientCapabilities = $meta.ClientCapabilities
        LogLevel           = $meta.LogLevel
        ProgressToken      = $meta.ProgressToken
        CancellationToken  = $Envelope.CancellationToken
        Sink               = $Envelope.Sink
        ServerName         = $Envelope.ServerName
        ServerLogLevel     = $Envelope.ServerLogLevel
        ProgressState      = @{ Last = $null }
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
        [string] $Json
    )

    $Sink.Queue.Enqueue(@{ Kind = $Kind; RequestId = $RequestId; Json = $Json })
    $null = $Sink.Signal.Set()
}

function Invoke-McpWorkerRequest {
    <#
    .SYNOPSIS
        Handles one tools/call request in a worker runspace and enqueues the response.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Envelope
    )

    $context = New-McpRequestContext -Envelope $Envelope
    $response = $null
    try {
        $result = Invoke-McpToolHandler -Registration $Envelope.Registration -Arguments $Envelope.Arguments -Context $context -UseCommandName
        if ($Envelope.IncludeServerInfo -and $null -ne $Envelope.ServerInfo) {
            $meta = if ($result.Contains('_meta') -and $result['_meta'] -is [System.Collections.IDictionary]) { $result['_meta'] } else { [ordered]@{} }
            $meta[$script:McpMetaKey.ServerInfo] = $Envelope.ServerInfo
            $result['_meta'] = $meta
        }
        $response = New-McpResultResponse -Id $Envelope.RequestId -Result $result
    } catch [System.Management.Automation.PipelineStoppedException] {
        throw
    } catch {
        $exception = $_.Exception
        if ($exception -is [System.Management.Automation.RuntimeException] -and $null -ne $exception.InnerException -and $exception.GetType() -eq [System.Management.Automation.RuntimeException]) {
            $exception = $exception.InnerException
        }
        $response = New-McpErrorResponse -Id $Envelope.RequestId -ErrorObject (ConvertTo-McpErrorObject -Exception $exception)
    }
    if ($Envelope.CancellationToken.IsCancellationRequested) { return }
    Send-McpSinkMessage -Sink $Envelope.Sink -Kind Response -RequestId $Envelope.RequestId -Json (ConvertTo-McpJson -InputObject $response)
}
