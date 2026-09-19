#Requires -Version 7.4
<#
.SYNOPSIS
    A small MCP server over stdio: echo, add, count (with progress), fail and shout tools.
.DESCRIPTION
    Start it from an MCP client with:
        pwsh -NoLogo -NoProfile -NonInteractive -File ./examples/echo-server.ps1
    The module is imported from $env:MCP_MODULE_MANIFEST when set (the repository's tests use the built
    module), otherwise from the installed ModelContextProtocol module.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The shout tool writes to the host on purpose to show that host output never reaches the client.')]
[CmdletBinding()]
param()

if ($env:MCP_MODULE_MANIFEST) {
    Import-Module -Name $env:MCP_MODULE_MANIFEST -ErrorAction Stop
} else {
    Import-Module -Name ModelContextProtocol -ErrorAction Stop
}

$server = New-McpServer -Name 'echo' -Version '0.1.0' -Title 'Echo server' -Instructions 'A demonstration server: echo text, add numbers, count with progress.' -SetDefault

Register-McpTool -Name 'echo' -Description 'Returns the text, optionally repeated.' -ScriptBlock {
    param(
        [Parameter(Mandatory)]
        [string] $Text,

        [ValidateRange(1, 10)]
        [int] $Repeat = 1
    )
    $Text * $Repeat
}

Register-McpTool -Name 'add' -Description 'Adds two numbers and returns the sum as structured content.' -ScriptBlock {
    param(
        [Parameter(Mandatory)]
        [double] $A,

        [Parameter(Mandatory)]
        [double] $B
    )
    [pscustomobject]@{ sum = $A + $B }
} -OutputSchema @{ type = 'object'; properties = @{ sum = @{ type = 'number' } }; required = @('sum') }

Register-McpTool -Name 'count' -Description 'Counts to N, reporting progress; honours cancellation.' -ScriptBlock {
    param(
        [ValidateRange(1, 100)]
        [int] $To = 3,

        [ValidateRange(0, 5000)]
        [int] $DelayMs = 100,

        [object] $Context
    )
    for ($i = 1; $i -le $To; $i++) {
        if ($Context.CancellationToken.IsCancellationRequested) { return "cancelled at $i" }
        Write-McpProgress -Context $Context -Progress $i -Total $To -Message "count $i"
        Write-McpLog -Context $Context -Level info -Message "counted $i"
        Start-Sleep -Milliseconds $DelayMs
    }
    "counted to $To"
}

Register-McpTool -Name 'fail' -Description 'Always fails, as a tool execution error the model can see.' -ScriptBlock {
    throw 'This tool always fails.'
}

Register-McpTool -Name 'shout' -Description 'Writes to the host and streams; only the return value reaches the client.' -ScriptBlock {
    param([string] $Text = 'hello')
    Write-Host "host output must not reach stdout: $Text"
    Write-Verbose 'verbose output'
    Write-Warning 'a warning for the server log'
    Write-Output $Text.ToUpperInvariant()
}

Start-McpServer -Server $server
