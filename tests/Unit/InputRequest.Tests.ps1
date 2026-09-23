[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force

    function Get-TestContext {
        param(
            [System.Collections.IDictionary] $Capabilities = @{ elicitation = @{ form = @{}; url = @{} }; sampling = @{ tools = @{} }; roots = @{} },
            [System.Collections.IDictionary] $Responses = [ordered]@{},
            [string] $Kind = 'Tool'
        )
        $wire = Invoke-McpInModule { param($c, $r) @{ c = (ConvertFrom-McpJson (ConvertTo-McpJson -InputObject $c)); r = (ConvertFrom-McpJson (ConvertTo-McpJson -InputObject $r)) } } -Parameters @{ c = $Capabilities; r = $Responses }
        Invoke-McpInModule { param($e) New-McpRequestContext -Envelope $e } -Parameters @{ e = @{ Kind = $Kind; Method = 'tools/call'; Name = 't'; Meta = @{ ClientCapabilities = $wire.c }; InputResponses = $wire.r } }
    }
    function Get-ThrownException {
        # (Not named $Action: a script block that calls $Action would resolve it to this parameter.)
        param([scriptblock] $Code)
        try { & $Code; $null } catch { $_.Exception }
    }
    function ConvertTo-Wire {
        param($InputObject)
        Invoke-McpInModule { param($o) ConvertFrom-McpJson (ConvertTo-McpJson -InputObject $o) } -Parameters @{ o = $InputObject }
    }
}

Describe 'Request-McpElicitation' {
    It 'throws McpInputRequiredException with a form elicitation when the answer is missing' {
        $context = Get-TestContext
        $exception = Get-ThrownException { Request-McpElicitation -Context $context -Key 'user_name' -Message 'What is your name?' -Schema @{ name = @{ type = 'string' } } -Required name }
        $exception | Should -BeOfType [McpInputRequiredException]
        $request = $exception.InputRequests['user_name']
        $request['method'] | Should -Be 'elicitation/create'
        $request['params']['mode'] | Should -Be 'form'
        $request['params']['message'] | Should -Be 'What is your name?'
        $request['params']['requestedSchema']['type'] | Should -Be 'object'
        $request['params']['requestedSchema']['required'] | Should -Be @('name')
        (Test-McpSpecShape -Definition 'InputRequests' -Instance (ConvertTo-Wire $exception.InputRequests)).IsValid | Should -BeTrue
    }

    It 'returns the accepted answer as Mcp.ElicitResult' {
        $context = Get-TestContext -Responses ([ordered]@{ user_name = @{ action = 'accept'; content = @{ name = 'Ada' } } })
        $answer = Request-McpElicitation -Context $context -Key 'user_name' -Message 'Name?' -Schema @{ name = @{ type = 'string' } } -Required name
        $answer.PSObject.TypeNames | Should -Contain 'Mcp.ElicitResult'
        $answer.Action | Should -Be 'accept'
        $answer.Accepted | Should -BeTrue
        $answer.Content.name | Should -Be 'Ada'
        $context.ConsumedInput.Contains('user_name') | Should -BeTrue
    }

    It 'returns declined and cancelled answers without content' {
        $context = Get-TestContext -Responses ([ordered]@{ a = @{ action = 'decline' }; b = @{ action = 'cancel' } })
        (Request-McpElicitation -Context $context -Key 'a' -Message 'm' -Schema @{ x = @{ type = 'string' } }).Accepted | Should -BeFalse
        (Request-McpElicitation -Context $context -Key 'b' -Message 'm' -Schema @{ x = @{ type = 'string' } }).Action | Should -Be 'cancel'
    }

    It 'rejects <Case> with -32602' -TestCases @(
        @{ Case = 'a response that is not an object'; Response = 'yes' }
        @{ Case = 'an unknown action'; Response = @{ action = 'maybe' } }
        @{ Case = 'content of the wrong type'; Response = @{ action = 'accept'; content = @{ name = 12345 } } }
        @{ Case = 'content without a required property'; Response = @{ action = 'accept'; content = @{} } }
    ) {
        param($Case, $Response)
        $null = $Case
        $context = Get-TestContext -Responses ([ordered]@{ user_name = $Response })
        $exception = Get-ThrownException { Request-McpElicitation -Context $context -Key 'user_name' -Message 'Name?' -Schema @{ name = @{ type = 'string' } } -Required name }
        $exception | Should -BeOfType [McpProtocolException]
        $exception.Code | Should -Be -32602
    }

    It 'asks for a URL in URL mode' {
        $exception = Get-ThrownException { Request-McpElicitation -Context (Get-TestContext) -Key 'login' -Message 'Sign in' -Url 'https://example.com/login' }
        $params = $exception.InputRequests['login']['params']
        $params['mode'] | Should -Be 'url'
        $params['url'] | Should -Be 'https://example.com/login'
        (Test-McpSpecShape -Definition 'ElicitRequestURLParams' -Instance (ConvertTo-Wire $params)).IsValid | Should -BeTrue
    }

    It 'fails with -32021 and the required capability when the client did not declare <Case>' -TestCases @(
        @{ Case = 'elicitation'; Capabilities = @{ sampling = @{} }; Action = { param($c) Request-McpElicitation -Context $c -Key 'k' -Message 'm' -Schema @{ x = @{ type = 'string' } } }; Path = 'elicitation', 'form' }
        @{ Case = 'URL mode'; Capabilities = @{ elicitation = @{ form = @{} } }; Action = { param($c) Request-McpElicitation -Context $c -Key 'k' -Message 'm' -Url 'https://example.com' }; Path = 'elicitation', 'url' }
        @{ Case = 'sampling'; Capabilities = @{ elicitation = @{} }; Action = { param($c) Request-McpSampling -Context $c -Key 'k' -Messages 'hi' }; Path = @('sampling') }
        @{ Case = 'sampling with tools'; Capabilities = @{ sampling = @{} }; Action = { param($c) Request-McpSampling -Context $c -Key 'k' -Messages 'hi' -Tools @(@{ name = 'x'; inputSchema = @{ type = 'object' } }) }; Path = 'sampling', 'tools' }
        @{ Case = 'roots'; Capabilities = @{}; Action = { param($c) Request-McpRoot -Context $c -Key 'k' }; Path = @('roots') }
    ) {
        param($Case, $Capabilities, $Action, $Path)
        $null = $Case
        $context = Get-TestContext -Capabilities $Capabilities
        $request = $Action
        $exception = Get-ThrownException { & $request $context }
        $exception | Should -BeOfType [McpProtocolException]
        $exception | Should -Not -BeOfType [McpInputRequiredException]
        $exception.Code | Should -Be -32021
        $node = $exception.Data['requiredCapabilities']
        foreach ($segment in $Path) { $node.Contains($segment) | Should -BeTrue; $node = $node[$segment] }
        $context.PendingInput.Count | Should -Be 0
    }

    It 'treats an empty elicitation capability as form mode' {
        $exception = Get-ThrownException { Request-McpElicitation -Context (Get-TestContext -Capabilities @{ elicitation = @{} }) -Key 'k' -Message 'm' -Schema @{ x = @{ type = 'boolean' } } }
        $exception | Should -BeOfType [McpInputRequiredException]
    }

    It 'throws outside of a tools/call, prompts/get or resources/read handler' {
        { Request-McpElicitation -Context (Get-TestContext -Kind 'Completion') -Key 'k' -Message 'm' -Schema @{ x = @{ type = 'string' } } } | Should -Throw -ExpectedMessage '*request context*'
    }
}

Describe 'Deferred input requests' {
    It 'collects several requests into one round with Wait-McpInput' {
        $context = Get-TestContext
        $name = Request-McpElicitation -Context $context -Key 'user_name' -Message 'Name?' -Schema @{ name = @{ type = 'string' } } -Defer
        $greeting = Request-McpSampling -Context $context -Key 'greeting' -Messages 'Generate a greeting' -MaxTokens 50 -Defer
        $roots = Request-McpRoot -Context $context -Key 'client_roots' -Defer
        $name | Should -BeNullOrEmpty
        $greeting | Should -BeNullOrEmpty
        $roots | Should -BeNullOrEmpty
        $exception = Get-ThrownException { Wait-McpInput -Context $context }
        $exception | Should -BeOfType [McpInputRequiredException]
        @($exception.InputRequests.Keys) | Should -Be @('user_name', 'greeting', 'client_roots')
        @($exception.InputRequests.Values | ForEach-Object { $_['method'] }) | Should -Be @('elicitation/create', 'sampling/createMessage', 'roots/list')
        (Test-McpSpecShape -Definition 'InputRequests' -Instance (ConvertTo-Wire $exception.InputRequests)).IsValid | Should -BeTrue
    }

    It 'returns the answers and passes Wait-McpInput when all are there' {
        $context = Get-TestContext -Responses ([ordered]@{
                greeting     = @{ role = 'assistant'; content = @{ type = 'text'; text = 'Hi!' }; model = 'm1'; stopReason = 'endTurn' }
                client_roots = @{ roots = @(@{ uri = 'file:///work'; name = 'work' }) }
            })
        $greeting = Request-McpSampling -Context $context -Key 'greeting' -Messages 'Generate a greeting' -Defer
        $roots = @(Request-McpRoot -Context $context -Key 'client_roots' -Defer)
        { Wait-McpInput -Context $context } | Should -Not -Throw
        $greeting.PSObject.TypeNames | Should -Contain 'Mcp.SamplingResult'
        $greeting.Text | Should -Be 'Hi!'
        $greeting.Model | Should -Be 'm1'
        $roots.Count | Should -Be 1
        $roots[0].PSObject.TypeNames | Should -Contain 'Mcp.Root'
        $roots[0].Uri | Should -Be 'file:///work'
    }

    It 'rejects malformed <Case> answers with -32602' -TestCases @(
        @{ Case = 'sampling'; Response = @{ role = 'robot'; content = @{ type = 'text'; text = 'x' }; model = 'm' }; Action = { param($c) Request-McpSampling -Context $c -Key 'k' -Messages 'hi' } }
        @{ Case = 'roots'; Response = @{ roots = @(@{ name = 'no uri' }) }; Action = { param($c) Request-McpRoot -Context $c -Key 'k' } }
    ) {
        param($Case, $Response, $Action)
        $null = $Case
        $context = Get-TestContext -Responses ([ordered]@{ k = $Response })
        $request = $Action
        (Get-ThrownException { & $request $context }).Code | Should -Be -32602
    }
}

Describe 'Elicitation schemas' {
    It 'accepts the primitive schema <Case>' -TestCases @(
        @{ Case = 'string with format'; Property = @{ type = 'string'; format = 'email'; minLength = 3 } }
        @{ Case = 'number'; Property = @{ type = 'number'; minimum = 0 } }
        @{ Case = 'integer'; Property = @{ type = 'integer' } }
        @{ Case = 'boolean'; Property = @{ type = 'boolean'; default = $true } }
        @{ Case = 'untitled single-select enum'; Property = @{ type = 'string'; enum = @('a', 'b') } }
        @{ Case = 'titled single-select enum'; Property = @{ type = 'string'; oneOf = @(@{ const = 'a'; title = 'A' }) } }
        @{ Case = 'legacy titled enum'; Property = @{ type = 'string'; enum = @('a'); enumNames = @('A') } }
        @{ Case = 'untitled multi-select enum'; Property = @{ type = 'array'; items = @{ type = 'string'; enum = @('a', 'b') } } }
        @{ Case = 'titled multi-select enum'; Property = @{ type = 'array'; items = @{ anyOf = @(@{ const = 'a'; title = 'A' }) } } }
    ) {
        param($Case, $Property)
        $null = $Case
        $schema = Invoke-McpInModule { param($p) ConvertTo-McpElicitationSchema -Schema @{ field = $p } } -Parameters @{ p = $Property }
        (Test-McpSpecShape -Definition 'PrimitiveSchemaDefinition' -Instance (ConvertTo-Wire $schema['properties']['field'])).IsValid | Should -BeTrue
    }

    It 'accepts a full schema with its required list' {
        $schema = Invoke-McpInModule { ConvertTo-McpElicitationSchema -Schema @{ type = 'object'; properties = @{ ok = @{ type = 'boolean' } }; required = @('ok') } }
        $schema['required'] | Should -Be @('ok')
    }

    It 'rejects <Case>' -TestCases @(
        @{ Case = 'nested objects'; Schema = @{ address = @{ type = 'object'; properties = @{ city = @{ type = 'string' } } } }; Message = '*only string*' }
        @{ Case = 'arrays of free values'; Schema = @{ tags = @{ type = 'array'; items = @{ type = 'string' } } }; Message = '*multi-select*' }
        @{ Case = 'unknown string formats'; Schema = @{ ip = @{ type = 'string'; format = 'ipv4' } }; Message = '*format*' }
        @{ Case = 'a required property that is not defined'; Schema = @{ type = 'object'; properties = @{ a = @{ type = 'string' } }; required = @('b') }; Message = '*not defined*' }
    ) {
        param($Case, $Schema, $Message)
        $null = $Case
        $schemaUnderTest = $Schema
        { Invoke-McpInModule { param($s) ConvertTo-McpElicitationSchema -Schema $s } -Parameters @{ s = $schemaUnderTest } } | Should -Throw -ExpectedMessage $Message
    }
}

Describe 'InputRequiredResult' {
    It 'matches the specification schema and signs the answers accepted so far' {
        $context = Get-TestContext -Responses ([ordered]@{ step1 = @{ action = 'accept'; content = @{ name = 'Ada' } } })
        $null = Request-McpElicitation -Context $context -Key 'step1' -Message 'Step 1' -Schema @{ name = @{ type = 'string' } }
        $exception = Get-ThrownException { Request-McpElicitation -Context $context -Key 'step2' -Message 'Step 2' -Schema @{ color = @{ type = 'string' } } }
        $key = [byte[]] (1..32)
        $envelope = @{ RequestStateKey = $key; Method = 'tools/call'; Name = 't'; RequestDigest = 'd'; RequestStateTtlSeconds = 60 }
        $result = Invoke-McpInModule { param($r, $c, $e) Get-McpInputRequiredResult -InputRequests $r -Context $c -Envelope $e } -Parameters @{ r = $exception.InputRequests; c = $context; e = $envelope }
        (Test-McpSpecShape -Definition 'InputRequiredResult' -Instance (ConvertTo-Wire $result)).IsValid | Should -BeTrue
        @($result['inputRequests'].Keys) | Should -Be @('step2')
        $payload = Invoke-McpInModule { param($k, $t) Read-McpRequestState -Key $k -Token $t -Method 'tools/call' -Name 't' -Digest 'd' } -Parameters @{ k = $key; t = $result['requestState'] }
        $payload['a']['step1']['content']['name'] | Should -Be 'Ada'
        $payload['r']['step2'] | Should -Be 'elicitation/create'
    }
}
