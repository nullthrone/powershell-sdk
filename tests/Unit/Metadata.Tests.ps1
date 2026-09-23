[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force

    function ConvertTo-Wire {
        param($InputObject)
        Invoke-McpInModule { param($o) ConvertFrom-McpJson (ConvertTo-McpJson -InputObject $o) } -Parameters @{ o = $InputObject }
    }
}

Describe 'Icons' {
    It 'normalises icons given as hashtables, objects and strings' {
        $icons = Invoke-McpInModule {
            ConvertTo-McpIconList -Icons @(
                @{ Src = 'https://example.com/a.png'; MimeType = 'image/png'; Sizes = '48x48'; Theme = 'Dark' }
                [pscustomobject]@{ src = 'data:image/svg+xml;base64,PHN2Zy8+'; sizes = @('any') }
                'http://example.com/b.jpg'
            )
        }
        $icons.Count | Should -Be 3
        $icons[0]['src'] | Should -Be 'https://example.com/a.png'
        $icons[0]['sizes'] | Should -Be @('48x48')
        $icons[0]['theme'] | Should -Be 'dark'
        foreach ($icon in $icons) { (Test-McpSpecShape -Definition 'Icon' -Instance $icon).IsValid | Should -BeTrue }
    }

    It 'rejects <Case>' -TestCases @(
        @{ Case = 'a relative src'; Icon = @{ src = 'icon.png' }; Message = '*absolute http, https or data URI*' }
        @{ Case = 'an invalid size'; Icon = @{ src = 'https://x/i.png'; sizes = '48' }; Message = '*WIDTHxHEIGHT*' }
        @{ Case = 'an unknown theme'; Icon = @{ src = 'https://x/i.png'; theme = 'blue' }; Message = '*light or dark*' }
        @{ Case = 'an unknown member'; Icon = @{ src = 'https://x/i.png'; color = 'red' }; Message = "*Unknown icon member 'color'*" }
    ) {
        { Invoke-McpInModule { param($i) ConvertTo-McpIconList -Icons @($i) } -Parameters @{ i = $Icon } } | Should -Throw -ExpectedMessage $Message
    }

    It 'validates the icons of servers, tools and prompts' {
        { New-McpServer -Name 's' -Version '1' -Icons @(@{ src = 'nope' }) } | Should -Throw -ExpectedMessage '*absolute*'
        $server = New-McpServer -Name 's' -Version '1' -Icons @('https://example.com/s.png')
        $server.Icons[0]['src'] | Should -Be 'https://example.com/s.png'
        { Register-McpTool -Server $server -Name 't' -ScriptBlock { 'x' } -Icons @(@{ src = 'nope' }) } | Should -Throw -ExpectedMessage '*absolute*'
        { Register-McpPrompt -Server $server -Name 'p' -Description 'P.' -ScriptBlock { 'x' } -Icons @(@{ src = 'nope' }) } | Should -Throw -ExpectedMessage '*absolute*'
    }
}

Describe 'New-McpContent' {
    It 'builds spec-valid blocks of every type' {
        $blocks = @(
            New-McpContent -Text 'hi' -Annotations @{ audience = @('user', 'assistant'); priority = 1 }
            New-McpContent -Image ([byte[]] (1, 2)) -MimeType 'image/png'
            New-McpContent -Audio 'UklGRg==' -MimeType 'audio/wav'
            New-McpContent -ResourceLink 'test://doc' -Name 'doc' -Title 'Doc' -Description 'A doc.' -MimeType 'text/plain' -Size 10 -Icons @('https://example.com/d.png')
            New-McpContent -EmbeddedResource 'test://doc' -MimeType 'text/plain' -ResourceText 'body' -ResourceMeta @{ source = 'test' } -Annotations @{ lastModified = '2026-07-28T00:00:00Z' }
            New-McpContent -EmbeddedResource 'test://bin' -ResourceBlob ([byte[]] (3)) -Meta @{ note = 'x' }
        )
        foreach ($block in $blocks) {
            $block.PSObject.TypeNames | Should -Contain 'Mcp.Content'
            (Test-McpSpecShape -Definition 'ContentBlock' -Instance (ConvertTo-Wire $block)).IsValid | Should -BeTrue
        }
        $blocks[0].annotations['priority'] | Should -Be 1.0
        $blocks[3].icons[0]['src'] | Should -Be 'https://example.com/d.png'
        $blocks[4].resource['_meta']['source'] | Should -Be 'test'
    }

    It 'decodes binary data with GetBytes()' {
        (New-McpContent -Image ([byte[]] (1, 2)) -MimeType 'image/png').GetBytes() | Should -Be @(1, 2)
        (New-McpContent -EmbeddedResource 'test://bin' -ResourceBlob ([byte[]] (3, 4))).GetBytes() | Should -Be @(3, 4)
        [System.Text.Encoding]::UTF8.GetString((New-McpContent -Text 'ä').GetBytes()) | Should -Be 'ä'
    }

    It 'rejects invalid annotations' {
        { New-McpContent -Text 'x' -Annotations @{ priority = -0.1 } } | Should -Throw -ExpectedMessage '*from 0 to 1*'
        { New-McpContent -Text 'x' -Annotations @{ lastModified = 'yesterday' } } | Should -Throw -ExpectedMessage '*ISO 8601*'
        { New-McpContent -Text 'x' -Annotations @{ importance = 1 } } | Should -Throw -ExpectedMessage "*Unknown annotation 'importance'*"
    }
}

Describe 'New-McpPromptMessage and New-McpResourceContent' {
    It 'builds prompt messages' {
        $message = New-McpPromptMessage -Role assistant -Text 'ok'
        $message.PSObject.TypeNames | Should -Contain 'Mcp.PromptMessage'
        (Test-McpSpecShape -Definition 'PromptMessage' -Instance (ConvertTo-Wire $message)).IsValid | Should -BeTrue
        (New-McpPromptMessage -Content (New-McpContent -Image 'AQI=' -MimeType 'image/png')).content.type | Should -Be 'image'
        { New-McpPromptMessage -Content 'plain' } | Should -Throw -ExpectedMessage '*content block*'
    }

    It 'builds resource contents' {
        $text = New-McpResourceContent -Text 'x' -Uri 'test://a' -MimeType 'text/plain'
        (Test-McpSpecShape -Definition 'TextResourceContents' -Instance (ConvertTo-Wire $text)).IsValid | Should -BeTrue
        $blob = New-McpResourceContent -Blob ([byte[]] (1)) -Uri 'test://b'
        (Test-McpSpecShape -Definition 'BlobResourceContents' -Instance (ConvertTo-Wire $blob)).IsValid | Should -BeTrue
        $blob.PSObject.TypeNames | Should -Contain 'Mcp.ResourceContents'
        { New-McpResourceContent -Text 'x' -Uri 'relative' } | Should -Throw -ExpectedMessage '*absolute URI*'
    }
}

Describe 'Cursor pagination' {
    It 'binds cursors to their list' {
        $server = New-McpServer -Name 's' -Version '1' -PageSize 1
        Register-McpTool -Server $server -Name 'a' -ScriptBlock { 'a' }
        Register-McpTool -Server $server -Name 'b' -ScriptBlock { 'b' }
        Register-McpPrompt -Server $server -Name 'p' -Description 'P.' -ScriptBlock { 'p' }
        Register-McpPrompt -Server $server -Name 'q' -Description 'Q.' -ScriptBlock { 'q' }
        $first = Invoke-McpInModule { param($s) Get-McpToolListResult -Server $s -Cursor $null } $server
        $first['nextCursor'] | Should -Not -BeNullOrEmpty
        $second = Invoke-McpInModule { param($s, $c) Get-McpToolListResult -Server $s -Cursor $c } $server $first['nextCursor']
        $second['tools'][0]['name'] | Should -Be 'b'
        $second.Contains('nextCursor') | Should -BeFalse
        { Invoke-McpInModule { param($s, $c) Get-McpPromptListResult -Server $s -Cursor $c } $server $first['nextCursor'] } | Should -Throw -ExpectedMessage 'Invalid cursor.'
        $prompts = Invoke-McpInModule { param($s) Get-McpPromptListResult -Server $s -Cursor $null } $server
        (Invoke-McpInModule { param($s, $c) Get-McpPromptListResult -Server $s -Cursor $c } $server $prompts['nextCursor'])['prompts'][0]['name'] | Should -Be 'q'
    }
}
