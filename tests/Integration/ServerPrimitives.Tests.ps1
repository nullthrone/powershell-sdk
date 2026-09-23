[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force

    $script:root = Join-Path $TestDrive 'files'
    $null = New-Item -ItemType Directory -Path $script:root -Force
    Set-Content -Path (Join-Path $script:root 'notes.txt') -Value 'file notes' -NoNewline

    $script:server = New-McpServer -Name 'primitives' -Version '1.0.0' -PageSize 2 -RequestTimeoutSeconds 10 -DefaultTtlMs 0
    Register-McpResource -Server $script:server -Uri 'test://text' -Name 'text' -Description 'Text.' -Content 'static text'
    Register-McpResource -Server $script:server -Uri 'test://binary' -Name 'binary' -MimeType 'image/png' -Content ([byte[]] (1, 2, 3))
    Register-McpResource -Server $script:server -Uri 'test://cached' -Name 'cached' -TtlMs 60000 -CacheScope private -ScriptBlock { [guid]::NewGuid().ToString() }
    Register-McpResource -Server $script:server -Uri 'test://logging' -Name 'logging' -ScriptBlock {
        Write-Warning 'resource warning'
        Write-Information 'resource info'
        'logged'
    }
    Register-McpResource -Server $script:server -UriTemplate 'items://{id}' -Name 'item' -MimeType 'application/json' -ScriptBlock {
        param([int] $id)
        if ($id -gt 100) { return }
        [ordered]@{ id = $id; square = $id * $id }
    } -Completion @{ id = @('1', '2', '10', '20') }
    Register-McpResource -Server $script:server -Path $script:root -Uri 'files://'
    Register-McpPrompt -Server $script:server -Name 'greet' -Description 'Greets someone.' -ScriptBlock {
        param(
            [Parameter(Mandatory)][string] $Name,
            [ValidateSet('formal', 'casual')][string] $Style = 'casual'
        )
        if ($Style -eq 'formal') { "Good day, $Name." } else { "Hi $Name!" }
        New-McpPromptMessage -Role assistant -Text 'How can I help?'
    }
    Register-McpPrompt -Server $script:server -Name 'picture' -Description 'Shows a picture.' -ScriptBlock {
        New-McpContent -Image ([byte[]] (9, 8, 7)) -MimeType 'image/png'
    }
    Register-McpPrompt -Server $script:server -Name 'third' -Description 'Third page.' -ScriptBlock { 'third' }
    $script:session = Connect-McpServer -Server $script:server
}

AfterAll {
    if ($script:session) { Disconnect-McpServer -Session $script:session }
}

Describe 'Resources through the client' -Tag 'Integration' {
    It 'declares the capabilities of what is registered' {
        $capabilities = (Get-McpServerInfo -Session $script:session).Capabilities
        @($capabilities.Keys) | Should -Be @('completions', 'prompts', 'resources', 'tools')
        $capabilities['resources']['subscribe'] | Should -BeTrue
        $capabilities['resources']['listChanged'] | Should -BeTrue
    }

    It 'lists resources and templates across pages' {
        $resources = @(Get-McpResource -Session $script:session)
        @($resources | ForEach-Object Name) | Should -Be @('text', 'binary', 'cached', 'logging')
        $resources[0].PSObject.TypeNames | Should -Contain 'Mcp.Resource'
        $resources[1].Size | Should -Be 3
        @(Get-McpResource -Name 'b*' -Session $script:session).Count | Should -Be 1
        $templates = @(Get-McpResource -Template -Session $script:session)
        @($templates | ForEach-Object UriTemplate) | Should -Be @('items://{id}', 'files://{+path}')
        $templates[0].PSObject.TypeNames | Should -Contain 'Mcp.ResourceTemplate'
    }

    It 'reads text, binary, template and file resources' {
        $text = Read-McpResource -Uri 'test://text' -Session $script:session
        $text.PSObject.TypeNames | Should -Contain 'Mcp.ResourceContent'
        $text.Text | Should -Be 'static text'
        $text.MimeType | Should -Be 'text/plain'
        $binary = Read-McpResource -Uri 'test://binary' -Session $script:session
        $binary.Blob | Should -Be 'AQID'
        $binary.GetBytes() | Should -Be @(1, 2, 3)
        (ConvertFrom-Json (Read-McpResource -Uri 'items://7' -Session $script:session).Text).square | Should -Be 49
        (Read-McpResource -Uri 'files://notes.txt' -Session $script:session).Text | Should -Be 'file notes'
    }

    It 'reads the resources piped from Get-McpResource' {
        $contents = @(Get-McpResource -Session $script:session | Where-Object Name -In 'text', 'binary' | Read-McpResource -Session $script:session)
        @($contents | ForEach-Object Uri) | Should -Be @('test://text', 'test://binary')
    }

    It 'reports unknown resources as non-terminating ObjectNotFound errors' {
        $contents = @(Read-McpResource -Uri 'test://nope', 'items://500', 'test://text' -Session $script:session -ErrorVariable errors -ErrorAction SilentlyContinue)
        $contents.Count | Should -Be 1
        # -ErrorVariable also collects the protocol exceptions caught inside the command (not all as ErrorRecords).
        $failures = @($errors | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -and $_.FullyQualifiedErrorId -like 'McpResourceNotFound,*' })
        $failures.Count | Should -Be 2
        $failures[0].CategoryInfo.Category | Should -Be 'ObjectNotFound'
        $failures[0].TargetObject | Should -Be 'test://nope'
        $failures[0].Exception.InnerException.Code | Should -Be -32602
        $failures[1].TargetObject | Should -Be 'items://500'
    }

    It 'rejects reads that escape a directory resource' {
        { Read-McpResource -Uri 'files://../secret' -Session $script:session -ErrorAction Stop } | Should -Throw -ExpectedMessage '*no resource*'
    }

    It 'caches reads for the ttlMs of the result and not for ttlMs 0' {
        $first = (Read-McpResource -Uri 'test://cached' -Session $script:session).Text
        (Read-McpResource -Uri 'test://cached' -Session $script:session).Text | Should -Be $first
        $script:session.Cache['resources/read test://cached'].CacheScope | Should -Be 'private'
        (Read-McpResource -Uri 'test://cached' -Session $script:session -Refresh).Text | Should -Not -Be $first
        $null = Read-McpResource -Uri 'test://text' -Session $script:session
        $script:session.Cache.ContainsKey('resources/read test://text') | Should -BeFalse
        $script:session.Cache.ContainsKey('resources/list') | Should -BeFalse
    }

    It 'sends handler warnings and information as log notifications when asked' {
        $script:session.Log.Clear()
        $content = Read-McpResource -Uri 'test://logging' -Session $script:session -LogLevel info
        $content.Text | Should -Be 'logged'
        @($script:session.Log | ForEach-Object Level) | Should -Be @('warning', 'info')
        $script:session.Log[0].Data | Should -Be 'resource warning'
        $script:session.Log[0].Logger | Should -Be 'test://logging'
        $script:session.Log.Clear()
        $null = Read-McpResource -Uri 'test://logging' -Session $script:session
        $script:session.Log.Count | Should -Be 0
    }
}

Describe 'Prompts and completion through the client' -Tag 'Integration' {
    It 'lists prompts across pages with their arguments' {
        $prompts = @(Get-McpPrompt -Session $script:session)
        @($prompts | ForEach-Object Name) | Should -Be @('greet', 'picture', 'third')
        $prompts[0].PSObject.TypeNames | Should -Contain 'Mcp.Prompt'
        $prompts[0].Arguments[0].Name | Should -Be 'Name'
        $prompts[0].Arguments[0].Required | Should -BeTrue
        $prompts[0].Arguments[1].Required | Should -BeFalse
        @(Get-McpPrompt -Name 'pic*' -Session $script:session).Name | Should -Be 'picture'
    }

    It 'renders prompts with arguments' {
        $result = Invoke-McpPrompt -Name 'greet' -Arguments @{ Name = 'Ada'; Style = 'formal' } -Session $script:session
        $result.PSObject.TypeNames | Should -Contain 'Mcp.PromptResult'
        $result.Description | Should -Be 'Greets someone.'
        $result.Messages.Count | Should -Be 2
        $result.Messages[0].Role | Should -Be 'user'
        $result.Messages[0].Content.text | Should -Be 'Good day, Ada.'
        $result.Messages[1].Role | Should -Be 'assistant'
        $result.Text | Should -Be "Good day, Ada.`nHow can I help?"
        $image = Invoke-McpPrompt -Name 'picture' -Session $script:session
        $image.Messages[0].Content.PSObject.TypeNames | Should -Contain 'Mcp.Content'
        $image.Messages[0].Content.GetBytes() | Should -Be @(9, 8, 7)
    }

    It 'throws protocol errors for unknown prompts and missing arguments' {
        { Invoke-McpPrompt -Name 'nope' -Session $script:session } | Should -Throw -ExpectedMessage "*Unknown prompt 'nope'*"
        { Invoke-McpPrompt -Name 'greet' -Session $script:session } | Should -Throw -ExpectedMessage '*Missing required argument*Name*'
    }

    It 'completes prompt arguments and template variables' {
        $style = Get-McpCompletion -PromptName 'greet' -Argument 'Style' -Value 'f' -Session $script:session
        $style.PSObject.TypeNames | Should -Contain 'Mcp.Completion'
        $style.Values | Should -Be @('formal')
        $style.Total | Should -Be 1
        $style.HasMore | Should -BeFalse
        (Get-McpCompletion -ResourceTemplate 'items://{id}' -Argument 'id' -Value '1' -Session $script:session).Values | Should -Be @('1', '10')
        { Get-McpCompletion -PromptName 'greet' -Argument 'Missing' -Value '' -Session $script:session } | Should -Throw -ExpectedMessage '*no argument*'
    }
}

Describe 'Capability gating and the client cache' -Tag 'Integration' {
    It 'answers the methods of undeclared capabilities with -32601' {
        $bare = New-McpServer -Name 'bare' -Version '1'
        $session = Connect-McpServer -Server $bare
        try {
            @((Get-McpServerInfo -Session $session).Capabilities.Keys) | Should -Be @('tools')
            foreach ($call in @(
                    { Get-McpResource -Session $session }
                    { Get-McpResource -Template -Session $session }
                    { Read-McpResource -Uri 'test://x' -Session $session }
                    { Get-McpPrompt -Session $session }
                    { Invoke-McpPrompt -Name 'x' -Session $session }
                    { Get-McpCompletion -PromptName 'x' -Argument 'y' -Session $session }
                )) {
                $caught = $null
                try { & $call } catch { $caught = $_.Exception }
                $caught | Should -BeOfType [McpProtocolException]
                $caught.Code | Should -Be -32601
            }
        } finally {
            Disconnect-McpServer -Session $session
        }
    }

    It 'caches lists and the server info for their ttlMs' {
        $server = New-McpServer -Name 'cached' -Version '1' -DefaultTtlMs 60000
        Register-McpTool -Server $server -Name 'one' -ScriptBlock { 1 }
        Register-McpPrompt -Server $server -Name 'p' -Description 'P.' -ScriptBlock { 'p' }
        $session = Connect-McpServer -Server $server
        try {
            @(Get-McpTool -Session $session).Count | Should -Be 1
            @(Get-McpPrompt -Session $session).Count | Should -Be 1
            $session.Cache.ContainsKey('server/discover') | Should -BeTrue
            $session.Cache['tools/list'].CacheScope | Should -Be 'public'
            # The cached list hides a later registration until it expires or -Refresh asks again.
            Register-McpTool -Server $server -Name 'two' -ScriptBlock { 2 }
            @(Get-McpTool -Session $session).Count | Should -Be 1
            @(Get-McpTool -Session $session -Refresh).Count | Should -Be 2
            Register-McpTool -Server $server -Name 'three' -ScriptBlock { 3 }
            $session.Cache['tools/list'].ExpiresAt = [datetime]::UtcNow.AddSeconds(-1)
            @(Get-McpTool -Session $session).Count | Should -Be 3
            $session.Cache['tools/list'].ExpiresAt | Should -BeGreaterThan ([datetime]::UtcNow)
        } finally {
            Disconnect-McpServer -Session $session
        }
    }
}
