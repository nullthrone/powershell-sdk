BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force
}

Describe 'ConvertFrom-McpJson' {
    It 'keeps object key order, is case-sensitive and preserves JSON types' {
        $value = Invoke-McpInModule { ConvertFrom-McpJson '{"b":1,"a":2.5,"A":"x","n":null,"t":true,"f":false,"o":{},"l":[]}' }
        $value | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
        @($value.Keys) | Should -Be @('b', 'a', 'A', 'n', 't', 'f', 'o', 'l')
        $value['b'] | Should -BeOfType [long]
        $value['a'] | Should -BeOfType [double]
        $value['A'] | Should -Be 'x'
        $value['n'] | Should -BeNull
        $value.Contains('n') | Should -BeTrue
        $value['t'] | Should -BeTrue
        $value['f'] | Should -BeFalse
        $value['o'] | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
        $value['o'].Count | Should -Be 0
        $value['l'].GetType().IsArray | Should -BeTrue
        $value['l'].Count | Should -Be 0
    }

    It 'does not unroll single-element arrays and keeps nested arrays' {
        $value = Invoke-McpInModule { ConvertFrom-McpJson '{"one":[1],"nested":[[1,2],[3]],"top":[{"a":1}]}' }
        $value['one'].GetType().IsArray | Should -BeTrue
        $value['one'].Count | Should -Be 1
        $value['nested'].Count | Should -Be 2
        $value['nested'][0].Count | Should -Be 2
        $value['nested'][1].Count | Should -Be 1
        $value['top'][0]['a'] | Should -Be 1
    }

    It 'preserves the JSON type of a request id (<Json>)' -ForEach @(
        @{ Json = '{"id":"1"}'; Type = [string] }
        @{ Json = '{"id":1}'; Type = [long] }
        @{ Json = '{"id":1.5}'; Type = [double] }
    ) {
        $value = Invoke-McpInModule { param($j) ConvertFrom-McpJson $j } $Json
        $value['id'] | Should -BeOfType $Type
    }

    It 'does not coerce date-like strings' {
        $value = Invoke-McpInModule { ConvertFrom-McpJson '{"when":"2026-07-28T00:00:00Z"}' }
        $value['when'] | Should -BeOfType [string]
        $value['when'] | Should -Be '2026-07-28T00:00:00Z'
    }

    It 'handles large integers, unicode and escapes' {
        $value = Invoke-McpInModule { ConvertFrom-McpJson '{"big":9007199254740993,"huge":1e300,"u":"héllo 😀","esc":"a\nb\"c"}' }
        $value['big'] | Should -Be 9007199254740993
        $value['huge'] | Should -BeOfType [double]
        $value['u'] | Should -Be "héllo 😀"
        $value['esc'] | Should -Be "a`nb`"c"
    }

    It 'returns scalars for scalar documents' {
        Invoke-McpInModule { ConvertFrom-McpJson '"text"' } | Should -Be 'text'
        Invoke-McpInModule { ConvertFrom-McpJson '42' } | Should -Be 42
        Invoke-McpInModule { ConvertFrom-McpJson 'null' } | Should -BeNull
    }

    It 'throws on invalid JSON and on comments' {
        { Invoke-McpInModule { ConvertFrom-McpJson '{"a":' } } | Should -Throw
        { Invoke-McpInModule { ConvertFrom-McpJson '{"a":1} // c' } } | Should -Throw
        { Invoke-McpInModule { ConvertFrom-McpJson '' } } | Should -Throw
    }

    It 'enforces the maximum depth' {
        $deep = ('[' * 100) + (']' * 100)
        { Invoke-McpInModule { param($d) ConvertFrom-McpJson $d -MaxDepth 32 } $deep } | Should -Throw
        { Invoke-McpInModule { param($d) ConvertFrom-McpJson $d -MaxDepth 128 } $deep } | Should -Not -Throw
    }
}

Describe 'ConvertTo-McpJson' {
    It 'writes compact single-line JSON with insertion order' {
        $json = Invoke-McpInModule { ConvertTo-McpJson ([ordered]@{ b = 1; a = @{ x = $null }; s = 'text'; l = @(1, 'two', $true) }) }
        $json | Should -Be '{"b":1,"a":{"x":null},"s":"text","l":[1,"two",true]}'
        $json | Should -Not -Match "`n"
    }

    It 'serialises PSCustomObject, switch, byte[], DateTime, enum, Guid, Uri and Version' {
        $guid = [guid] '12345678-1234-1234-1234-123456789abc'
        $object = [pscustomobject]@{
            flag    = [switch] $true
            bytes   = [byte[]] @(1, 2, 3)
            when    = [datetime]::new(2026, 7, 28, 12, 0, 0, [System.DateTimeKind]::Utc)
            level   = [McpLoggingLevel]::Warning
            id      = $guid
            uri     = [uri] 'https://example.com/a'
            version = [version] '1.2.3'
        }
        $json = Invoke-McpInModule { param($o) ConvertTo-McpJson $o } $object
        $json | Should -Be '{"flag":true,"bytes":"AQID","when":"2026-07-28T12:00:00.0000000Z","level":"Warning","id":"12345678-1234-1234-1234-123456789abc","uri":"https://example.com/a","version":"1.2.3"}'
    }

    It 'keeps non-ASCII text unescaped (astral characters as surrogate escapes) and escapes control characters' {
        $json = Invoke-McpInModule { ConvertTo-McpJson @{ t = "héllo 😀 a`nb`tc <>&'" } }
        $json | Should -Be '{"t":"héllo \uD83D\uDE00 a\nb\tc <>&''"}'
        Invoke-McpInModule { param($j) (ConvertFrom-McpJson $j)['t'] } $json | Should -Be "héllo 😀 a`nb`tc <>&'"
    }

    It 'writes numbers of every integer and floating type as JSON numbers' {
        $json = Invoke-McpInModule { ConvertTo-McpJson ([ordered]@{ i = [int] 1; l = [long] 2; d = [double] 2.5; f = [single] 0.5; m = [decimal] 1.25; u = [uint64] 3; big = [bigint]::Parse('123456789012345678901234567890') }) }
        $json | Should -Be '{"i":1,"l":2,"d":2.5,"f":0.5,"m":1.25,"u":3,"big":123456789012345678901234567890}'
    }

    It 'round-trips a decoded message byte for byte' {
        $text = '{"jsonrpc":"2.0","id":"a-1","method":"tools/call","params":{"_meta":{"progressToken":7},"name":"x","arguments":{"list":[1,[2,3],{"k":null}],"e":{}}}}'
        $roundTrip = Invoke-McpInModule { param($t) ConvertTo-McpJson (ConvertFrom-McpJson $t) } $text
        $roundTrip | Should -Be $text
    }

    It 'rejects NaN, infinity and excessive depth' {
        { Invoke-McpInModule { ConvertTo-McpJson @{ x = [double]::NaN } } } | Should -Throw
        { Invoke-McpInModule { ConvertTo-McpJson @{ x = [double]::PositiveInfinity } } } | Should -Throw
        $nested = @{ a = 1 }
        1..40 | ForEach-Object { $nested = @{ a = $nested } }
        { Invoke-McpInModule { param($n) ConvertTo-McpJson $n -MaxDepth 32 } $nested } | Should -Throw
        { Invoke-McpInModule { param($n) ConvertTo-McpJson $n -MaxDepth 64 } $nested } | Should -Not -Throw
    }

    It 'writes null, empty containers and generic lists' {
        Invoke-McpInModule { ConvertTo-McpJson $null } | Should -Be 'null'
        Invoke-McpInModule { ConvertTo-McpJson @{} } | Should -Be '{}'
        Invoke-McpInModule { ConvertTo-McpJson @() } | Should -Be '[]'
        $list = [System.Collections.Generic.List[object]]::new(); $list.Add(1); $list.Add('a')
        Invoke-McpInModule { param($l) ConvertTo-McpJson $l } -Parameters @{ l = $list } | Should -Be '[1,"a"]'
    }
}
