#Requires -Version 7.4
<#
.SYNOPSIS
    The conformance fixture server: the tools, resources, prompts and completions that the server scenarios of
    @modelcontextprotocol/conformance exercise for revision 2026-07-28, served over Streamable HTTP.
.DESCRIPTION
    The Conformance build task and .github/workflows/conformance.yml start it with
        pwsh -NoLogo -NoProfile -NonInteractive -File tests/Conformance/everything-server.ps1 -Port 3001
    and run the suite against http://127.0.0.1:3001/mcp. The module is imported from $env:MCP_MODULE_MANIFEST
    when set (the build sets it to the built module), otherwise from the installed ModelContextProtocol module.
    Scenarios of later milestones (subscriptions, input requests) are listed in conformance-baseline.yml until
    their milestone lands.
.PARAMETER Port
    The TCP port on the loopback interface.
.PARAMETER Hostname
    The host part of the endpoint URL; clients must use the same value.
.PARAMETER LogLevel
    The stderr log level (debug shows every request).
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int] $Port = 3001,

    [string] $Hostname = '127.0.0.1',

    [ValidateSet('debug', 'info', 'notice', 'warning', 'error', 'critical', 'alert', 'emergency')]
    [string] $LogLevel = 'info'
)

if ($env:MCP_MODULE_MANIFEST) {
    Import-Module -Name $env:MCP_MODULE_MANIFEST -ErrorAction Stop
} else {
    Import-Module -Name ModelContextProtocol -ErrorAction Stop
}

# Handlers run in worker runspaces and see nothing but their parameters, so the payloads (a 1x1 red PNG and a
# 44-byte silent WAV header, the smallest valid payloads of their types) are inlined below.

$server = New-McpServer -Name 'ModelContextProtocol-everything-server' -Version '0.1.0' -Title 'Conformance fixture' -Instructions 'A fixture for the MCP conformance suite.' -LogLevel $LogLevel -DefaultTtlMs 0 -DefaultCacheScope private -SetDefault

Register-McpTool -Name 'test_simple_text' -Description 'Returns a simple text response.' -ScriptBlock {
    'This is a simple text response for testing.'
}

Register-McpTool -Name 'test_image_content' -Description 'Returns a 1x1 PNG image.' -ScriptBlock {
    New-McpContent -Image 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==' -MimeType 'image/png'
}

Register-McpTool -Name 'test_audio_content' -Description 'Returns a minimal WAV clip.' -ScriptBlock {
    New-McpContent -Audio 'UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQAAAAA=' -MimeType 'audio/wav'
}

Register-McpTool -Name 'test_embedded_resource' -Description 'Returns an embedded text resource.' -ScriptBlock {
    New-McpContent -EmbeddedResource 'test://embedded-resource' -MimeType 'text/plain' -ResourceText 'This is an embedded resource content.'
}

Register-McpTool -Name 'test_multiple_content_types' -Description 'Returns text, an image and an embedded resource.' -ScriptBlock {
    New-McpContent -Text 'Multiple content types test:'
    New-McpContent -Image 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==' -MimeType 'image/png'
    New-McpContent -EmbeddedResource 'test://mixed-content-resource' -MimeType 'application/json' -ResourceText '{"test":"data","value":123}'
}

Register-McpTool -Name 'test_error_handling' -Description 'Always fails, as a tool execution error.' -ScriptBlock {
    throw 'This tool intentionally returns an error for testing'
}

Register-McpTool -Name 'test_tool_with_progress' -Description 'Reports progress 0, 50 and 100 of 100 while it runs.' -ScriptBlock {
    param($Context)
    Write-McpProgress -Context $Context -Progress 0 -Total 100 -Message 'Starting'
    Start-Sleep -Milliseconds 50
    Write-McpProgress -Context $Context -Progress 50 -Total 100 -Message 'Half way'
    Start-Sleep -Milliseconds 50
    Write-McpProgress -Context $Context -Progress 100 -Total 100 -Message 'Done'
    'Progress test completed'
}

Register-McpTool -Name 'test_logging_tool' -Description 'Logs three messages; they reach the client only when the request asked for a log level.' -ScriptBlock {
    param($Context)
    Write-McpLog -Context $Context -Level info -Message 'Tool execution started'
    Start-Sleep -Milliseconds 50
    Write-McpLog -Context $Context -Level info -Message 'Tool processing data'
    Start-Sleep -Milliseconds 50
    Write-McpLog -Context $Context -Level info -Message 'Tool execution completed'
    'Logging test completed'
}

Register-McpTool -Name 'test_missing_capability' -Description 'Requires the sampling capability; rejects requests that do not declare it.' -ScriptBlock {
    param($Context)
    if (-not (Test-McpClientCapability -Context $Context -Path 'sampling')) {
        throw [McpProtocolException]::new(-32021, 'This tool requires the sampling capability.', @{ requiredCapabilities = @{ sampling = @{} } })
    }
    'The client declared the sampling capability.'
}

Register-McpTool -Name 'test_streaming_elicitation' -Description 'Streams a result; asks the client for input from milestone M4 on.' -ScriptBlock {
    'No input required yet.'
}

Register-McpTool -Name 'test_custom_headers' -Description 'Mirrors region and priority into Mcp-Param headers.' -ScriptBlock {
    param(
        [Parameter(Mandatory)]
        [string] $region,

        [int] $priority = 0,

        [string] $query = ''
    )
    "region=$region priority=$priority query=$query"
} -Header @{ region = 'Region'; priority = 'Priority' }

# The JSON Schema 2020-12 vocabulary of the json-schema-2020-12 scenario: kept verbatim in tools/list.
$jsonSchemaTool = [ordered]@{
    '$schema'            = 'https://json-schema.org/draft/2020-12/schema'
    type                 = 'object'
    '$defs'              = [ordered]@{
        address = [ordered]@{
            '$anchor'  = 'addressDef'
            type       = 'object'
            properties = [ordered]@{ street = [ordered]@{ type = 'string' }; city = [ordered]@{ type = 'string' } }
        }
    }
    properties           = [ordered]@{
        name          = [ordered]@{ type = 'string' }
        address       = [ordered]@{ '$ref' = '#/$defs/address' }
        contactMethod = [ordered]@{ type = 'string'; enum = @('phone', 'email') }
        phone         = [ordered]@{ type = 'string' }
        email         = [ordered]@{ type = 'string' }
    }
    allOf                = @([ordered]@{ anyOf = @([ordered]@{ required = @('phone') }, [ordered]@{ required = @('email') }) })
    if                   = [ordered]@{ properties = [ordered]@{ contactMethod = [ordered]@{ const = 'phone' } }; required = @('contactMethod') }
    then                 = [ordered]@{ required = @('phone') }
    else                 = [ordered]@{ required = @('email') }
    additionalProperties = $false
}
Register-McpTool -Name 'json_schema_2020_12_tool' -Description 'Tool with JSON Schema 2020-12 features' -InputSchema $jsonSchemaTool -ScriptBlock {
    param([hashtable] $Arguments)
    "Received $($Arguments.Count) argument(s)."
}

# Resources: the caching scenario reads the first listed resource, so the static text resource comes first.
$png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=='
Register-McpResource -Uri 'test://static-text' -Name 'Static text resource' -Description 'A static text resource.' -Content 'This is the content of the static text resource.'
Register-McpResource -Uri 'test://static-binary' -Name 'Static binary resource' -Description 'A 1x1 PNG image.' -MimeType 'image/png' -Content ([System.Convert]::FromBase64String($png))
Register-McpResource -UriTemplate 'test://template/{id}/data' -Name 'Template resource' -Description 'Data for an ID.' -MimeType 'application/json' -ScriptBlock {
    param([string] $id)
    [ordered]@{ id = $id; templateTest = $true; data = "Data for ID: $id" }
} -Completion @{ id = @('1', '12', '123') }

Register-McpPrompt -Name 'test_simple_prompt' -Description 'A simple prompt without arguments.' -ScriptBlock {
    'This is a simple prompt for testing.'
}

Register-McpPrompt -Name 'test_prompt_with_arguments' -Description 'A prompt with two required arguments.' -Arguments @(
    @{ Name = 'arg1'; Description = 'First test argument'; Required = $true }
    @{ Name = 'arg2'; Description = 'Second test argument'; Required = $true }
) -ScriptBlock {
    param([string] $arg1, [string] $arg2)
    "Prompt with arguments: arg1='$arg1', arg2='$arg2'"
} -Completion @{ arg1 = @('paris', 'park', 'party', 'test', 'testing') }

Register-McpPrompt -Name 'test_prompt_with_embedded_resource' -Description 'A prompt that embeds a resource.' -Arguments @(
    @{ Name = 'resourceUri'; Description = 'The URI of the embedded resource'; Required = $true }
) -ScriptBlock {
    param([string] $resourceUri)
    New-McpContent -EmbeddedResource $resourceUri -MimeType 'text/plain' -ResourceText 'Embedded resource content for testing.'
    'Please process the embedded resource above.'
}

Register-McpPrompt -Name 'test_prompt_with_image' -Description 'A prompt with an image.' -ScriptBlock {
    New-McpContent -Image 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==' -MimeType 'image/png'
    'Please analyze the image above.'
}

Start-McpServer -Server $server -Transport Http -Url "http://${Hostname}:$Port/mcp/"
