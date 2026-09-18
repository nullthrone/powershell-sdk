BeforeDiscovery {
    $script:windowsPowerShell = if ($IsWindows) { Get-Command -Name powershell.exe -ErrorAction SilentlyContinue } else { $null }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    $script:manifestPath = Get-McpBuiltModuleManifest
}

Describe 'Windows PowerShell 5.1 guard' -Tag 'Compat', 'PS51Guard' {
    It 'refuses to import the module and names the required PowerShell version' -Skip:(-not $script:windowsPowerShell) {
        $command = "try { Import-Module '$script:manifestPath' -ErrorAction Stop; exit 0 } catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 3 }"
        $result = Invoke-McpChildProcess -FilePath $script:windowsPowerShell.Source -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $command)
        $result.ExitCode | Should -Be 3
        $result.StdErr | Should -Match '7\.4'
    }
}
