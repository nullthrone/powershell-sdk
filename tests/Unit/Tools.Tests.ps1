[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force

    function script:Get-McpTestEcho {
        <#
        .SYNOPSIS
            Echoes text.
        .PARAMETER Text
            The text to echo.
        .PARAMETER Repeat
            How often.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Context is inspected by the registration, not used by the fixture.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string] $Text,

            [ValidateRange(1, 5)]
            [int] $Repeat = 1,

            [switch] $Upper,

            [object] $Context
        )
        $result = $Text * $Repeat
        if ($Upper) { $result.ToUpperInvariant() } else { $result }
    }
}

Describe 'Register-McpTool' {
    BeforeEach {
        $script:server = New-McpServer -Name 'test' -Version '1.0.0'
    }

    It 'registers a function with a generated schema and the synopsis as description' {
        $registration = Register-McpTool -Command (Get-Command Get-McpTestEcho) -Server $script:server -PassThru
        $registration.PSObject.TypeNames | Should -Contain 'Mcp.ToolRegistration'
        $registration.Name | Should -Be 'Get-McpTestEcho'
        $registration.Description | Should -Be 'Echoes text.'
        $registration.InputSchema['required'] | Should -Be @('Text')
        $registration.InputSchema['properties']['Repeat']['maximum'] | Should -Be 5
        $registration.InputSchema['properties'].Contains('Context') | Should -BeFalse
        $registration.Handler.Kind | Should -Be 'Function'
        $registration.Handler.CommandName | Should -Be 'Get-McpTestEcho'
        $registration.Handler.Definition | Should -Match 'Repeat'
        $registration.Handler.ContextParameter | Should -Be 'Context'
        $registration.Handler.ArgumentStyle | Should -Be 'Splat'
        $script:server.Tools.Contains('Get-McpTestEcho') | Should -BeTrue
    }

    It 'registers a script block with a generated schema' {
        $registration = Register-McpTool -Name 'add' -ScriptBlock { param([Parameter(Mandatory)][int] $A, [int] $B = 1) $A + $B } -Server $script:server -PassThru
        $registration.Handler.Kind | Should -Be 'ScriptBlock'
        $registration.Handler.CommandName | Should -Be 'McpTool_add'
        $registration.InputSchema['properties']['A']['type'] | Should -Be 'integer'
        $registration.InputSchema['properties']['B']['default'] | Should -Be 1
        $registration.InputSchema['required'] | Should -Be @('A')
        $registration.Handler.Definition | Should -Match '\$A \+ \$B'
    }

    It 'uses an explicit input schema and the Arguments style when the handler declares Arguments' {
        $schema = @{ type = 'object'; properties = @{ q = @{ type = 'string' } }; required = @('q') }
        $registration = Register-McpTool -Name 'search' -ScriptBlock { param($Arguments) $Arguments['q'] } -InputSchema $schema -Server $script:server -PassThru
        $registration.Handler.ArgumentStyle | Should -Be 'Arguments'
        $registration.InputSchema['required'] | Should -Be @('q')
        $registration.InputSchema['properties']['q']['type'] | Should -Be 'string'
    }

    It 'registers a cmdlet with its module' {
        $registration = Register-McpTool -Command Get-Date -Name 'date' -Server $script:server -PassThru
        $registration.Handler.Kind | Should -Be 'Cmdlet'
        $registration.Handler.ModuleName | Should -Be 'Microsoft.PowerShell.Utility'
        $registration.InputSchema['properties']['Format']['type'] | Should -Be 'string'
    }

    It 'normalises annotations, keeps title, icons and meta' {
        $registration = Register-McpTool -Command (Get-Command Get-McpTestEcho) -Name 'echo' -Title 'Echo' -Annotations @{ ReadOnlyHint = $true; DestructiveHint = 0; Title = 'Echo tool' } -Icons @(@{ src = 'https://example.com/i.png'; mimeType = 'image/png' }) -Meta @{ 'x.example/flag' = 1 } -Server $script:server -PassThru
        $registration.Annotations['readOnlyHint'] | Should -BeTrue
        $registration.Annotations['destructiveHint'] | Should -BeFalse
        $registration.Annotations['title'] | Should -Be 'Echo tool'
        $definition = Invoke-McpInModule { param($r) ConvertTo-McpToolDefinition -Registration $r } $registration
        @($definition.Keys) | Should -Be @('name', 'title', 'description', 'inputSchema', 'annotations', 'icons', '_meta')
        (Test-McpSpecShape -Definition 'Tool' -Instance $definition).IsValid | Should -BeTrue
    }

    It 'rejects invalid names and duplicates unless -Force' {
        { Register-McpTool -Name 'bad name' -ScriptBlock { 1 } -Server $script:server } | Should -Throw -ExpectedMessage '*not a valid tool name*'
        Register-McpTool -Name 'one' -ScriptBlock { 1 } -Server $script:server
        { Register-McpTool -Name 'one' -ScriptBlock { 2 } -Server $script:server } | Should -Throw -ExpectedMessage '*already registered*'
        Register-McpTool -Name 'one' -ScriptBlock { 2 } -Server $script:server -Force
        (Invoke-McpToolHandler -Name 'one' -Server $script:server)['content'][0]['text'] | Should -Be '2'
    }

    It 'uses the default server when none is given' {
        $default = New-McpServer -Name 'default' -Version '1' -SetDefault
        Register-McpTool -Name 'ping' -ScriptBlock { 'pong' }
        $default.Tools.Contains('ping') | Should -BeTrue
    }
}

Describe 'Invoke-McpToolHandler' {
    BeforeAll {
        $script:server = New-McpServer -Name 'test' -Version '1.0.0'
        Register-McpTool -Command (Get-Command Get-McpTestEcho) -Name 'echo' -Server $script:server
        Register-McpTool -Name 'object' -ScriptBlock { [pscustomobject]@{ answer = 42; list = @(1, 2) } } -Server $script:server
        Register-McpTool -Name 'objects' -ScriptBlock { @{ a = 1 }; @{ b = 2 } } -Server $script:server
        Register-McpTool -Name 'throws' -ScriptBlock { throw 'boom' } -Server $script:server
        Register-McpTool -Name 'writes-error' -ScriptBlock { Write-Error 'soft'; 'partial' } -Server $script:server
        Register-McpTool -Name 'result' -ScriptBlock { New-McpToolResult -IsError -Text 'nope' -StructuredContent @{ code = 1 } } -Server $script:server
        Register-McpTool -Name 'image' -ScriptBlock { New-McpContent -Image ([byte[]] @(1, 2, 3)) -MimeType 'image/png'; 'and text' } -Server $script:server
        Register-McpTool -Name 'typed' -ScriptBlock { param([datetime] $When, [string[]] $Tags, [hashtable] $Map, [System.DayOfWeek] $Day) "$($When.Year)|$($Tags.Count)|$($Map['k'])|$([int] $Day)" } -Server $script:server
        Register-McpTool -Name 'context' -ScriptBlock { param($Context) $Context.RequestId } -Server $script:server
        Register-McpTool -Name 'raw' -ScriptBlock { param($Arguments) $Arguments.Keys -join ',' } -InputSchema @{ type = 'object'; additionalProperties = $true } -Server $script:server
        Register-McpTool -Name 'structured' -ScriptBlock { param([int] $N) @{ n = $N } } -OutputSchema @{ type = 'object'; properties = @{ n = @{ type = 'integer'; minimum = 1 } }; required = @('n') } -Server $script:server
        Register-McpTool -Name 'nothing' -ScriptBlock { } -Server $script:server
    }

    It 'returns text content for string output and validates against CallToolResult' {
        $result = Invoke-McpToolHandler -Name 'echo' -Arguments @{ Text = 'hi'; Repeat = 2; Upper = $true } -Server $script:server
        $result['content'][0]['type'] | Should -Be 'text'
        $result['content'][0]['text'] | Should -Be 'HIHI'
        $result['resultType'] | Should -Be 'complete'
        $result.Contains('isError') | Should -BeFalse
        (Test-McpSpecShape -Definition 'CallToolResult' -Instance $result).IsValid | Should -BeTrue
    }

    It 'throws -32602 for invalid arguments and unknown tools' {
        $exception = $null
        try { Invoke-McpToolHandler -Name 'echo' -Arguments @{ Repeat = 9 } -Server $script:server } catch { $exception = $_.Exception }
        $exception | Should -BeOfType [McpProtocolException]
        $exception.Code | Should -Be -32602
        @($exception.Data['errors']).Count | Should -BeGreaterOrEqual 2
        try { Invoke-McpToolHandler -Name 'missing' -Server $script:server } catch { $exception = $_.Exception }
        $exception.Code | Should -Be -32602
        $exception.Message | Should -Match 'Unknown tool'
    }

    It 'turns a single object into structuredContent plus JSON text' {
        $result = Invoke-McpToolHandler -Name 'object' -Server $script:server
        $result['structuredContent'].answer | Should -Be 42
        $result['content'][0]['text'] | Should -Be '{"answer":42,"list":[1,2]}'
        (Test-McpSpecShape -Definition 'CallToolResult' -Instance $result).IsValid | Should -BeTrue
    }

    It 'turns several objects into JSON text blocks without structuredContent' {
        $result = Invoke-McpToolHandler -Name 'objects' -Server $script:server
        $result['content'].Count | Should -Be 2
        $result.Contains('structuredContent') | Should -BeFalse
    }

    It 'reports handler exceptions and non-terminating errors as isError results' {
        $thrown = Invoke-McpToolHandler -Name 'throws' -Server $script:server
        $thrown['isError'] | Should -BeTrue
        $thrown['content'][0]['text'] | Should -Be 'Error: boom'
        # Whether Write-Error terminates the handler depends on the caller's ErrorActionPreference in-process;
        # either way the result is an error result that names the error.
        $soft = Invoke-McpToolHandler -Name 'writes-error' -Server $script:server
        $soft['isError'] | Should -BeTrue
        @($soft['content'] | ForEach-Object { $_['text'] }) | Should -Contain 'Error: soft'
    }

    It 'passes New-McpToolResult through' {
        $result = Invoke-McpToolHandler -Name 'result' -Server $script:server
        $result['isError'] | Should -BeTrue
        $result['content'][0]['text'] | Should -Be 'nope'
        $result['structuredContent']['code'] | Should -Be 1
        (Test-McpSpecShape -Definition 'CallToolResult' -Instance $result).IsValid | Should -BeTrue
    }

    It 'passes content blocks through and encodes binary data' {
        $result = Invoke-McpToolHandler -Name 'image' -Server $script:server
        $result['content'][0].type | Should -Be 'image'
        $result['content'][0].data | Should -Be 'AQID'
        $result['content'][1]['text'] | Should -Be 'and text'
        (Test-McpSpecShape -Definition 'CallToolResult' -Instance $result).IsValid | Should -BeTrue
    }

    It 'binds typed parameters from JSON values' {
        $arguments = Invoke-McpInModule { ConvertFrom-McpJson '{"When":"2026-07-28T10:00:00Z","Tags":["a","b"],"Map":{"k":"v"},"Day":"Tuesday"}' }
        $result = Invoke-McpToolHandler -Name 'typed' -Arguments $arguments -Server $script:server
        $result['content'][0]['text'] | Should -Be '2026|2|v|2'
    }

    It 'injects the context and supports the Arguments style' {
        $context = [pscustomobject]@{ PSTypeName = 'Mcp.RequestContext'; RequestId = 'r-7'; LogLevel = 'warning' }
        (Invoke-McpToolHandler -Name 'context' -Context $context -Server $script:server)['content'][0]['text'] | Should -Be 'r-7'
        (Invoke-McpToolHandler -Name 'raw' -Arguments ([ordered]@{ x = 1; y = 2 }) -Server $script:server)['content'][0]['text'] | Should -Be 'x,y'
    }

    It 'validates structured content against the output schema' {
        (Invoke-McpToolHandler -Name 'structured' -Arguments @{ N = 3 } -Server $script:server).Contains('isError') | Should -BeFalse
        $invalid = Invoke-McpToolHandler -Name 'structured' -Arguments @{ N = 0 } -Server $script:server
        $invalid['isError'] | Should -BeTrue
        $invalid['content'][-1]['text'] | Should -Match 'output schema'
    }

    It 'returns an empty content array for a handler without output' {
        $result = Invoke-McpToolHandler -Name 'nothing' -Server $script:server
        @($result['content']).Count | Should -Be 0
        (Test-McpSpecShape -Definition 'CallToolResult' -Instance $result).IsValid | Should -BeTrue
    }
}
