#Requires -Version 7.4
<#
.SYNOPSIS
    An MCP server over stdio with all server primitives: a tool, resources, a resource template, prompts and
    argument completion, around made-up weather data.
.DESCRIPTION
    Start it from an MCP client with:
        pwsh -NoLogo -NoProfile -NonInteractive -File ./examples/weather-server.ps1
    The module is imported from $env:MCP_MODULE_MANIFEST when set (the repository's tests use the built
    module), otherwise from the installed ModelContextProtocol module. The data is generated from the city
    name, so the example needs no network access.
#>
[CmdletBinding()]
param()

if ($env:MCP_MODULE_MANIFEST) {
    Import-Module -Name $env:MCP_MODULE_MANIFEST -ErrorAction Stop
} else {
    Import-Module -Name ModelContextProtocol -ErrorAction Stop
}

$server = New-McpServer -Name 'weather' -Version '0.1.0' -Title 'Weather example' -Instructions 'Made-up weather data: read weather://stations for the known cities, weather://{city}/current for current conditions, or use the forecast tool and the weather-report prompt.' -DefaultTtlMs 60000 -SetDefault

# Handlers run in worker runspaces and see nothing but their parameters, so each handler derives its data from
# the city name itself.
Register-McpTool -Name 'forecast' -Description 'A made-up forecast for the next days.' -ScriptBlock {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Berlin', 'Hamburg', 'Munich', 'Vienna', 'Zurich')]
        [string] $City,

        [ValidateRange(1, 7)]
        [int] $Days = 3
    )
    $seed = [int] ($City.ToCharArray() | Measure-Object -Sum { [int] $_ }).Sum
    [pscustomobject]@{
        city = $City
        days = @(for ($day = 1; $day -le $Days; $day++) {
                [ordered]@{ day = $day; high = 12 + ($seed + $day * 7) % 15; low = 2 + ($seed + $day * 3) % 8 }
            })
    }
} -OutputSchema @{ type = 'object'; properties = @{ city = @{ type = 'string' }; days = @{ type = 'array' } }; required = @('city', 'days') } -Annotations @{ ReadOnlyHint = $true; OpenWorldHint = $false }

Register-McpResource -Uri 'weather://stations' -Name 'stations' -Title 'Weather stations' -Description 'The cities with weather data.' -MimeType 'application/json' -Content '["Berlin","Hamburg","Munich","Vienna","Zurich"]' -Annotations @{ Audience = 'assistant'; Priority = 0.8 }

Register-McpResource -UriTemplate 'weather://{city}/current' -Name 'current-weather' -Title 'Current weather' -Description 'Current conditions in a city.' -MimeType 'application/json' -TtlMs 10000 -ScriptBlock {
    param([string] $city)
    if ($city -notin @('Berlin', 'Hamburg', 'Munich', 'Vienna', 'Zurich')) { return }
    $seed = [int] ($city.ToCharArray() | Measure-Object -Sum { [int] $_ }).Sum
    [ordered]@{ city = $city; temperature = 5 + $seed % 20; conditions = @('clear', 'cloudy', 'rain', 'snow')[$seed % 4] }
} -Completion @{
    city = { param($Value) @('Berlin', 'Hamburg', 'Munich', 'Vienna', 'Zurich') | Where-Object { $_ -like "$Value*" } }
}

Register-McpPrompt -Name 'weather-report' -ScriptBlock {
    <#
    .SYNOPSIS
        Asks the model for a short weather report for a city.
    .PARAMETER City
        The city of the report.
    .PARAMETER Tone
        The tone of the report.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Berlin', 'Hamburg', 'Munich', 'Vienna', 'Zurich')]
        [string] $City,

        [ValidateSet('neutral', 'cheerful', 'dramatic')]
        [string] $Tone = 'neutral'
    )
    New-McpContent -EmbeddedResource "weather://$City/current" -MimeType 'text/plain' -ResourceText "Current weather data for $City is available as weather://$City/current."
    "Write a $Tone three-sentence weather report for $City. Use the forecast tool for the coming days."
}

Register-McpPrompt -Name 'packing-list' -Description 'Asks the model what to pack for a trip.' -Arguments @(
    @{ Name = 'destination'; Description = 'Where the trip goes.'; Required = $true }
    @{ Name = 'days'; Description = 'The length of the trip in days.' }
) -ScriptBlock {
    param($Arguments)
    $days = if ($Arguments['days']) { $Arguments['days'] } else { 'a few' }
    New-McpPromptMessage -Role user -Text "I am travelling to $($Arguments['destination']) for $days days. What should I pack?"
    New-McpPromptMessage -Role assistant -Text 'Let me check the forecast first.'
}

Start-McpServer -Server $server
