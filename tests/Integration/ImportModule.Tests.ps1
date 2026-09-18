BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    $script:manifestPath = Get-McpBuiltModuleManifest
    $script:pwsh = Get-McpPowerShellPath
}

Describe 'Importing the module in a fresh pwsh process' -Tag 'Integration' {
    It 'writes nothing to stdout or stderr and exits with 0' {
        $result = Invoke-McpChildProcess -FilePath $script:pwsh -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive',
            '-Command', "Import-Module '$script:manifestPath' -ErrorAction Stop; exit 0"
        )
        $result.StdErr | Should -BeNullOrEmpty
        $result.StdOut | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
    }

    It 'stays silent when imported from a launcher-style script under -File' {
        $launcher = Join-Path $TestDrive 'launcher.ps1'
        @(
            '#Requires -Version 7.4'
            '[CmdletBinding()]'
            'param()'
            "Import-Module '$script:manifestPath' -ErrorAction Stop"
            'exit 0'
        ) | Set-Content -Path $launcher -Encoding utf8NoBOM
        $result = Invoke-McpChildProcess -FilePath $script:pwsh -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $launcher
        )
        $result.StdErr | Should -BeNullOrEmpty
        $result.StdOut | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
    }

    It 'exposes the engine types by name in the importing process' {
        $result = Invoke-McpChildProcess -FilePath $script:pwsh -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive',
            '-Command', "Import-Module '$script:manifestPath' -ErrorAction Stop; [Console]::Error.WriteLine([McpEra]::Modern); exit 0"
        )
        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -BeNullOrEmpty
        $result.StdErr.Trim() | Should -Be 'Modern'
    }
}
