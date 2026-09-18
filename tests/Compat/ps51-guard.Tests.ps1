BeforeDiscovery {
    # Discovery-time value: only used for -Skip. Variables set during discovery are not visible in the run phase,
    # so the run phase looks the command up again in BeforeAll.
    $script:hasWindowsPowerShell = [bool] ($IsWindows -and (Get-Command -Name powershell.exe -ErrorAction SilentlyContinue))
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    $script:manifestPath = Get-McpBuiltModuleManifest
    $script:windowsPowerShell = if ($IsWindows) { Get-Command -Name powershell.exe -ErrorAction SilentlyContinue } else { $null }
}

Describe 'Windows PowerShell 5.1 guard' -Tag 'Compat', 'PS51Guard' {
    It 'refuses to import the module and names the required PowerShell version' -Skip:(-not $script:hasWindowsPowerShell) {
        $script:windowsPowerShell | Should -Not -BeNullOrEmpty
        $command = "try { Import-Module '$script:manifestPath' -ErrorAction Stop; exit 0 } catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 3 }"
        $result = Invoke-McpChildProcess -FilePath $script:windowsPowerShell.Source -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $command)
        $result.ExitCode | Should -Be 3
        $result.StdErr | Should -Match '7\.4'
    }
}
