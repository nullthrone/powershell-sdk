BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force
}

Describe 'JSON-RPC message model' {
    It 'builds requests, notifications and responses with the fixed member order' {
        Invoke-McpInModule { ConvertTo-McpJson (New-McpRequest -Id 1 -Method 'tools/list' -Params ([ordered]@{ cursor = 'c' })) } |
            Should -Be '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":"c"}}'
        Invoke-McpInModule { ConvertTo-McpJson (New-McpNotification -Method 'notifications/cancelled' -Params ([ordered]@{ requestId = 'r' })) } |
            Should -Be '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"r"}}'
        Invoke-McpInModule { ConvertTo-McpJson (New-McpResultResponse -Id 'x' -Result ([ordered]@{ resultType = 'complete' })) } |
            Should -Be '{"jsonrpc":"2.0","id":"x","result":{"resultType":"complete"}}'
        Invoke-McpInModule { ConvertTo-McpJson (New-McpErrorResponse -Id $null -ErrorObject (New-McpError -Code -32700 -Message 'Parse error')) } |
            Should -Be '{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"}}'
    }

    It 'omits params and data when they are not given' {
        Invoke-McpInModule { ConvertTo-McpJson (New-McpNotification -Method 'notifications/initialized') } | Should -Be '{"jsonrpc":"2.0","method":"notifications/initialized"}'
        Invoke-McpInModule { ConvertTo-McpJson (New-McpError -Code -32603 -Message 'm') } | Should -Be '{"code":-32603,"message":"m"}'
        Invoke-McpInModule { ConvertTo-McpJson (New-McpError -Code -32022 -Message 'm' -Data ([ordered]@{ supported = @('2026-07-28'); requested = 'x' })) } |
            Should -Be '{"code":-32022,"message":"m","data":{"supported":["2026-07-28"],"requested":"x"}}'
    }

    It 'knows the error codes of the specification' {
        $codes = Invoke-McpInModule { $script:McpErrorCode }
        $codes.ParseError | Should -Be -32700
        $codes.InvalidRequest | Should -Be -32600
        $codes.MethodNotFound | Should -Be -32601
        $codes.InvalidParams | Should -Be -32602
        $codes.InternalError | Should -Be -32603
        $codes.HeaderMismatch | Should -Be -32020
        $codes.MissingRequiredClientCapability | Should -Be -32021
        $codes.UnsupportedProtocolVersion | Should -Be -32022
        Invoke-McpInModule { Get-McpErrorCode -Name InvalidParams } | Should -Be -32602
    }

    It 'classifies <Json> as <Kind>' -ForEach @(
        @{ Json = '{"jsonrpc":"2.0","id":1,"method":"m"}'; Kind = 'Request' }
        @{ Json = '{"jsonrpc":"2.0","id":"s","method":"m","params":{}}'; Kind = 'Request' }
        @{ Json = '{"jsonrpc":"2.0","method":"m"}'; Kind = 'Notification' }
        @{ Json = '{"jsonrpc":"2.0","id":1,"result":{}}'; Kind = 'Response' }
        @{ Json = '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"x"}}'; Kind = 'ErrorResponse' }
        @{ Json = '{"jsonrpc":"2.0","id":null,"method":"m"}'; Kind = 'Invalid' }
        @{ Json = '{"jsonrpc":"2.0","id":1.5,"method":"m"}'; Kind = 'Invalid' }
        @{ Json = '{"jsonrpc":"2.0","id":{"a":1},"method":"m"}'; Kind = 'Invalid' }
        @{ Json = '{"jsonrpc":"1.0","id":1,"method":"m"}'; Kind = 'Invalid' }
        @{ Json = '{"id":1,"method":"m"}'; Kind = 'Invalid' }
        @{ Json = '{"jsonrpc":"2.0","id":1,"method":"m","params":[1]}'; Kind = 'Invalid' }
        @{ Json = '{"jsonrpc":"2.0","id":1}'; Kind = 'Invalid' }
        @{ Json = '[]'; Kind = 'Invalid' }
        @{ Json = '"text"'; Kind = 'Invalid' }
    ) {
        Invoke-McpInModule { param($j) Get-McpMessageKind -Message (ConvertFrom-McpJson $j) } $Json | Should -Be $Kind
    }

    It 'turns exceptions into error objects' {
        $protocol = Invoke-McpInModule { ConvertTo-McpErrorObject -Exception ([McpProtocolException]::new(-32602, 'bad', ([ordered]@{ detail = 1 }))) }
        $protocol['code'] | Should -Be -32602
        $protocol['message'] | Should -Be 'bad'
        $protocol['data']['detail'] | Should -Be 1
        $internal = Invoke-McpInModule { ConvertTo-McpErrorObject -Exception ([System.InvalidOperationException]::new('boom')) }
        $internal['code'] | Should -Be -32603
        $internal['message'] | Should -Be 'boom'
        $internal.Contains('data') | Should -BeFalse
    }
}
