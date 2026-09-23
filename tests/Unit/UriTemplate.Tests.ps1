[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force

    function Test-TemplateMatch {
        param([string] $Template, [string] $Uri)
        Invoke-McpInModule {
            param($t, $u)
            $parsed = ConvertFrom-McpUriTemplate -Template $t
            Test-McpUriTemplateMatch -Template $parsed -Uri $u
        } $Template $Uri
    }
}

Describe 'RFC 6570 URI template matching' {
    It 'matches <Template> against <Uri>' -TestCases @(
        @{ Template = 'test://template/{id}/data'; Uri = 'test://template/123/data'; Expected = @{ id = '123' } }
        @{ Template = 'weather://{city}/current'; Uri = 'weather://Berlin%20Mitte/current'; Expected = @{ city = 'Berlin Mitte' } }
        @{ Template = 'docs://{+path}'; Uri = 'docs://guide/intro.md'; Expected = @{ path = 'guide/intro.md' } }
        @{ Template = 'file:///srv{/dir,name}'; Uri = 'file:///srv/a/b.txt'; Expected = @{ dir = 'a'; name = 'b.txt' } }
        @{ Template = 'app://x{.format}'; Uri = 'app://x.json'; Expected = @{ format = 'json' } }
        @{ Template = 'app://x{;version}'; Uri = 'app://x;version=2'; Expected = @{ version = '2' } }
        @{ Template = 'search://items{?q,limit}'; Uri = 'search://items?limit=5&q=a%26b'; Expected = @{ q = 'a&b'; limit = '5' } }
        @{ Template = 'search://items?fixed=1{&page}'; Uri = 'search://items?fixed=1&page=3'; Expected = @{ page = '3' } }
        @{ Template = 'page://doc{#section}'; Uri = 'page://doc#intro'; Expected = @{ section = 'intro' } }
        @{ Template = 'pair://{a,b}'; Uri = 'pair://x,y'; Expected = @{ a = 'x'; b = 'y' } }
    ) {
        $variables = Test-TemplateMatch -Template $Template -Uri $Uri
        $variables | Should -Not -BeNullOrEmpty
        foreach ($key in $Expected.Keys) {
            $variables[$key] | Should -BeExactly $Expected[$key]
        }
    }

    It 'does not match <Uri> against <Template>' -TestCases @(
        @{ Template = 'test://template/{id}/data'; Uri = 'test://template//data' }
        @{ Template = 'test://template/{id}/data'; Uri = 'test://template/1/2/data' }
        @{ Template = 'test://template/{id}/data'; Uri = 'test://template/1/data/more' }
        @{ Template = 'weather://{city}/current'; Uri = 'WEATHER://berlin/current' }
    ) {
        Test-TemplateMatch -Template $Template -Uri $Uri | Should -BeNullOrEmpty
    }

    It 'lists the variables of a template in order' {
        $parsed = Invoke-McpInModule { ConvertFrom-McpUriTemplate -Template 'a://{x}/{+y}{?z,w}' }
        $parsed.Variables | Should -Be @('x', 'y', 'z', 'w')
    }

    It 'rejects <Template>' -TestCases @(
        @{ Template = 'a://{path*}'; Message = '*level 4*' }
        @{ Template = 'a://{name:3}'; Message = '*level 4*' }
        @{ Template = 'a://{x'; Message = "*unmatched '{'*" }
        @{ Template = 'a://x}'; Message = "*unmatched '}'*" }
        @{ Template = 'a://{}'; Message = '*empty expression*' }
        @{ Template = 'a://{=x}'; Message = '*reserved operator*' }
        @{ Template = 'a://{x}/{x}'; Message = '*more than once*' }
        @{ Template = 'a://{bad-name}'; Message = '*invalid variable name*' }
    ) {
        { Invoke-McpInModule { param($t) ConvertFrom-McpUriTemplate -Template $t } $Template } | Should -Throw -ExpectedMessage $Message
    }
}
