BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force
    $script:engines = @('PowerShell')
    if ((Invoke-McpInModule { Get-McpJsonSchemaEngine }) -eq 'JsonSchemaNet') { $script:engines += 'JsonSchemaNet' }
    $script:engineCases = @($script:engines | ForEach-Object { @{ Engine = $_ } })
}

Describe 'Test-McpJsonSchema' {
    It 'uses JsonSchema.Net when PowerShell ships it' {
        $expected = if (Test-Path (Join-Path $PSHOME 'JsonSchema.Net.dll')) { 'JsonSchemaNet' } else { 'PowerShell' }
        Invoke-McpInModule { Get-McpJsonSchemaEngine } | Should -Be $expected
    }

    Context 'engine <Engine>' -ForEach @(@{ Engine = 'PowerShell' }, @{ Engine = 'JsonSchemaNet' }) {
        BeforeAll {
            $script:skip = $Engine -notin $script:engines
        }

        It 'accepts a valid object and reports type violations with locations' {
            if ($script:skip) { Set-ItResult -Skipped -Because "$Engine is not available"; return }
            $schema = '{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"string"}},"required":["a"],"additionalProperties":false}'
            $ok = Invoke-McpInModule { param($s, $e) Test-McpJsonSchema -Schema $s -Instance (ConvertFrom-McpJson '{"a":1,"b":"x"}') -Engine $e } $schema $Engine
            $ok.IsValid | Should -BeTrue
            $ok.Errors | Should -BeNullOrEmpty
            $bad = Invoke-McpInModule { param($s, $e) Test-McpJsonSchema -Schema $s -Instance (ConvertFrom-McpJson '{"a":"one","c":true}') -Engine $e } $schema $Engine
            $bad.IsValid | Should -BeFalse
            ($bad.Errors -join "`n") | Should -Match '/a'
            ($bad.Errors -join "`n") | Should -Match 'c'
        }

        It 'evaluates schemas without $schema as 2020-12 (prefixItems, dependentRequired-free subset)' {
            if ($script:skip) { Set-ItResult -Skipped -Because "$Engine is not available"; return }
            $schema = '{"type":"array","prefixItems":[{"type":"integer"},{"type":"string"}],"items":{"type":"boolean"}}'
            (Invoke-McpInModule { param($s, $e) Test-McpJsonSchema -Schema $s -Instance (ConvertFrom-McpJson '[1,"a",true,false]') -Engine $e } $schema $Engine).IsValid | Should -BeTrue
            (Invoke-McpInModule { param($s, $e) Test-McpJsonSchema -Schema $s -Instance (ConvertFrom-McpJson '[1,"a",1]') -Engine $e } $schema $Engine).IsValid | Should -BeFalse
        }

        It 'validates <Keyword>' -ForEach @(
            @{ Keyword = 'enum'; Schema = '{"enum":["a",1,null]}'; Valid = @('"a"', '1', 'null'); Invalid = @('"b"', '2', 'true') }
            @{ Keyword = 'const'; Schema = '{"const":{"x":[1,2]}}'; Valid = @('{"x":[1,2]}'); Invalid = @('{"x":[2,1]}') }
            @{ Keyword = 'minimum/maximum'; Schema = '{"type":"number","minimum":1,"maximum":2}'; Valid = @('1', '1.5', '2'); Invalid = @('0.5', '2.5') }
            @{ Keyword = 'exclusiveMinimum'; Schema = '{"type":"integer","exclusiveMinimum":0}'; Valid = @('1'); Invalid = @('0', '1.5') }
            @{ Keyword = 'minLength/maxLength'; Schema = '{"type":"string","minLength":2,"maxLength":3}'; Valid = @('"ab"', '"abc"'); Invalid = @('"a"', '"abcd"') }
            @{ Keyword = 'pattern'; Schema = '{"type":"string","pattern":"^[a-z]+$"}'; Valid = @('"abc"'); Invalid = @('"ab1"') }
            @{ Keyword = 'minItems/maxItems'; Schema = '{"type":"array","minItems":1,"maxItems":2}'; Valid = @('[1]', '[1,2]'); Invalid = @('[]', '[1,2,3]') }
            @{ Keyword = 'uniqueItems'; Schema = '{"type":"array","uniqueItems":true}'; Valid = @('[1,2]'); Invalid = @('[1,1]') }
            @{ Keyword = 'anyOf'; Schema = '{"anyOf":[{"type":"string"},{"type":"integer"}]}'; Valid = @('"a"', '1'); Invalid = @('true') }
            @{ Keyword = 'oneOf'; Schema = '{"oneOf":[{"type":"number"},{"type":"integer"}]}'; Valid = @('1.5'); Invalid = @('1', '"a"') }
            @{ Keyword = 'allOf'; Schema = '{"allOf":[{"type":"integer"},{"minimum":5}]}'; Valid = @('5'); Invalid = @('4', '5.5') }
            @{ Keyword = 'not'; Schema = '{"not":{"type":"string"}}'; Valid = @('1'); Invalid = @('"a"') }
            @{ Keyword = 'type array'; Schema = '{"type":["string","null"]}'; Valid = @('"a"', 'null'); Invalid = @('1') }
            @{ Keyword = 'local $ref'; Schema = '{"$defs":{"n":{"type":"integer"}},"type":"object","properties":{"v":{"$ref":"#/$defs/n"}}}'; Valid = @('{"v":1}'); Invalid = @('{"v":"x"}') }
            @{ Keyword = 'if/then/else'; Schema = '{"if":{"type":"string"},"then":{"minLength":2},"else":{"type":"integer"}}'; Valid = @('"ab"', '3'); Invalid = @('"a"', 'true') }
            @{ Keyword = 'additionalProperties schema'; Schema = '{"type":"object","additionalProperties":{"type":"integer"}}'; Valid = @('{"a":1}'); Invalid = @('{"a":"x"}') }
            @{ Keyword = 'boolean schema'; Schema = '{"type":"object","properties":{"a":false}}'; Valid = @('{}'); Invalid = @('{"a":1}') }
        ) {
            if ($script:skip) { Set-ItResult -Skipped -Because "$Engine is not available"; return }
            foreach ($instance in $Valid) {
                $result = Invoke-McpInModule { param($s, $i, $e) Test-McpJsonSchema -Schema $s -Instance (ConvertFrom-McpJson $i) -Engine $e } $Schema $instance $Engine
                $result.IsValid | Should -BeTrue -Because "$instance should satisfy $Schema ($Engine)"
            }
            foreach ($instance in $Invalid) {
                $result = Invoke-McpInModule { param($s, $i, $e) Test-McpJsonSchema -Schema $s -Instance (ConvertFrom-McpJson $i) -Engine $e } $Schema $instance $Engine
                $result.IsValid | Should -BeFalse -Because "$instance should violate $Schema ($Engine)"
            }
        }

        It 'accepts hashtable and PSObject instances' {
            if ($script:skip) { Set-ItResult -Skipped -Because "$Engine is not available"; return }
            $schema = @{ type = 'object'; properties = @{ n = @{ type = 'integer' } }; required = @('n') }
            (Invoke-McpInModule { param($s, $e) Test-McpJsonSchema -Schema $s -Instance @{ n = 1 } -Engine $e } $schema $Engine).IsValid | Should -BeTrue
            (Invoke-McpInModule { param($s, $e) Test-McpJsonSchema -Schema $s -Instance ([pscustomobject]@{ n = 'x' }) -Engine $e } $schema $Engine).IsValid | Should -BeFalse
        }
    }

    It 'rejects external references, unsupported dialects and oversized schemas before evaluation' {
        { Invoke-McpInModule { Test-McpJsonSchema -Schema '{"$ref":"https://example.com/schema.json"}' -Instance 1 } } | Should -Throw -ExpectedMessage '*external*'
        { Invoke-McpInModule { Test-McpJsonSchema -Schema '{"properties":{"a":{"$ref":"http://example.com/x"}}}' -Instance 1 } } | Should -Throw
        { Invoke-McpInModule { Test-McpJsonSchema -Schema '{"$schema":"http://json-schema.org/draft-04/schema#","type":"string"}' -Instance 'x' } } | Should -Throw -ExpectedMessage '*dialect*'
        $deep = ('{"properties":{"a":' * 40) + '{}' + ('}}' * 40)
        { Invoke-McpInModule { param($s) Test-McpJsonSchema -Schema $s -Instance @{} } $deep } | Should -Throw -ExpectedMessage '*deeper*'
    }
}

Describe 'New-McpToolInputSchema' {
    BeforeAll {
        function script:Get-McpTestWeather {
            <#
            .SYNOPSIS
                Returns the weather.
            .PARAMETER Location
                City or postal code.
            .PARAMETER Units
                Unit system.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Schema fixture; the parameters are only inspected.')]
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string] $Location,

                [ValidateSet('metric', 'imperial')]
                [string] $Units = 'metric',

                [ValidateRange(1, 10)]
                [int] $Days = 3,

                [switch] $Detailed,

                [ValidateLength(1, 5)]
                [string[]] $Tags,

                [datetime] $When,

                [System.DayOfWeek] $Day,

                [Parameter(HelpMessage = 'Ignored by the tool.')]
                [hashtable] $Options,

                [object] $Context
            )
        }
        $script:command = Get-Command -Name Get-McpTestWeather
    }

    It 'maps parameter types, validation attributes, help and defaults' {
        $generated = Invoke-McpInModule {
            param($c)
            $help = Get-McpCommandHelp -Ast $c.ScriptBlock.Ast
            $defaults = Get-McpParameterDefaultValue -Ast $c.ScriptBlock.Ast
            New-McpToolInputSchema -Parameters $c.Parameters -Help $help -Defaults $defaults
        } $script:command
        $schema = $generated.Schema
        $schema['type'] | Should -Be 'object'
        $schema['additionalProperties'] | Should -BeFalse
        @($schema['required']) | Should -Be @('Location')
        @($schema['properties'].Keys) | Should -Be @('Location', 'Units', 'Days', 'Detailed', 'Tags', 'When', 'Day', 'Options')
        $schema['properties']['Location']['type'] | Should -Be 'string'
        $schema['properties']['Location']['description'] | Should -Be 'City or postal code.'
        $schema['properties']['Units']['enum'] | Should -Be @('metric', 'imperial')
        $schema['properties']['Units']['default'] | Should -Be 'metric'
        $schema['properties']['Days']['type'] | Should -Be 'integer'
        $schema['properties']['Days']['minimum'] | Should -Be 1
        $schema['properties']['Days']['maximum'] | Should -Be 10
        $schema['properties']['Days']['default'] | Should -Be 3
        $schema['properties']['Detailed']['type'] | Should -Be 'boolean'
        $schema['properties']['Tags']['type'] | Should -Be 'array'
        $schema['properties']['Tags']['items']['type'] | Should -Be 'string'
        $schema['properties']['Tags']['minLength'] | Should -Be 1
        $schema['properties']['When']['format'] | Should -Be 'date-time'
        $schema['properties']['Day']['enum'] | Should -Contain 'Monday'
        $schema['properties']['Options']['type'] | Should -Be 'object'
        $schema['properties']['Options']['description'] | Should -Be 'Ignored by the tool.'
        $generated.ParameterTypes['Days'] | Should -Be ([int])
        (Invoke-McpInModule { param($s) ConvertTo-McpJson $s } $schema) | Should -Match '"required":\["Location"\]'
    }

    It 'excludes common parameters and the Context parameter' {
        $generated = Invoke-McpInModule { param($c) New-McpToolInputSchema -Parameters $c.Parameters } $script:command
        $generated.Schema['properties'].Contains('Verbose') | Should -BeFalse
        $generated.Schema['properties'].Contains('ErrorAction') | Should -BeFalse
        $generated.Schema['properties'].Contains('Context') | Should -BeFalse
    }

    It 'produces the recommended schema for a command without parameters' {
        function script:Get-McpTestNothing { [CmdletBinding()] param() }
        $generated = Invoke-McpInModule { param($c) New-McpToolInputSchema -Parameters $c.Parameters } (Get-Command Get-McpTestNothing)
        Invoke-McpInModule { param($s) ConvertTo-McpJson $s } $generated.Schema | Should -Be '{"type":"object","additionalProperties":false}'
    }

    It 'rejects SecureString, PSCredential and ScriptBlock parameters' {
        function script:Get-McpTestSecret { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Schema fixture.')] param([securestring] $Secret) }
        { Invoke-McpInModule { param($c) New-McpToolInputSchema -Parameters $c.Parameters } (Get-Command Get-McpTestSecret) } | Should -Throw -ExpectedMessage '*SecureString*'
    }

    It 'validates generated schemas with both engines identically' {
        $generated = Invoke-McpInModule { param($c) New-McpToolInputSchema -Parameters $c.Parameters } $script:command
        foreach ($engine in $script:engines) {
            $ok = Invoke-McpInModule { param($s, $e) Test-McpJsonSchema -Schema $s -Instance (ConvertFrom-McpJson '{"Location":"Berlin","Days":2,"Units":"metric"}') -Engine $e } $generated.Schema $engine
            $ok.IsValid | Should -BeTrue -Because $engine
            $bad = Invoke-McpInModule { param($s, $e) Test-McpJsonSchema -Schema $s -Instance (ConvertFrom-McpJson '{"Days":"two","Units":"kelvin","Extra":1}') -Engine $e } $generated.Schema $engine
            $bad.IsValid | Should -BeFalse -Because $engine
            $bad.Errors.Count | Should -BeGreaterOrEqual 3 -Because $engine
        }
    }
}
