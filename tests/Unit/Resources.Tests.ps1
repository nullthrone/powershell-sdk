[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force

    # Reads a resource in the current runspace, as the worker would, and returns the wire result after a JSON round trip.
    function Read-TestResource {
        param([pscustomobject] $Server, [string] $Uri)
        Invoke-McpInModule {
            param($s, $u)
            $resolved = Resolve-McpResourceRequest -Server $s -Uri $u
            $hint = Get-McpResourceCacheHint -Server $s -Registration $resolved.Registration
            $result = Invoke-McpResourceHandler -Registration $resolved.Registration -Uri $u -Variables $resolved.Variables -CacheHint $hint
            ConvertFrom-McpJson (ConvertTo-McpJson -InputObject $result)
        } $Server $Uri
    }

    $script:root = Join-Path $TestDrive 'root'
    $null = New-Item -ItemType Directory -Path (Join-Path $script:root 'sub') -Force
    Set-Content -Path (Join-Path $script:root 'readme.md') -Value '# Readme' -NoNewline
    Set-Content -Path (Join-Path $script:root 'sub' 'data.json') -Value '{"a":1}' -NoNewline
    [System.IO.File]::WriteAllBytes((Join-Path $script:root 'image.png'), [byte[]] (137, 80, 78, 71))
    Set-Content -Path (Join-Path $TestDrive 'secret.txt') -Value 'secret' -NoNewline
}

Describe 'Register-McpResource' {
    It 'registers fixed text and binary content with MIME types and sizes' {
        $server = New-McpServer -Name 'r' -Version '1'
        Register-McpResource -Server $server -Uri 'test://text' -Content 'héllo'
        Register-McpResource -Server $server -Uri 'test://bin' -Content ([byte[]] (1, 2, 3)) -Name 'bin' -Title 'Binary' -Description 'Three bytes.'
        $list = Invoke-McpInModule { param($s) Get-McpResourceListResult -Server $s -Cursor $null } $server
        (Test-McpSpecShape -Definition 'ListResourcesResult' -Instance $list).IsValid | Should -BeTrue
        $list['resources'][0]['mimeType'] | Should -Be 'text/plain'
        $list['resources'][0]['size'] | Should -Be 6
        $list['resources'][0]['name'] | Should -Be 'test://text'
        $list['resources'][1]['mimeType'] | Should -Be 'application/octet-stream'
        $list['resources'][1]['size'] | Should -Be 3
        $list['resources'][1]['title'] | Should -Be 'Binary'
        $binary = Read-TestResource -Server $server -Uri 'test://bin'
        (Test-McpSpecShape -Definition 'ReadResourceResult' -Instance $binary).IsValid | Should -BeTrue
        $binary['contents'][0]['blob'] | Should -Be 'AQID'
        (Read-TestResource -Server $server -Uri 'test://text')['contents'][0]['text'] | Should -Be 'héllo'
    }

    It 'validates URIs, sources and duplicates' {
        $server = New-McpServer -Name 'r' -Version '1'
        { Register-McpResource -Server $server -Uri 'not a uri' -Content 'x' } | Should -Throw -ExpectedMessage '*absolute URI*'
        { Register-McpResource -Server $server -Uri 'test://x' } | Should -Throw -ExpectedMessage '*exactly one*'
        { Register-McpResource -Server $server -Uri 'test://x' -Content 'a' -ScriptBlock { 'b' } } | Should -Throw -ExpectedMessage '*exactly one*'
        { Register-McpResource -Server $server -Uri 'test://x' -Content 42 } | Should -Throw -ExpectedMessage '*string or a byte*'
        Register-McpResource -Server $server -Uri 'test://x' -Content 'a'
        { Register-McpResource -Server $server -Uri 'test://x' -Content 'b' } | Should -Throw -ExpectedMessage '*already registered*'
        Register-McpResource -Server $server -Uri 'test://x' -Content 'b' -Force
        (Read-TestResource -Server $server -Uri 'test://x')['contents'][0]['text'] | Should -Be 'b'
        { Register-McpResource -Server $server -UriTemplate 'test://{a*}' -ScriptBlock { 'x' } } | Should -Throw -ExpectedMessage '*level 4*'
        { Register-McpResource -Server $server -UriTemplate 'test://{a}' -ScriptBlock { 'x' } -Completion @{ b = @('1') } } | Should -Throw -ExpectedMessage '*not one of the arguments*'
    }

    It 'validates annotations and icons' {
        $server = New-McpServer -Name 'r' -Version '1'
        $registration = Register-McpResource -Server $server -Uri 'test://a' -Content 'x' -PassThru -Annotations @{ Audience = 'user'; Priority = 0.5; LastModified = [datetime]::new(2026, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc) } -Icons @('https://example.com/i.png')
        $registration.Annotations['audience'] | Should -Be @('user')
        $registration.Annotations['priority'] | Should -Be 0.5
        $registration.Annotations['lastModified'] | Should -Be '2026-01-02T03:04:05Z'
        $registration.Icons[0]['src'] | Should -Be 'https://example.com/i.png'
        $definition = Invoke-McpInModule { param($r) ConvertTo-McpResourceDefinition -Registration $r } $registration
        (Test-McpSpecShape -Definition 'Resource' -Instance $definition).IsValid | Should -BeTrue
        { Register-McpResource -Server $server -Uri 'test://b' -Content 'x' -Annotations @{ Priority = 2 } } | Should -Throw -ExpectedMessage '*from 0 to 1*'
        { Register-McpResource -Server $server -Uri 'test://b' -Content 'x' -Annotations @{ Audience = 'robot' } } | Should -Throw -ExpectedMessage '*user or assistant*'
        { Register-McpResource -Server $server -Uri 'test://b' -Content 'x' -Icons @(@{ src = 'ftp://x/i.png' }) } | Should -Throw -ExpectedMessage '*http, https or data*'
    }
}

Describe 'Resource handlers and templates' {
    It 'binds template variables by name and shapes objects as JSON' {
        $server = New-McpServer -Name 'r' -Version '1'
        Register-McpResource -Server $server -UriTemplate 'items://{kind}/{id}' -MimeType 'application/json' -ScriptBlock {
            param([string] $kind, [int] $id, $Uri, $Variables)
            [ordered]@{ kind = $kind; id = $id; uri = $Uri; count = $Variables.Count }
        }
        $result = Read-TestResource -Server $server -Uri 'items://book/7'
        (Test-McpSpecShape -Definition 'ReadResourceResult' -Instance $result).IsValid | Should -BeTrue
        $result['contents'][0]['mimeType'] | Should -Be 'application/json'
        $payload = ConvertFrom-Json $result['contents'][0]['text']
        $payload.kind | Should -Be 'book'
        $payload.id | Should -Be 7
        $payload.uri | Should -Be 'items://book/7'
        $payload.count | Should -Be 2
        $templates = Invoke-McpInModule { param($s) Get-McpResourceTemplateListResult -Server $s -Cursor $null } $server
        (Test-McpSpecShape -Definition 'ListResourceTemplatesResult' -Instance $templates).IsValid | Should -BeTrue
        $templates['resourceTemplates'][0]['uriTemplate'] | Should -Be 'items://{kind}/{id}'
    }

    It 'joins strings, keeps byte arrays whole and passes New-McpResourceContent through' {
        $server = New-McpServer -Name 'r' -Version '1'
        Register-McpResource -Server $server -Uri 'test://lines' -ScriptBlock { 'one'; 'two' }
        Register-McpResource -Server $server -Uri 'test://bytes' -MimeType 'image/png' -ScriptBlock { [byte[]] (1, 2, 3) }
        Register-McpResource -Server $server -Uri 'test://many' -ScriptBlock {
            New-McpResourceContent -Text 'a' -MimeType 'text/markdown'
            New-McpResourceContent -Blob ([byte[]] (255)) -Uri 'test://many/blob' -Meta @{ note = 'x' }
        }
        (Read-TestResource -Server $server -Uri 'test://lines')['contents'][0]['text'] | Should -Be "one`ntwo"
        $bytes = (Read-TestResource -Server $server -Uri 'test://bytes')['contents']
        $bytes.Count | Should -Be 1
        $bytes[0]['blob'] | Should -Be 'AQID'
        $bytes[0]['mimeType'] | Should -Be 'image/png'
        $many = Read-TestResource -Server $server -Uri 'test://many'
        (Test-McpSpecShape -Definition 'ReadResourceResult' -Instance $many).IsValid | Should -BeTrue
        $many['contents'][0]['uri'] | Should -Be 'test://many'
        $many['contents'][0]['mimeType'] | Should -Be 'text/markdown'
        $many['contents'][1]['uri'] | Should -Be 'test://many/blob'
        $many['contents'][1]['blob'] | Should -Be '/w=='
        $many['contents'][1]['_meta']['note'] | Should -Be 'x'
    }

    It 'reports unknown URIs, empty output and ItemNotFoundException as not found (-32602 with the URI)' {
        $server = New-McpServer -Name 'r' -Version '1'
        Register-McpResource -Server $server -Uri 'test://empty' -ScriptBlock { }
        Register-McpResource -Server $server -Uri 'test://missing' -ScriptBlock { throw [System.Management.Automation.ItemNotFoundException]::new('gone') }
        Register-McpResource -Server $server -Uri 'test://broken' -ScriptBlock { throw 'boom' }
        foreach ($uri in 'test://unknown', 'test://empty', 'test://missing') {
            $caught = $null
            try { Read-TestResource -Server $server -Uri $uri } catch { $caught = $_.Exception }
            while ($caught -and $caught -isnot [McpProtocolException] -and $caught.InnerException) { $caught = $caught.InnerException }
            $caught | Should -BeOfType [McpProtocolException]
            $caught.Code | Should -Be -32602
            $caught.Message | Should -Be 'Resource not found'
            $caught.Data['uri'] | Should -Be $uri
        }
        $caught = $null
        try { Read-TestResource -Server $server -Uri 'test://broken' } catch { $caught = $_.Exception }
        while ($caught -and $caught -isnot [McpProtocolException] -and $caught.InnerException) { $caught = $caught.InnerException }
        $caught.Code | Should -Be -32603
        $caught.Message | Should -Match 'boom'
    }

    It 'uses the resource caching hints and falls back to the server defaults' {
        $server = New-McpServer -Name 'r' -Version '1' -DefaultTtlMs 1000 -DefaultCacheScope private
        Register-McpResource -Server $server -Uri 'test://own' -Content 'x' -TtlMs 60000 -CacheScope public
        Register-McpResource -Server $server -Uri 'test://default' -Content 'x'
        $own = Read-TestResource -Server $server -Uri 'test://own'
        $own['ttlMs'] | Should -Be 60000
        $own['cacheScope'] | Should -Be 'public'
        $default = Read-TestResource -Server $server -Uri 'test://default'
        $default['ttlMs'] | Should -Be 1000
        $default['cacheScope'] | Should -Be 'private'
    }
}

Describe 'File and directory resources' {
    It 'serves a file with the MIME type of its extension' {
        $server = New-McpServer -Name 'r' -Version '1'
        $registration = Register-McpResource -Server $server -Path (Join-Path $script:root 'readme.md') -PassThru
        $registration.Uri | Should -BeLike 'file:///*readme.md'
        $registration.Name | Should -Be 'readme.md'
        $registration.MimeType | Should -Be 'text/markdown'
        $definition = Invoke-McpInModule { param($r) ConvertTo-McpResourceDefinition -Registration $r } $registration
        $definition['size'] | Should -Be 8
        (Read-TestResource -Server $server -Uri $registration.Uri)['contents'][0]['text'] | Should -Be '# Readme'
    }

    It 'serves the files below a directory as a template' {
        $server = New-McpServer -Name 'r' -Version '1'
        $registration = Register-McpResource -Server $server -Path $script:root -Uri 'docs://' -PassThru
        $registration.UriTemplate | Should -Be 'docs://{+path}'
        (Read-TestResource -Server $server -Uri 'docs://sub/data.json')['contents'][0]['mimeType'] | Should -Be 'application/json'
        $image = (Read-TestResource -Server $server -Uri 'docs://image.png')['contents'][0]
        $image['mimeType'] | Should -Be 'image/png'
        $image['blob'] | Should -Be ([System.Convert]::ToBase64String([byte[]] (137, 80, 78, 71)))
        $fileTemplate = Register-McpResource -Server $server -Path (Join-Path $script:root 'sub') -PassThru
        $fileTemplate.UriTemplate | Should -BeLike 'file:///*/sub/{+path}'
    }

    It 'rejects paths that leave the directory: <Path>' -TestCases @(
        @{ Path = '../secret.txt' }
        @{ Path = '%2e%2e/secret.txt' }
        @{ Path = 'sub/../../secret.txt' }
        @{ Path = 'sub' }
        @{ Path = 'missing.txt' }
    ) {
        $server = New-McpServer -Name 'r' -Version '1'
        Register-McpResource -Server $server -Path $script:root -Uri 'docs://'
        { Read-TestResource -Server $server -Uri "docs://$Path" } | Should -Throw -ExpectedMessage '*Resource not found*'
    }

    It 'rejects absolute paths' {
        $absolute = Invoke-McpInModule { param($r, $p) Resolve-McpDirectoryResourcePath -Root $r -RelativePath $p } $script:root (Join-Path $TestDrive 'secret.txt')
        $absolute | Should -BeNullOrEmpty
    }

    It 'rejects symbolic links that lead outside the directory' -Skip:$IsWindows {
        $linkRoot = Join-Path $TestDrive 'linked'
        $null = New-Item -ItemType Directory -Path $linkRoot -Force
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $linkRoot 'escape.txt') -Target (Join-Path $TestDrive 'secret.txt')
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $linkRoot 'outside') -Target $TestDrive
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $linkRoot 'sibling.md') -Target (Join-Path $linkRoot '..' 'root' 'readme.md')
        Set-Content -Path (Join-Path $linkRoot 'plain.txt') -Value 'plain' -NoNewline
        $resolve = { param($p) Invoke-McpInModule { param($r, $p) Resolve-McpDirectoryResourcePath -Root $r -RelativePath $p } $linkRoot $p }
        & $resolve 'escape.txt' | Should -BeNullOrEmpty
        & $resolve 'outside/secret.txt' | Should -BeNullOrEmpty
        & $resolve 'sibling.md' | Should -BeNullOrEmpty
        & $resolve 'plain.txt' | Should -Not -BeNullOrEmpty
    }
}
