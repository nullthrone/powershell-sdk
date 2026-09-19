[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force
}

Describe 'Header value encoding (SEP-2243 value encoding table)' {
    It 'encodes <Name> as <Expected>' -TestCases @(
        @{ Name = 'plain ASCII'; Value = 'us-west1'; Type = 'string'; Expected = 'us-west1' }
        @{ Name = 'internal spaces'; Value = 'us west 1'; Type = 'string'; Expected = 'us west 1' }
        @{ Name = 'an empty string'; Value = ''; Type = 'string'; Expected = '' }
        @{ Name = 'non-ASCII text'; Value = 'Hello, 世界'; Type = 'string'; Expected = '=?base64?SGVsbG8sIOS4lueVjA==?=' }
        @{ Name = 'padded text'; Value = ' padded '; Type = 'string'; Expected = '=?base64?IHBhZGRlZCA=?=' }
        @{ Name = 'a newline'; Value = "line1`nline2"; Type = 'string'; Expected = '=?base64?bGluZTEKbGluZTI=?=' }
        @{ Name = 'the sentinel pattern itself'; Value = '=?base64?literal?='; Type = 'string'; Expected = '=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=' }
        @{ Name = 'a leading tab'; Value = "`tindented"; Type = 'string'; Expected = '=?base64?CWluZGVudGVk?=' }
        @{ Name = 'an integer'; Value = 42; Type = 'integer'; Expected = '42' }
        @{ Name = 'a negative long'; Value = [long] -7; Type = 'integer'; Expected = '-7' }
        @{ Name = 'an integral double'; Value = [double] 42; Type = 'integer'; Expected = '42' }
        @{ Name = 'true'; Value = $true; Type = 'boolean'; Expected = 'true' }
        @{ Name = 'false'; Value = $false; Type = 'boolean'; Expected = 'false' }
    ) {
        Invoke-McpInModule { param($v, $t) ConvertTo-McpHeaderValue -Value $v -Type $t } -Parameters @{ v = $Value; t = $Type } | Should -BeExactly $Expected
    }

    It 'rejects non-integral and non-boolean values for integer and boolean headers' {
        { Invoke-McpInModule { ConvertTo-McpHeaderValue -Value 1.5 -Type integer } } | Should -Throw -ExpectedMessage '*integral*'
        { Invoke-McpInModule { ConvertTo-McpHeaderValue -Value 'yes' -Type boolean } } | Should -Throw -ExpectedMessage '*boolean*'
    }

    It 'decodes the sentinel, trims whitespace and keeps literals' {
        Invoke-McpInModule { ConvertFrom-McpHeaderValue -Value '=?base64?SGVsbG8sIOS4lueVjA==?=' } | Should -BeExactly 'Hello, 世界'
        Invoke-McpInModule { ConvertFrom-McpHeaderValue -Value '  echo  ' } | Should -BeExactly 'echo'
        Invoke-McpInModule { ConvertFrom-McpHeaderValue -Value 'SGVsbG8=' } | Should -BeExactly 'SGVsbG8='
        Invoke-McpInModule { ConvertFrom-McpHeaderValue -Value '=?base64?SGVsbG8=' } | Should -BeExactly '=?base64?SGVsbG8='
        Invoke-McpInModule { ConvertFrom-McpHeaderValue -Value '=?base64??=' } | Should -BeExactly ''
    }

    It 'reports malformed Base64 in the sentinel as a header mismatch' -TestCases @(
        @{ Value = '=?base64?SGVsbG8?=' }
        @{ Value = '=?base64?SGVs!!!bG8=?=' }
    ) {
        $exception = $null
        try { Invoke-McpInModule { param($v) ConvertFrom-McpHeaderValue -Value $v } -Parameters @{ v = $Value } } catch { $exception = $_.Exception }
        $exception | Should -BeOfType [McpProtocolException]
        $exception.Code | Should -Be -32020
    }

    It 'compares integers numerically, booleans and strings exactly' {
        Invoke-McpInModule { Test-McpHeaderValueMatch -HeaderValue '42.0' -BodyValue 42 -Type integer } | Should -BeTrue
        Invoke-McpInModule { Test-McpHeaderValueMatch -HeaderValue '41' -BodyValue 42 -Type integer } | Should -BeFalse
        Invoke-McpInModule { Test-McpHeaderValueMatch -HeaderValue '42' -BodyValue '42' -Type integer } | Should -BeFalse
        Invoke-McpInModule { Test-McpHeaderValueMatch -HeaderValue 'true' -BodyValue $true -Type boolean } | Should -BeTrue
        Invoke-McpInModule { Test-McpHeaderValueMatch -HeaderValue 'True' -BodyValue $true -Type boolean } | Should -BeFalse
        Invoke-McpInModule { Test-McpHeaderValueMatch -HeaderValue 'Region' -BodyValue 'region' -Type string } | Should -BeFalse
        Invoke-McpInModule { Test-McpHeaderValueMatch -HeaderValue 'x' -BodyValue $null -Type string } | Should -BeFalse
    }

    It 'derives Mcp-Name from params.name or params.uri for the named methods only' {
        Invoke-McpInModule { Get-McpStandardHeaderName -Method 'tools/call' -Params ([ordered]@{ name = 'echo' }) } | Should -Be 'echo'
        Invoke-McpInModule { Get-McpStandardHeaderName -Method 'prompts/get' -Params ([ordered]@{ name = 'p' }) } | Should -Be 'p'
        Invoke-McpInModule { Get-McpStandardHeaderName -Method 'resources/read' -Params ([ordered]@{ uri = 'file:///a' }) } | Should -Be 'file:///a'
        Invoke-McpInModule { Get-McpStandardHeaderName -Method 'tools/list' -Params ([ordered]@{ name = 'x' }) } | Should -BeNullOrEmpty
        Invoke-McpInModule { Get-McpStandardHeaderName -Method 'tools/call' -Params ([ordered]@{ name = 5 }) } | Should -BeNullOrEmpty
    }
}

Describe 'x-mcp-header annotations (SEP-2243 schema extension)' {
    It 'collects annotations reachable through properties chains with their paths and types' {
        $schema = [ordered]@{
            type       = 'object'
            properties = [ordered]@{
                region  = [ordered]@{ type = 'string'; 'x-mcp-header' = 'Region' }
                options = [ordered]@{ type = 'object'; properties = [ordered]@{ priority = [ordered]@{ type = 'integer'; 'x-mcp-header' = 'Priority' } } }
                verbose = [ordered]@{ type = 'boolean'; 'x-mcp-header' = 'Verbose' }
                query   = [ordered]@{ type = 'string' }
            }
        }
        $parameters = @(Invoke-McpInModule { param($s) Get-McpToolHeaderParameter -InputSchema $s } -Parameters @{ s = $schema })
        $parameters.Count | Should -Be 3
        @($parameters | ForEach-Object { ($_.Path -join '.') + '=' + $_.Header + ':' + $_.Type }) | Should -Be @('region=Region:string', 'options.priority=Priority:integer', 'verbose=Verbose:boolean')
        @(Invoke-McpInModule { Get-McpToolHeaderParameter -InputSchema ([ordered]@{ type = 'object' }) }).Count | Should -Be 0
        @(Invoke-McpInModule { Get-McpToolHeaderParameter -InputSchema $null }).Count | Should -Be 0
    }

    It 'rejects <Name>' -TestCases @(
        @{ Name = 'an empty header name'; Property = @{ type = 'string'; 'x-mcp-header' = '' }; Reason = 'non-empty' }
        @{ Name = 'an object-typed property'; Property = @{ type = 'object'; 'x-mcp-header' = 'Data' }; Reason = 'only string, integer and boolean' }
        @{ Name = 'an array-typed property'; Property = @{ type = 'array'; items = @{ type = 'string' }; 'x-mcp-header' = 'Items' }; Reason = 'only string, integer and boolean' }
        @{ Name = 'a null-typed property'; Property = @{ type = 'null'; 'x-mcp-header' = 'Nil' }; Reason = 'only string, integer and boolean' }
        @{ Name = 'a number-typed property'; Property = @{ type = 'number'; 'x-mcp-header' = 'Amount' }; Reason = 'only string, integer and boolean' }
        @{ Name = 'a property without a type'; Property = @{ 'x-mcp-header' = 'Untyped' }; Reason = 'only string, integer and boolean' }
        @{ Name = 'a space in the header name'; Property = @{ type = 'string'; 'x-mcp-header' = 'My Region' }; Reason = 'field-name token' }
        @{ Name = 'a colon in the header name'; Property = @{ type = 'string'; 'x-mcp-header' = 'Region:Primary' }; Reason = 'field-name token' }
        @{ Name = 'a non-ASCII header name'; Property = @{ type = 'string'; 'x-mcp-header' = 'Région' }; Reason = 'field-name token' }
        @{ Name = 'a control character in the header name'; Property = @{ type = 'string'; 'x-mcp-header' = "Region`t1" }; Reason = 'field-name token' }
        @{ Name = 'a non-string header name'; Property = @{ type = 'string'; 'x-mcp-header' = 5 }; Reason = 'non-empty string' }
    ) {
        $schema = @{ type = 'object'; properties = @{ value = $Property } }
        { Invoke-McpInModule { param($s) Get-McpToolHeaderParameter -InputSchema $s } -Parameters @{ s = $schema } } | Should -Throw -ExpectedMessage "*$Reason*"
    }

    It 'rejects duplicate header names, also across letter case' {
        $same = @{ type = 'object'; properties = @{ a = @{ type = 'string'; 'x-mcp-header' = 'Region' }; b = @{ type = 'string'; 'x-mcp-header' = 'Region' } } }
        { Invoke-McpInModule { param($s) Get-McpToolHeaderParameter -InputSchema $s } -Parameters @{ s = $same } } | Should -Throw -ExpectedMessage '*more than once*'
        $mixed = @{ type = 'object'; properties = @{ a = @{ type = 'string'; 'x-mcp-header' = 'MyField' }; b = @{ type = 'string'; 'x-mcp-header' = 'myfield' } } }
        { Invoke-McpInModule { param($s) Get-McpToolHeaderParameter -InputSchema $s } -Parameters @{ s = $mixed } } | Should -Throw -ExpectedMessage '*more than once*'
    }

    It 'rejects annotations that are not statically reachable' -TestCases @(
        @{ Name = 'inside items'; Schema = @{ type = 'object'; properties = @{ list = @{ type = 'array'; items = @{ type = 'string'; 'x-mcp-header' = 'Item' } } } } }
        @{ Name = 'inside anyOf'; Schema = @{ type = 'object'; properties = @{ v = @{ anyOf = @(@{ type = 'string'; 'x-mcp-header' = 'V' }, @{ type = 'integer' }) } } } }
        @{ Name = 'inside $defs'; Schema = @{ type = 'object'; '$defs' = @{ region = @{ type = 'string'; 'x-mcp-header' = 'Region' } }; properties = @{ region = @{ '$ref' = '#/$defs/region' } } } }
        @{ Name = 'inside then'; Schema = @{ type = 'object'; if = @{ properties = @{ a = @{ const = 1 } } }; then = @{ properties = @{ b = @{ type = 'string'; 'x-mcp-header' = 'B' } } } } }
        @{ Name = 'on the root'; Schema = @{ type = 'object'; 'x-mcp-header' = 'Root'; properties = @{} } }
    ) {
        { Invoke-McpInModule { param($s) Get-McpToolHeaderParameter -InputSchema $s } -Parameters @{ s = $Schema } } | Should -Throw -ExpectedMessage '*reachable*'
    }

    It 'builds Mcp-Param headers from arguments and omits absent or null values' {
        $parameters = @(
            @{ Path = @('region'); Header = 'Region'; Type = 'string' }
            @{ Path = @('priority'); Header = 'Priority'; Type = 'integer' }
            @{ Path = @('verbose'); Header = 'Verbose'; Type = 'boolean' }
            @{ Path = @('nested', 'value'); Header = 'Nested'; Type = 'string' }
        )
        $arguments = [ordered]@{ region = 'Hello, 世界'; priority = 3; verbose = $null; nested = [ordered]@{ value = 'x' }; query = 'q' }
        $headers = Invoke-McpInModule { param($p, $a) Get-McpToolCallHeader -HeaderParameters $p -Arguments $a } -Parameters @{ p = $parameters; a = $arguments }
        $headers.Count | Should -Be 3
        $headers['Mcp-Param-Region'] | Should -Be '=?base64?SGVsbG8sIOS4lueVjA==?='
        $headers['Mcp-Param-Priority'] | Should -Be '3'
        $headers['Mcp-Param-Nested'] | Should -Be 'x'
        (Invoke-McpInModule { param($p) Get-McpToolCallHeader -HeaderParameters $p -Arguments $null } -Parameters @{ p = $parameters }).Count | Should -Be 0
    }

    It 'validates received Mcp-Param headers against the body' {
        $parameters = @(@{ Path = @('region'); Header = 'Region'; Type = 'string' }, @{ Path = @('priority'); Header = 'Priority'; Type = 'integer' })
        $check = {
            param($headerTable, $arguments)
            $collection = [System.Collections.Specialized.NameValueCollection]::new()
            foreach ($key in $headerTable.Keys) { $collection.Add($key, $headerTable[$key]) }
            try {
                Invoke-McpInModule { param($p, $a, $h) Test-McpToolParameterHeader -HeaderParameters $p -Arguments $a -Headers $h } -Parameters @{ p = $parameters; a = $arguments; h = $collection }
                'accepted'
            } catch {
                "$($_.Exception.Code)"
            }
        }
        & $check @{ 'Mcp-Param-Region' = 'Hello'; 'mcp-param-priority' = '42.0' } ([ordered]@{ region = 'Hello'; priority = 42 }) | Should -Be 'accepted'
        & $check @{ 'Mcp-Param-Region' = '=?base64?SGVsbG8=?=' } ([ordered]@{ region = 'Hello' }) | Should -Be 'accepted'
        & $check @{ 'Mcp-Param-Region' = 'SGVsbG8=' } ([ordered]@{ region = 'SGVsbG8=' }) | Should -Be 'accepted'
        & $check @{} ([ordered]@{ query = 'q' }) | Should -Be 'accepted'
        & $check @{} ([ordered]@{ region = $null }) | Should -Be 'accepted'
        & $check @{} ([ordered]@{ region = 'Hello' }) | Should -Be '-32020'
        & $check @{ 'Mcp-Param-Region' = 'World' } ([ordered]@{ region = 'Hello' }) | Should -Be '-32020'
        & $check @{ 'Mcp-Param-Region' = '=?base64?SGVsbG8?=' } ([ordered]@{ region = 'Hello' }) | Should -Be '-32020'
        & $check @{ 'Mcp-Param-Region' = 'Hello' } ([ordered]@{ query = 'q' }) | Should -Be '-32020'
        & $check @{ 'Mcp-Param-Priority' = '41' } ([ordered]@{ priority = 42 }) | Should -Be '-32020'
    }
}

Describe 'Register-McpTool -Header' {
    It 'annotates the generated schema and records the header parameters' {
        $server = New-McpServer -Name 'headers' -Version '1'
        $registration = Register-McpTool -Name 'lookup' -ScriptBlock { param([Parameter(Mandatory)][string] $Region, [int] $Priority = 1, [string] $Query = '') "$Region $Priority $Query" } -Header @{ region = 'Region'; Priority = 'Priority' } -Server $server -PassThru
        $registration.InputSchema['properties']['Region']['x-mcp-header'] | Should -Be 'Region'
        $registration.InputSchema['properties']['Priority']['x-mcp-header'] | Should -Be 'Priority'
        $registration.InputSchema['properties']['Query'].Contains('x-mcp-header') | Should -BeFalse
        @($registration.HeaderParameters | ForEach-Object { $_.Path -join '.' }) | Should -Be @('Region', 'Priority')
        (Test-McpSpecShape -Definition 'Tool' -Instance (Invoke-McpInModule { param($r) ConvertTo-McpToolDefinition -Registration $r } -Parameters @{ r = $registration })).IsValid | Should -BeTrue
    }

    It 'rejects unknown parameters, non-primitive parameters and invalid header names' {
        $server = New-McpServer -Name 'headers' -Version '1'
        { Register-McpTool -Name 'a' -ScriptBlock { param([string] $Region) $Region } -Header @{ Missing = 'X' } -Server $server } | Should -Throw -ExpectedMessage '*not a property*'
        { Register-McpTool -Name 'b' -ScriptBlock { param([hashtable] $Options) $Options } -Header @{ Options = 'Options' } -Server $server } | Should -Throw -ExpectedMessage '*only string, integer and boolean*'
        { Register-McpTool -Name 'c' -ScriptBlock { param([string] $Region) $Region } -Header @{ Region = 'My Region' } -Server $server } | Should -Throw -ExpectedMessage '*field-name token*'
        { Register-McpTool -Name 'd' -ScriptBlock { param([string] $A, [string] $B) "$A$B" } -Header @{ A = 'Same'; B = 'same' } -Server $server } | Should -Throw -ExpectedMessage '*more than once*'
        { Register-McpTool -Name 'e' -ScriptBlock { param([hashtable] $Arguments) $Arguments } -InputSchema @{ type = 'object'; properties = @{ v = @{ type = 'object'; 'x-mcp-header' = 'V' } } } -Server $server } | Should -Throw -ExpectedMessage '*invalid x-mcp-header*'
    }
}

Describe 'HTTP status codes and Origin validation' {
    It 'maps JSON-RPC error codes to HTTP statuses' -TestCases @(
        @{ Code = $null; Expected = 200 }
        @{ Code = -32700; Expected = 400 }
        @{ Code = -32600; Expected = 400 }
        @{ Code = -32602; Expected = 400 }
        @{ Code = -32020; Expected = 400 }
        @{ Code = -32021; Expected = 400 }
        @{ Code = -32022; Expected = 400 }
        @{ Code = -32601; Expected = 404 }
        @{ Code = -32603; Expected = 200 }
        @{ Code = -32000; Expected = 200 }
    ) {
        Invoke-McpInModule { param($c) Get-McpHttpStatusCode -ErrorCode $c } -Parameters @{ c = $Code } | Should -Be $Expected
    }

    It 'accepts only Host headers that name the endpoint host and port' {
        $test = { param($u, $h) Invoke-McpInModule { param($u, $h) Test-McpHttpHost -Transport @{ Url = [uri] $u } -HostHeader $h } -Parameters @{ u = $u; h = $h } }
        & $test 'http://127.0.0.1:8080/mcp/' '127.0.0.1:8080' | Should -BeTrue
        & $test 'http://127.0.0.1:8080/mcp/' ' 127.0.0.1:8080 ' | Should -BeTrue
        & $test 'http://localhost:8080/mcp/' 'LOCALHOST:8080' | Should -BeTrue
        & $test 'http://localhost/mcp/' 'localhost' | Should -BeTrue
        & $test 'http://localhost/mcp/' 'localhost:80' | Should -BeTrue
        & $test 'https://mcp.example.com/mcp/' 'mcp.example.com' | Should -BeTrue
        & $test 'https://mcp.example.com/mcp/' 'mcp.example.com:443' | Should -BeTrue
        & $test 'http://[::1]:8080/mcp/' '[::1]:8080' | Should -BeTrue
        & $test 'http://127.0.0.1:8080/mcp/' '127.0.0.1' | Should -BeFalse
        & $test 'http://127.0.0.1:8080/mcp/' '127.0.0.1:1' | Should -BeFalse
        & $test 'http://127.0.0.1:8080/mcp/' 'evil.example.com' | Should -BeFalse
        & $test 'http://127.0.0.1:8080/mcp/' 'evil.example.com:8080' | Should -BeFalse
        & $test 'http://127.0.0.1:8080/mcp/' '127.0.0.1:' | Should -BeFalse
        & $test 'http://127.0.0.1:8080/mcp/' '127.0.0.1:x' | Should -BeFalse
        & $test 'http://[::1]:8080/mcp/' '[::1' | Should -BeFalse
        & $test 'http://[::1]:8080/mcp/' '[::1]8080' | Should -BeFalse
        & $test 'http://127.0.0.1:8080/mcp/' '' | Should -BeFalse
        & $test 'http://127.0.0.1:8080/mcp/' $null | Should -BeFalse
    }

    It 'accepts loopback and own origins by default and honours an allow list' {
        $transport = @{ Url = [uri] 'http://127.0.0.1:8080/mcp/'; AllowedOrigins = @() }
        $test = { param($t, $o) Invoke-McpInModule { param($t, $o) Test-McpHttpOrigin -Transport $t -Origin $o } -Parameters @{ t = $t; o = $o } }
        & $test $transport $null | Should -BeTrue
        & $test $transport 'http://localhost:3000' | Should -BeTrue
        & $test $transport 'http://127.0.0.1' | Should -BeTrue
        & $test $transport 'https://[::1]:8443' | Should -BeTrue
        & $test $transport 'http://127.0.0.1:8080' | Should -BeTrue
        & $test $transport 'http://evil.example.com' | Should -BeFalse
        & $test $transport 'null' | Should -BeFalse
        & $test $transport 'file://x' | Should -BeFalse
        $listed = @{ Url = [uri] 'http://127.0.0.1:8080/mcp/'; AllowedOrigins = @('https://app.example.com') }
        & $test $listed 'https://app.example.com' | Should -BeTrue
        & $test $listed 'https://APP.example.com/' | Should -BeTrue
        & $test $listed 'http://localhost:3000' | Should -BeFalse
        $any = @{ Url = [uri] 'http://127.0.0.1:8080/mcp/'; AllowedOrigins = @('*') }
        & $test $any 'http://evil.example.com' | Should -BeTrue
    }
}

Describe 'SSE parsing' {
    It 'reads events with data lines, ignores comments, ids and unknown fields, and reports end of stream' {
        $lines = @(': connected', '', 'event: message', 'data: {"a":1}', '', ': keep-alive', '', 'id: 7', 'retry: 100', 'data: first', 'data: second', '', 'event: other', 'data: x', '', 'data:{"b":2}', '')
        $text = ($lines -join "`n") + "`n"
        $stream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($text))
        $events = Invoke-McpInModule {
            param($s)
            $sse = New-McpSseReader -Stream $s
            $result = [System.Collections.Generic.List[object]]::new()
            while ($true) {
                $received = Receive-McpSseEvent -Sse $sse -TimeoutMs 2000
                $result.Add($received)
                if ($received.Status -ne 'Event') { break }
            }
            $result.ToArray()
        } -Parameters @{ s = $stream }
        $events.Count | Should -Be 5
        $events[0].Event | Should -Be 'message'
        $events[0].Data | Should -Be '{"a":1}'
        $events[1].Event | Should -BeNullOrEmpty
        $events[1].Data | Should -Be "first`nsecond"
        $events[2].Event | Should -Be 'other'
        $events[3].Data | Should -Be '{"b":2}'
        $events[4].Status | Should -Be 'Eof'
    }
}
