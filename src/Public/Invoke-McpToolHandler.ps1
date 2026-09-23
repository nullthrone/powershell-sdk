function Invoke-McpToolHandler {
    <#
    .SYNOPSIS
        Runs a registered tool in the current runspace and returns its CallToolResult, as a client would see it.
    .DESCRIPTION
        Validates the arguments against the tool's input schema, binds them to the handler's parameters, runs
        the handler and shapes its output. Use it to test tools without a transport. Protocol errors (unknown
        tool, invalid arguments) are thrown as McpProtocolException; errors inside the handler become a result
        with isError.
    .PARAMETER Name
        The registered tool name.
    .PARAMETER Arguments
        The arguments as a dictionary (JSON-compatible values).
    .PARAMETER Server
        The server the tool is registered on; defaults to the default server.
    .PARAMETER Registration
        A registration object instead of -Name and -Server.
    .PARAMETER Context
        The request context passed to a handler's Context parameter (built by the server at call time).
    .PARAMETER UseCommandName
        Invoke the handler by its command name in the current runspace (used by the worker runspaces, where
        handlers exist as functions) instead of the script block or command object captured at registration.
    .EXAMPLE
        Invoke-McpToolHandler -Name echo -Arguments @{ Text = 'hi' }
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary (a CallToolResult)
    #>
    [CmdletBinding(DefaultParameterSetName = 'Name')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(ParameterSetName = 'Name', Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Position = 1)]
        [AllowNull()]
        [System.Collections.IDictionary] $Arguments,

        [Parameter(ParameterSetName = 'Name')]
        [object] $Server,

        [Parameter(ParameterSetName = 'Registration', Mandatory)]
        [ValidateNotNull()]
        [object] $Registration,

        [object] $Context,

        [switch] $UseCommandName
    )

    if ($PSCmdlet.ParameterSetName -eq 'Name') {
        $Registration = Get-McpToolRegistration -Server (Resolve-McpServer -Server $Server) -Name $Name
    }
    if ($null -eq $Arguments) { $Arguments = [ordered]@{} }

    $validation = Test-McpJsonSchema -Schema $Registration.InputSchema -Instance $Arguments
    if (-not $validation.IsValid) {
        $data = [ordered]@{ errors = @($validation.Errors) }
        throw [McpProtocolException]::new($script:McpErrorCode.InvalidParams, "Invalid arguments for tool '$($Registration.Name)': $($validation.Errors -join '; ')", $data)
    }
    $splat = ConvertTo-McpToolArgument -Registration $Registration -Arguments $Arguments -Context $Context
    $threshold = if ($null -ne $Context -and $Context.PSObject.Properties['ServerLogLevel'] -and $null -ne $Context.ServerLogLevel) { $Context.ServerLogLevel } else { $script:McpDefaultLogLevel }

    $merged = $null
    try {
        $merged = @(Invoke-McpHandlerCommand -Handler $Registration.Handler -Splat $splat -UseCommandName:$UseCommandName)
    } catch [System.Management.Automation.PipelineStoppedException] {
        throw
    } catch {
        $exception = Get-McpHandlerException -Exception $_.Exception
        if ($exception -is [McpProtocolException]) { throw $exception }
        $failure = ConvertTo-McpTextBlock -Text ('Error: ' + $exception.Message)
        $result = [ordered]@{
            content    = @($failure)
            isError    = $true
            resultType = 'complete'
        }
        return $result
    }
    $parts = Split-McpHandlerOutput -Merged $merged
    Write-McpHandlerDiagnostic -Diagnostics $parts.Diagnostics -Name $Registration.Name -Threshold $threshold -Context $Context
    ConvertTo-McpCallToolResult -Output $parts.Output -Registration $Registration -ErrorRecords $parts.Errors
}
