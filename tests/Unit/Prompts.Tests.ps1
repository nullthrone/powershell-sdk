[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force

    # Renders a prompt in the current runspace, as the worker would, and returns the wire result after a JSON round trip.
    function Get-TestPrompt {
        param([pscustomobject] $Server, [string] $Name, [hashtable] $Arguments)
        Invoke-McpInModule {
            param($s, $n, $a)
            $registration = Get-McpPromptRegistration -Server $s -Name $n
            $values = Test-McpPromptArgument -Registration $registration -Arguments $a
            $result = Invoke-McpPromptHandler -Registration $registration -Arguments $values
            ConvertFrom-McpJson (ConvertTo-McpJson -InputObject $result)
        } -Parameters @{ s = $Server; n = $Name; a = $Arguments }
    }

    function Get-TestCompletion {
        param([pscustomobject] $Server, [hashtable] $Params)
        Invoke-McpInModule {
            param($s, $p)
            $request = Resolve-McpCompletionRequest -Server $s -Params $p
            Invoke-McpCompletionHandler -Request $request
        } -Parameters @{ s = $Server; p = $Params }
    }
}

Describe 'Register-McpPrompt' {
    It 'derives arguments, descriptions and completions from the param block' {
        $server = New-McpServer -Name 'p' -Version '1'
        $registration = Register-McpPrompt -Server $server -Name 'weather' -PassThru -ScriptBlock {
            <#
            .SYNOPSIS
                Asks for a weather report.
            .PARAMETER City
                The city.
            .PARAMETER Units
                The unit system.
            #>
            param(
                [Parameter(Mandatory)] [string] $City,
                [ValidateSet('metric', 'imperial')] [string] $Units = 'metric',
                [int] $Days = 1,
                $Context
            )
            "Weather for $City in $Units units for $Days day(s)$(if ($null -eq $Context) { ' (no context)' })."
        }
        $registration.Description | Should -Be 'Asks for a weather report.'
        @($registration.Arguments | ForEach-Object { $_['name'] }) | Should -Be @('City', 'Units', 'Days')
        $registration.Arguments[0]['required'] | Should -BeTrue
        $registration.Arguments[0]['description'] | Should -Be 'The city.'
        $registration.Arguments[1].Contains('required') | Should -BeFalse
        $registration.Completion['Units'].Values | Should -Be @('metric', 'imperial')
        $list = Invoke-McpInModule { param($s) Get-McpPromptListResult -Server $s -Cursor $null } $server
        (Test-McpSpecShape -Definition 'ListPromptsResult' -Instance $list).IsValid | Should -BeTrue
        $result = Get-TestPrompt -Server $server -Name 'weather' -Arguments @{ City = 'Berlin'; Days = '3' }
        (Test-McpSpecShape -Definition 'GetPromptResult' -Instance $result).IsValid | Should -BeTrue
        $result['description'] | Should -Be 'Asks for a weather report.'
        $result['messages'][0]['role'] | Should -Be 'user'
        $result['messages'][0]['content']['text'] | Should -Be 'Weather for Berlin in metric units for 3 day(s) (no context).'
    }

    It 'passes all values to an Arguments parameter with explicit -Arguments' {
        $server = New-McpServer -Name 'p' -Version '1'
        $registration = Register-McpPrompt -Server $server -Name 'raw' -Description 'Raw.' -PassThru -Arguments @('a', @{ Name = 'b'; Title = 'B'; Description = 'Second'; Required = $true }) -ScriptBlock {
            param($Arguments)
            ($Arguments.Keys | Sort-Object | ForEach-Object { "$_=$($Arguments[$_])" }) -join ';'
        }
        $registration.Handler.ArgumentStyle | Should -Be 'Arguments'
        $registration.Arguments[1]['title'] | Should -Be 'B'
        (Get-TestPrompt -Server $server -Name 'raw' -Arguments @{ a = '1'; b = '2'; extra = '3' })['messages'][0]['content']['text'] | Should -Be 'a=1;b=2;extra=3'
    }

    It 'shapes content blocks, assistant messages and objects' {
        $server = New-McpServer -Name 'p' -Version '1'
        Register-McpPrompt -Server $server -Name 'mixed' -Description 'Mixed.' -ScriptBlock {
            'first'
            'second'
            New-McpContent -Image ([byte[]] (1, 2)) -MimeType 'image/png'
            New-McpPromptMessage -Role assistant -Text 'Understood.'
            New-McpContent -EmbeddedResource 'test://doc' -MimeType 'text/plain' -ResourceText 'doc'
            [pscustomobject]@{ a = 1 }
        }
        $result = Get-TestPrompt -Server $server -Name 'mixed'
        (Test-McpSpecShape -Definition 'GetPromptResult' -Instance $result).IsValid | Should -BeTrue
        $messages = $result['messages']
        $messages.Count | Should -Be 5
        $messages[0]['content']['text'] | Should -Be "first`nsecond"
        $messages[1]['content']['type'] | Should -Be 'image'
        $messages[2]['role'] | Should -Be 'assistant'
        $messages[3]['content']['resource']['uri'] | Should -Be 'test://doc'
        $messages[4]['content']['text'] | Should -Be '{"a":1}'
    }

    It 'validates arguments of prompts/get' {
        $server = New-McpServer -Name 'p' -Version '1'
        Register-McpPrompt -Server $server -Name 'needs' -Description 'Needs x.' -ScriptBlock { param([Parameter(Mandatory)][string] $x) $x }
        { Get-TestPrompt -Server $server -Name 'needs' -Arguments @{} } | Should -Throw -ExpectedMessage '*Missing required argument*x*'
        { Get-TestPrompt -Server $server -Name 'needs' -Arguments @{ x = 5 } } | Should -Throw -ExpectedMessage '*must be a string*'
        { Get-TestPrompt -Server $server -Name 'unknown' -Arguments @{} } | Should -Throw -ExpectedMessage "*Unknown prompt 'unknown'*"
        (Get-TestPrompt -Server $server -Name 'needs' -Arguments @{ x = 'ok'; ignored = 'y' })['messages'][0]['content']['text'] | Should -Be 'ok'
    }

    It 'turns handler failures into internal errors' {
        $server = New-McpServer -Name 'p' -Version '1'
        Register-McpPrompt -Server $server -Name 'broken' -Description 'Broken.' -ScriptBlock { throw 'kaputt' }
        $caught = $null
        try { Get-TestPrompt -Server $server -Name 'broken' } catch { $caught = $_.Exception }
        while ($caught -and $caught -isnot [McpProtocolException] -and $caught.InnerException) { $caught = $caught.InnerException }
        $caught.Code | Should -Be -32603
        $caught.Message | Should -Match 'kaputt'
    }

    It 'warns about a prompt without description and refuses duplicates' {
        $server = New-McpServer -Name 'p' -Version '1'
        Register-McpPrompt -Server $server -Name 'bare' -ScriptBlock { 'x' } -WarningVariable warnings -WarningAction SilentlyContinue
        @($warnings).Count | Should -Be 1
        { Register-McpPrompt -Server $server -Name 'bare' -Description 'Again.' -ScriptBlock { 'x' } } | Should -Throw -ExpectedMessage '*already registered*'
        Register-McpPrompt -Server $server -Name 'bare' -Description 'Again.' -ScriptBlock { 'y' } -Force
        $server.Prompts['bare'].Description | Should -Be 'Again.'
    }
}

Describe 'completion/complete' {
    BeforeAll {
        $script:server = New-McpServer -Name 'c' -Version '1'
        Register-McpPrompt -Server $script:server -Name 'city' -Description 'City.' -ScriptBlock { param([ValidateSet('Berlin', 'Bern', 'Bonn', 'Paris')][string] $Name, [string] $Country) "$Name, $Country" } -Completion @{
            Country = { param($Value, $Arguments) @('Germany', 'Switzerland', 'France') | Where-Object { $_ -like "$Value*" } | ForEach-Object { "$_ ($($Arguments['Name']))" } }
        }
        Register-McpResource -Server $script:server -UriTemplate 'numbers://{n}' -ScriptBlock { param($n) $n } -Completion @{ n = @(1..250 | ForEach-Object { [string] $_ }) }
    }

    It 'filters value lists by prefix, case-insensitively' {
        $result = Get-TestCompletion -Server $script:server -Params @{ ref = @{ type = 'ref/prompt'; name = 'city' }; argument = @{ name = 'Name'; value = 'be' } }
        (Test-McpSpecShape -Definition 'CompleteResult' -Instance $result).IsValid | Should -BeTrue
        $result['completion']['values'] | Should -Be @('Berlin', 'Bern')
        $result['completion']['total'] | Should -Be 2
        $result['completion']['hasMore'] | Should -BeFalse
    }

    It 'runs completion handlers with the context arguments' {
        $result = Get-TestCompletion -Server $script:server -Params @{ ref = @{ type = 'ref/prompt'; name = 'city' }; argument = @{ name = 'Country'; value = 'Ger' }; context = @{ arguments = @{ Name = 'Berlin' } } }
        $result['completion']['values'] | Should -Be @('Germany (Berlin)')
    }

    It 'caps the values at 100 and reports the total' {
        $result = Get-TestCompletion -Server $script:server -Params @{ ref = @{ type = 'ref/resource'; uri = 'numbers://{n}' }; argument = @{ name = 'n'; value = '' } }
        (Test-McpSpecShape -Definition 'CompleteResult' -Instance $result).IsValid | Should -BeTrue
        $result['completion']['values'].Count | Should -Be 100
        $result['completion']['total'] | Should -Be 250
        $result['completion']['hasMore'] | Should -BeTrue
    }

    It 'returns no values for an argument without a completion source' {
        Register-McpPrompt -Server $script:server -Name 'plain' -Description 'Plain.' -ScriptBlock { param([string] $Free) $Free }
        (Get-TestCompletion -Server $script:server -Params @{ ref = @{ type = 'ref/prompt'; name = 'plain' }; argument = @{ name = 'Free'; value = 'x' } })['completion']['values'].Count | Should -Be 0
    }

    It 'rejects invalid references: <Case>' -TestCases @(
        @{ Case = 'unknown prompt'; Params = @{ ref = @{ type = 'ref/prompt'; name = 'nope' }; argument = @{ name = 'Name'; value = '' } }; Message = '*Unknown prompt*' }
        @{ Case = 'unknown argument'; Params = @{ ref = @{ type = 'ref/prompt'; name = 'city' }; argument = @{ name = 'Nope'; value = '' } }; Message = '*no argument*' }
        @{ Case = 'unknown template'; Params = @{ ref = @{ type = 'ref/resource'; uri = 'numbers://x' }; argument = @{ name = 'n'; value = '' } }; Message = '*Unknown resource template*' }
        @{ Case = 'unknown variable'; Params = @{ ref = @{ type = 'ref/resource'; uri = 'numbers://{n}' }; argument = @{ name = 'm'; value = '' } }; Message = '*no variable*' }
        @{ Case = 'unknown ref type'; Params = @{ ref = @{ type = 'ref/tool'; name = 'x' }; argument = @{ name = 'n'; value = '' } }; Message = '*Unknown completion reference type*' }
        @{ Case = 'missing argument'; Params = @{ ref = @{ type = 'ref/prompt'; name = 'city' } }; Message = "*requires 'argument'*" }
        @{ Case = 'non-string context'; Params = @{ ref = @{ type = 'ref/prompt'; name = 'city' }; argument = @{ name = 'Name'; value = '' }; context = @{ arguments = @{ x = 1 } } }; Message = '*must be a string*' }
    ) {
        { Get-TestCompletion -Server $script:server -Params $Params } | Should -Throw -ExpectedMessage $Message
    }
}
