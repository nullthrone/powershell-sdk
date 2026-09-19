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
    $handler = $Registration.Handler
    $threshold = if ($null -ne $Context -and $Context.PSObject.Properties['LogLevel'] -and $null -ne $Context.LogLevel) { $Context.LogLevel } else { $script:McpDefaultLogLevel }

    $merged = $null
    try {
        if ($UseCommandName) {
            $merged = @(& $handler.CommandName @splat *>&1)
        } elseif ($handler.Kind -eq 'ScriptBlock') {
            $merged = @(& $handler.ScriptBlock @splat *>&1)
        } else {
            $merged = @(& $handler.CommandInfo @splat *>&1)
        }
    } catch [System.Management.Automation.PipelineStoppedException] {
        throw
    } catch {
        $exception = $_.Exception
        if ($exception -is [System.Management.Automation.RuntimeException] -and $null -ne $exception.InnerException -and $exception.GetType() -eq [System.Management.Automation.RuntimeException]) {
            $exception = $exception.InnerException
        }
        if ($exception -is [McpProtocolException]) { throw }
        $failure = ConvertTo-McpTextBlock -Text ('Error: ' + $exception.Message)
        $result = [ordered]@{
            content    = @($failure)
            isError    = $true
            resultType = 'complete'
        }
        return $result
    }
    $parts = Split-McpHandlerOutput -Merged $merged
    Write-McpHandlerDiagnostic -Diagnostics $parts.Diagnostics -ToolName $Registration.Name -Threshold $threshold
    ConvertTo-McpCallToolResult -Output $parts.Output -Registration $Registration -ErrorRecords $parts.Errors
}
