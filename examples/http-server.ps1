#Requires -Version 7.4
<#
.SYNOPSIS
    The echo tools over Streamable HTTP: an MCP endpoint on the loopback interface.
.DESCRIPTION
    Start it with
        pwsh -NoLogo -NoProfile -File ./examples/http-server.ps1 -Port 8080
    and connect with
        $session = Connect-McpServer -Url http://127.0.0.1:8080/mcp/
    or point an HTTP-capable MCP host at http://127.0.0.1:8080/mcp. Ctrl+C stops the server. The module is
    imported from $env:MCP_MODULE_MANIFEST when set, otherwise from the installed ModelContextProtocol module.
.PARAMETER Port
    The TCP port on 127.0.0.1.
.PARAMETER AllowedOrigins
    Origins accepted in the Origin header (default: loopback origins only).
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int] $Port = 8080,

    [string[]] $AllowedOrigins
)

if ($env:MCP_MODULE_MANIFEST) {
    Import-Module -Name $env:MCP_MODULE_MANIFEST -ErrorAction Stop
} else {
    Import-Module -Name ModelContextProtocol -ErrorAction Stop
}

$server = New-McpServer -Name 'echo-http' -Version '0.1.0' -Title 'Echo server over HTTP' -Instructions 'A demonstration server: echo text, look up a region, count with progress.' -LogLevel Info -SetDefault

Register-McpTool -Name 'echo' -Description 'Returns the text, optionally repeated.' -ScriptBlock {
    param(
        [Parameter(Mandatory)]
        [string] $Text,

        [ValidateRange(1, 10)]
        [int] $Repeat = 1
    )
    $Text * $Repeat
}

# -Header mirrors the Region argument into the Mcp-Param-Region header, so that proxies can route on it.
Register-McpTool -Name 'lookup' -Description 'Looks something up in a region.' -ScriptBlock {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('eu-central', 'us-west', 'ap-south')]
        [string] $Region,

        [Parameter(Mandatory)]
        [string] $Query
    )
    [pscustomobject]@{ region = $Region; query = $Query; hits = $Query.Length }
} -Header @{ Region = 'Region' }

Register-McpTool -Name 'count' -Description 'Counts to N, reporting progress on the SSE stream; honours cancellation.' -ScriptBlock {
    param(
        [ValidateRange(1, 100)]
        [int] $To = 3,

        [ValidateRange(0, 5000)]
        [int] $DelayMs = 200,

        [object] $Context
    )
    for ($i = 1; $i -le $To; $i++) {
        if ($Context.CancellationToken.IsCancellationRequested) { return "cancelled at $i" }
        Write-McpProgress -Context $Context -Progress $i -Total $To -Message "count $i"
        Start-Sleep -Milliseconds $DelayMs
    }
    "counted to $To"
}

$startParameters = @{ Server = $server; Transport = 'Http'; Url = "http://127.0.0.1:$Port/mcp/" }
if ($AllowedOrigins) { $startParameters['AllowedOrigins'] = $AllowedOrigins }
Start-McpServer @startParameters
