#Requires -Version 7.4
<#
.SYNOPSIS
    An MCP server over stdio whose tools ask the user for input (multi-round-trip requests) and announce changes
    of their tool list to subscribers (subscriptions/listen).
.DESCRIPTION
    Start it from an MCP client with:
        pwsh -NoLogo -NoProfile -NonInteractive -File ./examples/elicitation-server.ps1
    The module is imported from $env:MCP_MODULE_MANIFEST when set (the repository's tests use the built
    module), otherwise from the installed ModelContextProtocol module.

    A tool that needs input calls Request-McpElicitation. The first time, the answer is not there: the server
    answers with an InputRequiredResult, the client asks the user and sends the request again with the
    answer, and the handler runs again from the start, this time getting the answer. Handlers therefore do
    their side effects only after the last input request.

    Try it from PowerShell:
        $session = Connect-McpServer -Command pwsh -Arguments '-NoProfile', '-File', './examples/elicitation-server.ps1' -OnElicitation {
            param($Request)
            Write-Host $Request.Message
            switch (@($Request.RequestedSchema.properties.Keys)[0]) {
                'confirm' { @{ confirm = $true } }
                'name' { @{ name = 'Ada' } }
                'color' { @{ color = 'green' } }
            }
        }
        Invoke-McpTool -Name 'delete-files' -Arguments @{ Pattern = '*.tmp' }
#>
[CmdletBinding()]
param()

if ($env:MCP_MODULE_MANIFEST) {
    Import-Module -Name $env:MCP_MODULE_MANIFEST -ErrorAction Stop
} else {
    Import-Module -Name ModelContextProtocol -ErrorAction Stop
}

$server = New-McpServer -Name 'elicitation' -Version '0.1.0' -Title 'Elicitation example' -Instructions 'Tools that ask the user before they act.' -SetDefault

Register-McpTool -Name 'delete-files' -ScriptBlock {
    <#
    .SYNOPSIS
        Pretends to delete files, after the user confirmed it.
    .PARAMETER Pattern
        The file name pattern.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Pattern,

        $Context
    )
    if (-not (Test-McpClientCapability -Context $Context -Path 'elicitation')) {
        return "The client cannot ask for a confirmation; nothing deleted."
    }
    $answer = Request-McpElicitation -Context $Context -Key 'confirm' -Message "Delete all files matching '$Pattern'?" -Schema @{
        confirm = @{ type = 'boolean'; title = 'Delete'; description = 'Yes, delete the files.' }
    } -Required confirm
    if ($answer.Action -ne 'accept' -or -not $answer.Content.confirm) { return 'Cancelled; nothing deleted.' }
    # The side effect happens only now, after the last input request.
    "Deleted the files matching '$Pattern' (not really: this is an example)."
}

Register-McpTool -Name 'profile' -ScriptBlock {
    <#
    .SYNOPSIS
        Asks two questions in two rounds and remembers the round count in the request state.
    #>
    param($Context)
    $Context.State['rounds'] = 1 + [int] $Context.State['rounds']
    $name = Request-McpElicitation -Context $Context -Key 'name' -Message 'What is your name?' -Schema @{ name = @{ type = 'string'; minLength = 1 } } -Required name
    if ($name.Action -ne 'accept') { return 'No profile.' }
    $color = Request-McpElicitation -Context $Context -Key 'color' -Message "Hello $($name.Content.name), what is your favourite color?" -Schema @{
        color = @{ type = 'string'; enum = @('red', 'green', 'blue') }
    } -Required color
    "$($name.Content.name) likes $($color.Content.color) (asked in $($Context.State['rounds']) rounds)."
}

Register-McpTool -Name 'announce-tools' -ScriptBlock {
    <#
    .SYNOPSIS
        Announces a change of the tool list to the clients subscribed with Register-McpSubscription -ToolsListChanged.
    #>
    param($Context)
    # A handler announces changes through its context; Register-McpTool and Unregister-McpTool announce them
    # automatically when they change a running server.
    Send-McpToolListChanged -Context $Context
    'Announced.'
}

Start-McpServer -Server $server -Transport Stdio
