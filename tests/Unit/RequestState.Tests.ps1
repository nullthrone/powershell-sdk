[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force

    $script:key = [byte[]] (1..32)
    function Get-TestState {
        param([hashtable] $Overrides = @{})
        $parameters = @{
            Key          = $script:key
            Method       = 'tools/call'
            Name         = 'confirm'
            Digest       = 'digest-1'
            Answers      = [ordered]@{ step1 = [ordered]@{ action = 'accept'; content = [ordered]@{ name = 'Ada' } } }
            Requested    = [ordered]@{ step2 = 'elicitation/create' }
            HandlerState = @{ phase = 2 }
        }
        foreach ($name in $Overrides.Keys) { $parameters[$name] = $Overrides[$name] }
        Invoke-McpInModule { param($p) New-McpRequestState @p } -Parameters @{ p = $parameters }
    }
    function Read-TestState {
        param([object] $Token, [hashtable] $Overrides = @{})
        $parameters = @{ Key = $script:key; Token = $Token; Method = 'tools/call'; Name = 'confirm'; Digest = 'digest-1' }
        foreach ($name in $Overrides.Keys) { $parameters[$name] = $Overrides[$name] }
        Invoke-McpInModule { param($p) Read-McpRequestState @p } -Parameters @{ p = $parameters }
    }
    function ConvertTo-TestSecureString {
        param([string] $Text)
        $secure = [System.Security.SecureString]::new()
        foreach ($character in $Text.ToCharArray()) { $secure.AppendChar($character) }
        $secure
    }
    function Get-StateError {
        param([scriptblock] $Action)
        try { & $Action; $null } catch { $_.Exception }
    }
}

Describe 'requestState' {
    It 'round-trips the accumulated answers, the requested keys and the handler state' {
        $token = Get-TestState
        $token | Should -Match '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'
        $payload = Read-TestState -Token $token
        $payload['v'] | Should -Be 1
        $payload['a']['step1']['content']['name'] | Should -Be 'Ada'
        $payload['r']['step2'] | Should -Be 'elicitation/create'
        $payload['s']['phase'] | Should -Be 2
    }

    It 'differs on every call (nonce) and leaves out an empty handler state' {
        $first = Get-TestState -Overrides @{ HandlerState = @{} }
        $second = Get-TestState -Overrides @{ HandlerState = @{} }
        $first | Should -Not -Be $second
        (Read-TestState -Token $first).Contains('s') | Should -BeFalse
    }

    It 'rejects <Case> with -32602' -TestCases @(
        @{ Case = 'a modified payload'; Mutate = { param($t) $parts = $t.Split('.'); $body = $parts[0].ToCharArray(); $body[5] = if ($body[5] -eq 'A') { 'B' } else { 'A' }; (-join $body) + '.' + $parts[1] }; Reason = 'signature' }
        @{ Case = 'a modified signature'; Mutate = { param($t) $t.Substring(0, $t.Length - 2) + $(if ($t.EndsWith('AA')) { 'BB' } else { 'AA' }) }; Reason = 'signature' }
        @{ Case = 'a token without signature'; Mutate = { param($t) $t.Split('.')[0] }; Reason = 'malformed' }
        @{ Case = 'garbage'; Mutate = { param($t) $null = $t; 'not-a-token' }; Reason = 'malformed' }
        @{ Case = 'a non-string token'; Mutate = { param($t) $null = $t; 42 }; Reason = 'not a string' }
    ) {
        param($Case, $Mutate, $Reason)
        $null = $Case
        $token = & $Mutate (Get-TestState)
        $exception = Get-StateError { Read-TestState -Token $token }
        $exception | Should -BeOfType [McpProtocolException]
        $exception.Code | Should -Be -32602
        $exception.Message | Should -BeLike "*$Reason*"
    }

    It 'rejects a state signed with another key' {
        $token = Get-TestState -Overrides @{ Key = [byte[]] (101..132) }
        (Get-StateError { Read-TestState -Token $token }).Message | Should -BeLike '*signature*'
    }

    It 'rejects an expired state' {
        $token = Get-TestState -Overrides @{ TtlSeconds = -1 }
        (Get-StateError { Read-TestState -Token $token }).Message | Should -BeLike '*expired*'
    }

    It 'rejects a state of another <Case>' -TestCases @(
        @{ Case = 'method'; Overrides = @{ Method = 'prompts/get' }; Reason = 'another request' }
        @{ Case = 'target'; Overrides = @{ Name = 'other' }; Reason = 'another request' }
        @{ Case = 'argument digest'; Overrides = @{ Digest = 'digest-2' }; Reason = 'arguments differ' }
    ) {
        param($Case, $Overrides, $Reason)
        $null = $Case
        $stateOverrides = $Overrides
        (Get-StateError { Read-TestState -Token (Get-TestState) -Overrides $stateOverrides }).Message | Should -BeLike "*$Reason*"
    }
}

Describe 'Request digests and signing keys' {
    It 'digests the salient params independently of member order' {
        $a = Invoke-McpInModule { Get-McpRequestDigest -Method 'tools/call' -Params ([ordered]@{ name = 't'; arguments = [ordered]@{ x = 1; y = [ordered]@{ b = 2; a = 1 } } }) }
        $b = Invoke-McpInModule { Get-McpRequestDigest -Method 'tools/call' -Params ([ordered]@{ arguments = [ordered]@{ y = [ordered]@{ a = 1; b = 2 }; x = 1 }; name = 't'; inputResponses = @{}; requestState = 'x' }) }
        $c = Invoke-McpInModule { Get-McpRequestDigest -Method 'tools/call' -Params ([ordered]@{ name = 't'; arguments = [ordered]@{ x = 2 } }) }
        $a | Should -Be $b
        $a | Should -Not -Be $c
    }

    It 'derives a 32-byte key from <Case>' -TestCases @(
        @{ Case = 'nothing (random)'; Key = $null }
        @{ Case = 'a string'; Key = 'a sufficiently long secret' }
        @{ Case = 'a byte array'; Key = [byte[]] (1..40) }
    ) {
        param($Case, $Key)
        $null = $Case
        $bytes = Invoke-McpInModule { param($k) ConvertTo-McpRequestStateKey -Key $k } -Parameters @{ k = $Key }
        $bytes.Length | Should -BeGreaterOrEqual 32
    }

    It 'derives the same key from a string and the equal SecureString' {
        $fromString = Invoke-McpInModule { ConvertTo-McpRequestStateKey -Key 'a sufficiently long secret' }
        $fromSecure = Invoke-McpInModule { param($k) ConvertTo-McpRequestStateKey -Key $k } -Parameters @{ k = (ConvertTo-TestSecureString -Text 'a sufficiently long secret') }
        [System.Convert]::ToBase64String($fromString) | Should -Be ([System.Convert]::ToBase64String($fromSecure))
    }

    It 'rejects weak keys' {
        { Invoke-McpInModule { ConvertTo-McpRequestStateKey -Key 'short' } } | Should -Throw -ExpectedMessage '*16 characters*'
        { Invoke-McpInModule { ConvertTo-McpRequestStateKey -Key ([byte[]] (1..16)) } } | Should -Throw -ExpectedMessage '*32 bytes*'
        { New-McpServer -Name 'weak' -Version '1.0.0' -RequestStateKey 'short' } | Should -Throw -ExpectedMessage '*16 characters*'
    }
}
