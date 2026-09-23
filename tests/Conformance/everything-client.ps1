#Requires -Version 7.4
<#
.SYNOPSIS
    The conformance fixture client: connects to the scenario server of @modelcontextprotocol/conformance over
    Streamable HTTP and exercises what the client scenarios of revision 2026-07-28 observe.
.DESCRIPTION
    The suite runs it as
        pwsh -NoLogo -NoProfile -NonInteractive -File tests/Conformance/everything-client.ps1 <server-url>
    with MCP_CONFORMANCE_SCENARIO (the scenario name), MCP_CONFORMANCE_CONTEXT (JSON with scenario data such as
    the tool calls to make) and MCP_CONFORMANCE_PROTOCOL_VERSION (when a spec version was requested). It
    discovers the server, lists the tools and calls them: the calls given in the context, or every listed tool
    with arguments derived from its input schema. Diagnostics go to stderr; the exit code is 0 unless the
    connection fails. Scenarios of later milestones (input requests, authorization) are listed in
    conformance-baseline.yml.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]] $Arguments
)

$ErrorActionPreference = 'Stop'
if ($env:MCP_MODULE_MANIFEST) {
    Import-Module -Name $env:MCP_MODULE_MANIFEST -ErrorAction Stop
} else {
    Import-Module -Name ModelContextProtocol -ErrorAction Stop
}

function Write-ClientLog {
    param([string] $Message)
    [Console]::Error.WriteLine("[everything-client] $Message")
}

function ConvertTo-ToolArgument {
    <#
    .SYNOPSIS
        Arguments for a tool call: a value of the right type for every required property of the input schema.
    #>
    param([object] $Schema)
    $arguments = [ordered]@{}
    if ($Schema -isnot [System.Collections.IDictionary] -or -not $Schema.Contains('properties') -or $Schema['properties'] -isnot [System.Collections.IDictionary]) { return $arguments }
    $required = if ($Schema.Contains('required')) { @($Schema['required']) } else { @() }
    foreach ($name in $required) {
        $property = $Schema['properties'][$name]
        $type = if ($property -is [System.Collections.IDictionary] -and $property.Contains('type')) { [string] $property['type'] } else { 'string' }
        $arguments[[string] $name] = switch ($type) {
            'integer' { 1 }
            'number' { 1 }
            'boolean' { $true }
            'object' { [ordered]@{} }
            'array' { @() }
            'null' { $null }
            default { if ($property -is [System.Collections.IDictionary] -and $property.Contains('enum')) { @($property['enum'])[0] } else { 'test' } }
        }
    }
    $arguments
}

$url = if ($Arguments.Count -gt 0) { $Arguments[-1] } else { $null }
if (-not $url) {
    Write-ClientLog 'Usage: everything-client.ps1 <server-url>'
    exit 2
}
$scenario = $env:MCP_CONFORMANCE_SCENARIO
$context = @{}
if ($env:MCP_CONFORMANCE_CONTEXT) {
    try { $context = ConvertFrom-Json -InputObject $env:MCP_CONFORMANCE_CONTEXT -AsHashtable -Depth 50 } catch { Write-ClientLog "Ignoring MCP_CONFORMANCE_CONTEXT: $($_.Exception.Message)" }
    if ($null -eq $context) { $context = @{} }
}
$protocolVersion = if ($env:MCP_CONFORMANCE_PROTOCOL_VERSION) { $env:MCP_CONFORMANCE_PROTOCOL_VERSION } else { '2026-07-28' }
Write-ClientLog "scenario '$scenario' at $url (protocol version $protocolVersion)"
if ($protocolVersion -ne '2026-07-28') {
    Write-ClientLog "Protocol version $protocolVersion uses the initialize handshake, which this client speaks from milestone M5 on."
    exit 0
}

$connectParameters = @{
    Url                   = $url
    ClientInfo            = @{ name = 'ModelContextProtocol-everything-client'; version = '0.1.0' }
    Capabilities          = @{ elicitation = @{ form = @{} }; sampling = @{}; roots = @{ listChanged = $true } }
    ProtocolVersion       = $protocolVersion
    RequestTimeoutSeconds = 20
    ConnectTimeoutSeconds = 20
}
$session = Connect-McpServer @connectParameters
try {
    $info = Get-McpServerInfo -Session $session
    Write-ClientLog "connected to '$($info.Name)' $($info.Version) (supports $($info.SupportedVersions -join ', '))"
    $tools = @(Get-McpTool -Session $session -WarningVariable exclusions)
    foreach ($warning in @($exclusions)) { Write-ClientLog "warning: $warning" }
    Write-ClientLog "tools: $(if ($tools.Count -gt 0) { ($tools | ForEach-Object Name) -join ', ' } else { '(none)' })"

    $calls = [System.Collections.Generic.List[hashtable]]::new()
    if ($context.ContainsKey('toolCalls') -and $null -ne $context['toolCalls']) {
        foreach ($call in @($context['toolCalls'])) {
            if ($call -is [System.Collections.IDictionary] -and $call.Contains('name')) {
                $calls.Add(@{ name = [string] $call['name']; arguments = $(if ($call.Contains('arguments') -and $null -ne $call['arguments']) { $call['arguments'] } else { @{} }) })
            }
        }
    } else {
        $echo = $tools | Where-Object { $_.Name -eq 'json_schema_echo' } | Select-Object -First 1
        $focal = $tools | Where-Object { $_.Name -eq 'json_schema_2020_12_tool' } | Select-Object -First 1
        foreach ($tool in $tools) {
            if ($tool.Name -eq 'json_schema_echo' -and $null -ne $focal) {
                # The preservation scenario wants the focal tool's schema back exactly as the client observed it.
                $calls.Add(@{ name = $echo.Name; arguments = @{ schema = $focal.InputSchema } })
            } else {
                $calls.Add(@{ name = $tool.Name; arguments = (ConvertTo-ToolArgument -Schema $tool.InputSchema) })
            }
        }
    }
    foreach ($call in $calls) {
        try {
            $result = Invoke-McpTool -Name $call.name -Arguments $call.arguments -Session $session
            Write-ClientLog "tools/call $($call.name): isError=$($result.IsError) text=$($result.Text.Substring(0, [math]::Min(80, $result.Text.Length)))"
        } catch {
            Write-ClientLog "tools/call $($call.name) failed: $($_.Exception.Message)"
        }
    }

    # Resources and prompts, when the server declares them (http-standard-headers checks the Mcp-Method and
    # Mcp-Name headers of resources/read and prompts/get).
    $capabilities = $info.Capabilities
    if ($capabilities -is [System.Collections.IDictionary] -and $capabilities.Contains('resources')) {
        try {
            foreach ($resource in @(Get-McpResource -Session $session)) {
                $contents = @(Read-McpResource -Uri $resource.Uri -Session $session -ErrorAction Continue)
                Write-ClientLog "resources/read $($resource.Uri): $($contents.Count) content(s)"
            }
        } catch {
            Write-ClientLog "resources failed: $($_.Exception.Message)"
        }
    }
    if ($capabilities -is [System.Collections.IDictionary] -and $capabilities.Contains('prompts')) {
        try {
            foreach ($prompt in @(Get-McpPrompt -Session $session)) {
                $promptArguments = @{}
                foreach ($argument in @($prompt.Arguments | Where-Object { $_.Required })) { $promptArguments[$argument.Name] = 'value' }
                $rendered = Invoke-McpPrompt -Name $prompt.Name -Arguments $promptArguments -Session $session
                Write-ClientLog "prompts/get $($prompt.Name): $(@($rendered.Messages).Count) message(s)"
            }
        } catch {
            Write-ClientLog "prompts failed: $($_.Exception.Message)"
        }
    }
} finally {
    Disconnect-McpServer -Session $session
}
exit 0
