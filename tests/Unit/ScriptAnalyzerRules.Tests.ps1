BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module -Name PSScriptAnalyzer -MinimumVersion 1.25.0 -ErrorAction Stop
    $script:rulePath = Join-Path (Get-McpRepositoryRoot) 'tools' 'ScriptAnalyzerRules' 'McpAnalyzerRules.psm1'

    function Invoke-McpCustomRule {
        param(
            [Parameter(Mandatory)] [string] $RelativePath,
            [Parameter(Mandatory)] [string] $Content
        )
        $file = Join-Path $TestDrive $RelativePath
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $file) -Force
        Set-Content -Path $file -Value $Content -NoNewline -Encoding utf8NoBOM
        @(Invoke-ScriptAnalyzer -Path $file -CustomRulePath $script:rulePath -ErrorAction Stop)
    }
}

Describe 'Measure-McpStdoutPurity' {
    It 'flags <_> in a module source file' -ForEach @(
        "Write-Host 'x'"
        "'x' | Out-Host"
        "'x' | Out-Default"
        "Read-Host 'name'"
        "[Console]::WriteLine('x')"
        "[Console]::Write('x')"
        "[System.Console]::Out.Flush()"
        "`$stream = [Console]::OpenStandardOutput()"
        "[Console]::SetOut([Console]::Error)"
        "`$Host.UI.WriteLine('x')"
    ) {
        $findings = @(Invoke-McpCustomRule -RelativePath 'src/Private/Sample.ps1' -Content "function Sample { $_ }")
        $findings.Count | Should -Be 1
        $findings[0].RuleName | Should -Be 'Measure-McpStdoutPurity'
        $findings[0].Severity | Should -Be 'Error'
    }

    It 'allows <_> in a module source file' -ForEach @(
        "Write-Verbose 'x'"
        "Write-Warning 'x'"
        "Write-Output 'x'"
        "[Console]::Error.WriteLine('x')"
        "`$stream = [Console]::OpenStandardError()"
        "`$stream = [Console]::OpenStandardInput()"
        "'x' | Out-String"
        "`$Host.Version"
    ) {
        $findings = @(Invoke-McpCustomRule -RelativePath 'src/Private/Sample.ps1' -Content "function Sample { $_ }")
        @($findings | Where-Object RuleName -Like '*Measure-McpStdoutPurity') | Should -BeNullOrEmpty
    }

    It 'exempts the transport writer files (<_>)' -ForEach @('src/Classes/100-Stdio.ps1', 'src/Private/StdioTransport.ps1', 'src/Private/ConsoleWriter.ps1') {
        $findings = @(Invoke-McpCustomRule -RelativePath $_ -Content "`$stream = [Console]::OpenStandardOutput(); [Console]::Out.Flush()")
        @($findings | Where-Object RuleName -Like '*Measure-McpStdoutPurity') | Should -BeNullOrEmpty
    }

    It 'does not apply outside src/' {
        $findings = @(Invoke-McpCustomRule -RelativePath 'tests/Unit/Sample.Tests.ps1' -Content "Write-Host 'x'")
        @($findings | Where-Object RuleName -Like '*Measure-McpStdoutPurity') | Should -BeNullOrEmpty
    }

    It 'honours SuppressMessageAttribute' {
        $content = @'
function Sample {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('Measure-McpStdoutPurity', '', Justification = 'test')]
    param()
    Write-Host 'x'
}
'@
        $findings = @(Invoke-McpCustomRule -RelativePath 'src/Private/Sample.ps1' -Content $content)
        @($findings | Where-Object RuleName -Like '*Measure-McpStdoutPurity') | Should -BeNullOrEmpty
    }
}

Describe 'Measure-McpNoInvokeExpression' {
    It 'flags <_> as an error in <RelativePath>' -ForEach @(
        @{ Code = "Invoke-Expression 'Get-Date'"; RelativePath = 'src/Private/Sample.ps1' }
        @{ Code = "iex 'Get-Date'"; RelativePath = 'src/Private/Sample.ps1' }
        @{ Code = "`$ExecutionContext.InvokeCommand.InvokeScript('Get-Date')"; RelativePath = 'tests/Unit/Sample.Tests.ps1' }
        @{ Code = "`$ExecutionContext.InvokeCommand.ExpandString('`$x')"; RelativePath = 'build.ps1' }
    ) {
        $findings = @((Invoke-McpCustomRule -RelativePath $RelativePath -Content $Code) | Where-Object RuleName -Like '*Measure-McpNoInvokeExpression')
        $findings.Count | Should -Be 1
        $findings[0].Severity | Should -Be 'Error'
        $findings[0].Extent.Text | Should -Be $Code
    }

    It 'flags [scriptblock]::Create as a warning' {
        $findings = @((Invoke-McpCustomRule -RelativePath 'src/Private/Sample.ps1' -Content "`$sb = [scriptblock]::Create('1')") | Where-Object RuleName -Like '*Measure-McpNoInvokeExpression')
        $findings.Count | Should -Be 1
        $findings[0].Severity | Should -Be 'Warning'
    }

    It 'does not flag ordinary invocation' {
        $findings = @((Invoke-McpCustomRule -RelativePath 'src/Private/Sample.ps1' -Content "& `$command; `$sb.Invoke(); `$sb.Ast.GetScriptBlock()") | Where-Object RuleName -Like '*Measure-McpNoInvokeExpression')
        $findings | Should -BeNullOrEmpty
    }
}
