[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force

    function script:New-InputServer {
        param([string] $Name = 'input')
        $server = New-McpServer -Name $Name -Version '1.0.0' -RequestTimeoutSeconds 10 -RequestStateKey 'a test key of sufficient length'
        Register-McpTool -Name 'two-rounds' -Description 'Asks two questions in two rounds.' -ScriptBlock {
            param([string] $Topic = 'x', $Context)
            $Context.State['rounds'] = 1 + [int] $Context.State['rounds']
            $first = Request-McpElicitation -Context $Context -Key 'step1' -Message "Name ($Topic)?" -Schema @{ name = @{ type = 'string' } } -Required name
            $second = Request-McpElicitation -Context $Context -Key 'step2' -Message 'Color?' -Schema @{ color = @{ type = 'string'; enum = @('red', 'green') } } -Required color
            "$($first.Content.name)/$($second.Content.color)/rounds=$($Context.State['rounds'])"
        } -Server $server
        Register-McpTool -Name 'all-at-once' -Description 'Asks for three inputs in one round.' -ScriptBlock {
            param($Context)
            $name = Request-McpElicitation -Context $Context -Key 'user_name' -Message 'Name?' -Schema @{ name = @{ type = 'string' } } -Defer
            $sample = Request-McpSampling -Context $Context -Key 'greeting' -Messages 'Greet' -MaxTokens 20 -Defer
            $roots = Request-McpRoot -Context $Context -Key 'client_roots' -Defer
            Wait-McpInput -Context $Context
            "$($name.Content.name)|$($sample.Text)|$(@($roots | ForEach-Object Uri) -join ',')"
        } -Server $server
        Register-McpTool -Name 'decline' -Description 'Reports the elicitation action.' -ScriptBlock {
            param($Context)
            (Request-McpElicitation -Context $Context -Key 'k' -Message 'Sure?' -Schema @{ ok = @{ type = 'boolean' } }).Action
        } -Server $server
        Register-McpPrompt -Name 'ask-prompt' -Description 'Asks for context first.' -ScriptBlock {
            param($Context)
            "Context: $((Request-McpElicitation -Context $Context -Key 'user_context' -Message 'Context?' -Schema @{ context = @{ type = 'string' } } -Required context).Content.context)"
        } -Server $server
        Register-McpResource -UriTemplate 'ask://{item}' -Name 'ask-resource' -Description 'Asks before it reads.' -ScriptBlock {
            param([string] $item, $Context)
            $answer = Request-McpElicitation -Context $Context -Key 'confirm' -Message "Read $item?" -Schema @{ ok = @{ type = 'boolean' } } -Required ok
            "read $item ok=$($answer.Content.ok)"
        } -Server $server
        $server
    }

    $script:elicitation = {
        param($Request)
        switch (@($Request.RequestedSchema['properties'].Keys)[0]) {
            'name' { @{ name = 'Ada' } }
            'color' { @{ color = 'green' } }
            'context' { @{ context = 'tests' } }
            'ok' { @{ ok = $true } }
        }
    }
}

Describe 'Multi-round-trip requests on the wire' -Tag 'Integration' {
    BeforeAll {
        $script:rawServer = New-InputServer -Name 'raw'
        $script:pair = Invoke-McpInModule { New-McpInMemoryTransportPair }
        $script:background = Invoke-McpInModule { param($s, $e) Start-McpBackgroundServer -Server $s -Endpoint $e } -Parameters @{ s = $script:rawServer; e = $script:pair.Server }
        $script:nextId = 100
        function script:Invoke-Raw {
            param([string] $Method = 'tools/call', [hashtable] $Params, [hashtable] $Capabilities = @{ elicitation = @{}; sampling = @{}; roots = @{} })
            $script:nextId++
            $all = [ordered]@{ _meta = [ordered]@{ 'io.modelcontextprotocol/protocolVersion' = '2026-07-28'; 'io.modelcontextprotocol/clientCapabilities' = $Capabilities } }
            foreach ($key in $Params.Keys) { $all[$key] = $Params[$key] }
            $line = Invoke-McpInModule { param($r) ConvertTo-McpJson -InputObject $r } -Parameters @{ r = [ordered]@{ jsonrpc = '2.0'; id = $script:nextId; method = $Method; params = $all } }
            Invoke-McpInModule { param($t, $l) Send-McpTransportLine -Transport $t -Line $l } -Parameters @{ t = $script:pair.Client; l = $line }
            while ($true) {
                $received = Invoke-McpInModule { param($t) Receive-McpTransportLine -Transport $t -TimeoutMs 10000 } -Parameters @{ t = $script:pair.Client }
                if ($received.Status -ne 'Line') { throw "No response: $($received.Status)" }
                $message = Invoke-McpInModule { param($l) ConvertFrom-McpJson $l } -Parameters @{ l = $received.Line }
                if ($message['id'] -eq $script:nextId) { return $message }
            }
        }
    }

    AfterAll {
        Stop-McpServer -Server $script:rawServer
        Invoke-McpInModule { param($t) Close-McpTransport -Transport $t } -Parameters @{ t = $script:pair.Client }
        Invoke-McpInModule { param($b) Stop-McpBackgroundServer -Background $b } -Parameters @{ b = $script:background }
    }

    It 'answers with an InputRequiredResult and accumulates the answers in the requestState' {
        $round1 = Invoke-Raw -Params @{ name = 'two-rounds'; arguments = @{ Topic = 't' } }
        $result = $round1['result']
        (Test-McpSpecShape -Definition 'InputRequiredResult' -Instance $result).IsValid | Should -BeTrue
        $result['resultType'] | Should -Be 'input_required'
        @($result['inputRequests'].Keys) | Should -Be @('step1')
        $result['_meta']['io.modelcontextprotocol/serverInfo']['name'] | Should -Be 'raw'

        $round2 = Invoke-Raw -Params @{ name = 'two-rounds'; arguments = @{ Topic = 't' }; requestState = $result['requestState']; inputResponses = @{ step1 = @{ action = 'accept'; content = @{ name = 'Ada' } } } }
        @($round2['result']['inputRequests'].Keys) | Should -Be @('step2')

        # Round 3 carries only the new answer; the first one comes back from the state.
        $round3 = Invoke-Raw -Params @{ name = 'two-rounds'; arguments = @{ Topic = 't' }; requestState = $round2['result']['requestState']; inputResponses = @{ step2 = @{ action = 'accept'; content = @{ color = 'green' } } } }
        $round3['result']['resultType'] | Should -Be 'complete'
        $round3['result']['content'][0]['text'] | Should -Be 'Ada/green/rounds=3'
    }

    It 'works without requestState when the client sends every answer' {
        $response = Invoke-Raw -Params @{ name = 'two-rounds'; arguments = @{}; inputResponses = @{ step1 = @{ action = 'accept'; content = @{ name = 'Bo' } }; step2 = @{ action = 'accept'; content = @{ color = 'red' } }; unrelated = @{ x = 1 } } }
        $response['result']['content'][0]['text'] | Should -Be 'Bo/red/rounds=1'
    }

    It 'asks for all deferred inputs in one round' {
        $response = Invoke-Raw -Params @{ name = 'all-at-once'; arguments = @{} }
        @($response['result']['inputRequests'].Keys) | Should -Be @('user_name', 'greeting', 'client_roots')
    }

    It 'rejects <Case> with -32602' -TestCases @(
        @{ Case = 'a tampered requestState'; Mutate = { param($p) $p['requestState'] = $p['requestState'] + 'x'; $p } }
        @{ Case = 'a requestState of other arguments'; Mutate = { param($p) $p['arguments'] = @{ Topic = 'other' }; $p } }
        @{ Case = 'inputResponses that are not an object'; Mutate = { param($p) $p['inputResponses'] = 5; $p } }
        @{ Case = 'null inputResponses'; Mutate = { param($p) $p['inputResponses'] = $null; $p } }
        @{ Case = 'an input response that is not an object'; Mutate = { param($p) $p['inputResponses'] = @{ step1 = 12345 }; $p } }
        @{ Case = 'an answer that does not match the schema'; Mutate = { param($p) $p['inputResponses'] = @{ step1 = @{ action = 'accept'; content = @{ name = 12345 } } }; $p } }
    ) {
        param($Case, $Mutate)
        $null = $Case
        $round1 = Invoke-Raw -Params @{ name = 'two-rounds'; arguments = @{ Topic = 't' } }
        $params = & $Mutate @{ name = 'two-rounds'; arguments = @{ Topic = 't' }; requestState = $round1['result']['requestState']; inputResponses = @{ step1 = @{ action = 'accept'; content = @{ name = 'Ada' } } } }
        $response = Invoke-Raw -Params $params
        $response.Contains('result') | Should -BeFalse
        $response['error']['code'] | Should -Be -32602
    }

    It 'fails with -32021 when the client did not declare the capability' {
        $response = Invoke-Raw -Params @{ name = 'two-rounds'; arguments = @{} } -Capabilities @{ sampling = @{} }
        $response['error']['code'] | Should -Be -32021
        $response['error']['data']['requiredCapabilities']['elicitation'].Contains('form') | Should -BeTrue
    }

    It 'asks for input in prompts/get and resources/read' {
        (Invoke-Raw -Method 'prompts/get' -Params @{ name = 'ask-prompt' })['result']['inputRequests'].Contains('user_context') | Should -BeTrue
        $read = Invoke-Raw -Method 'resources/read' -Params @{ uri = 'ask://one' }
        $read['result']['resultType'] | Should -Be 'input_required'
        $done = Invoke-Raw -Method 'resources/read' -Params @{ uri = 'ask://one'; requestState = $read['result']['requestState']; inputResponses = @{ confirm = @{ action = 'accept'; content = @{ ok = $true } } } }
        $done['result']['contents'][0]['text'] | Should -Be 'read one ok=True'
    }
}

Describe 'Input callbacks of Connect-McpServer' -Tag 'Integration' {
    BeforeAll {
        $script:memoryServer = New-InputServer -Name 'memory-input'
        $script:requests = [System.Collections.Generic.List[object]]::new()
        $script:session = Connect-McpServer -Server $script:memoryServer -OnElicitation {
            param($Request)
            $script:requests.Add($Request)
            & $script:elicitation $Request
        } -OnSampling { param($Request) "hello ($($Request.MaxTokens))" } -OnRoots { param($Request) $null = $Request; '/work', @{ uri = 'file:///data'; name = 'data' } }
    }

    AfterAll {
        if ($script:session) { Disconnect-McpServer -Session $script:session }
    }

    It 'declares the capabilities of the callbacks' {
        $capabilities = $script:session.ClientCapabilities
        $capabilities['elicitation'].Contains('form') | Should -BeTrue
        $capabilities['elicitation'].Contains('url') | Should -BeTrue
        $capabilities.Contains('sampling') | Should -BeTrue
        $capabilities.Contains('roots') | Should -BeTrue
    }

    It 'answers input requests over several rounds' {
        $script:requests.Clear()
        (Invoke-McpTool -Name 'two-rounds' -Arguments @{ Topic = 'z' } -Session $script:session).Text | Should -Be 'Ada/green/rounds=3'
        @($script:requests | ForEach-Object Key) | Should -Be @('step1', 'step2')
        $script:requests[0].PSObject.TypeNames | Should -Contain 'Mcp.InputRequest'
        $script:requests[0].Mode | Should -Be 'form'
        $script:requests[0].Message | Should -Be 'Name (z)?'
        $script:requests[0].RequestMethod | Should -Be 'tools/call'
    }

    It 'answers elicitation, sampling and roots in one round' {
        $expectedRoot = [System.Uri]::new((Join-Path ([System.IO.Path]::GetPathRoot((Get-Location).Path)) 'work'), [System.UriKind]::Absolute).AbsoluteUri
        (Invoke-McpTool -Name 'all-at-once' -Session $script:session).Text | Should -Be "Ada|hello (20)|$expectedRoot,file:///data"
    }

    It 'renders prompts and reads resources that ask for input' {
        (Invoke-McpPrompt -Name 'ask-prompt' -Session $script:session).Messages[0].Content.Text | Should -Be 'Context: tests'
        (Read-McpResource -Uri 'ask://two' -Session $script:session).Text | Should -Be 'read two ok=True'
        # A result that needed input rounds is not cached.
        $script:session.Cache.ContainsKey('resources/read ask://two') | Should -BeFalse
    }

    It 'passes on a declined elicitation' {
        $session = Connect-McpServer -Server (New-InputServer) -OnElicitation { param($Request) $null = $Request; 'decline' }
        try {
            (Invoke-McpTool -Name 'decline' -Session $session).Text | Should -Be 'decline'
        } finally {
            Disconnect-McpServer -Session $session
        }
    }

    It 'fails with -32021 without the callback and capability' {
        $session = Connect-McpServer -Server (New-InputServer)
        try {
            $exception = $null
            try { Invoke-McpTool -Name 'two-rounds' -Session $session } catch { $exception = $_.Exception }
            $exception | Should -BeOfType [McpProtocolException]
            $exception.Code | Should -Be -32021
        } finally {
            Disconnect-McpServer -Session $session
        }
    }

    It 'fails when the server keeps asking beyond -MaxInputRounds' {
        $session = Connect-McpServer -Server (New-InputServer) -OnElicitation $script:elicitation -MaxInputRounds 1
        try {
            { Invoke-McpTool -Name 'two-rounds' -Session $session } | Should -Throw -ExpectedMessage '*-MaxInputRounds*'
        } finally {
            Disconnect-McpServer -Session $session
        }
    }

    It 'fails when a declared capability has no callback' {
        $session = Connect-McpServer -Server (New-InputServer) -Capabilities @{ elicitation = @{} }
        try {
            { Invoke-McpTool -Name 'two-rounds' -Session $session } | Should -Throw -ExpectedMessage '*-OnElicitation*'
        } finally {
            Disconnect-McpServer -Session $session
        }
    }
}

Describe 'Multi-round-trip requests over Streamable HTTP' -Tag 'Integration' {
    BeforeAll {
        $script:httpServer = New-InputServer -Name 'http-input'
        $script:handle = Start-McpTestHttpServer -Server $script:httpServer
        $script:httpSession = Connect-McpServer -Url $script:handle.Url -OnElicitation $script:elicitation -OnSampling { param($Request) $null = $Request; 'hi' } -OnRoots { param($Request) $null = $Request; @{ uri = 'file:///r' } }
    }

    AfterAll {
        if ($script:httpSession) { Disconnect-McpServer -Session $script:httpSession }
        if ($script:handle) { Stop-McpTestHttpServer -Handle $script:handle }
    }

    It 'runs the rounds as separate POSTs' {
        (Invoke-McpTool -Name 'two-rounds' -Arguments @{ Topic = 'h' } -Session $script:httpSession).Text | Should -Be 'Ada/green/rounds=3'
        (Invoke-McpTool -Name 'all-at-once' -Session $script:httpSession).Text | Should -Be 'Ada|hi|file:///r'
        (Read-McpResource -Uri 'ask://three' -Session $script:httpSession).Text | Should -Be 'read three ok=True'
    }
}
