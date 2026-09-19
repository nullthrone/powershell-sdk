BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    $script:manifest = Get-McpBuiltModuleManifest
    Import-Module $script:manifest -Force
    $script:pwsh = Get-McpPowerShellPath
    $script:serverScript = Join-Path (Get-McpRepositoryRoot) 'examples' 'echo-server.ps1'
    $script:serverArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:serverScript)
    $env:MCP_MODULE_MANIFEST = $script:manifest
    $env:POWERSHELL_TELEMETRY_OPTOUT = '1'
}

Describe 'The example server over stdio' -Tag 'Integration' {
    BeforeAll {
        $script:stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $script:session = Connect-McpServer -Command $script:pwsh -Arguments $script:serverArguments -ConnectTimeoutSeconds 60
        $script:connectMs = $script:stopwatch.ElapsedMilliseconds
    }

    AfterAll {
        if ($script:session) { Disconnect-McpServer -Session $script:session }
    }

    It 'connects, discovers and lists the tools' {
        $script:session.Kind | Should -Be 'Process'
        $script:session.Name | Should -Be 'echo'
        (Get-McpServerInfo -Session $script:session).Title | Should -Be 'Echo server'
        @(Get-McpTool -Session $script:session | ForEach-Object Name) | Should -Be @('echo', 'add', 'count', 'fail', 'shout')
        Write-Verbose "Connected in $($script:connectMs) ms" -Verbose:$false
    }

    It 'round-trips non-ASCII text and a 1 MB payload' {
        (Invoke-McpTool -Name 'echo' -Arguments @{ Text = 'héllo 😀 日本'; Repeat = 2 } -Session $script:session).Text | Should -Be 'héllo 😀 日本héllo 😀 日本'
        $big = 'x' * 1MB
        (Invoke-McpTool -Name 'echo' -Arguments @{ Text = $big } -Session $script:session).Text.Length | Should -Be 1MB
    }

    It 'returns structured content, error results and progress' {
        (Invoke-McpTool -Name 'add' -Arguments @{ A = 1.5; B = 2 } -Session $script:session).StructuredContent['sum'] | Should -Be 3.5
        (Invoke-McpTool -Name 'fail' -Session $script:session).IsError | Should -BeTrue
        $progress = [System.Collections.Generic.List[object]]::new()
        (Invoke-McpTool -Name 'count' -Arguments @{ To = 2; DelayMs = 10 } -OnProgress { param($p) $progress.Add($p.Progress) } -Session $script:session).Text | Should -Be 'counted to 2'
        @($progress) | Should -Be @(1, 2)
    }

    It 'keeps Write-Host and streams of handlers off stdout and logs warnings to stderr' {
        $result = Invoke-McpTool -Name 'shout' -Arguments @{ Text = 'quiet' } -Session $script:session
        $result.Text | Should -Be 'QUIET'
        $result.Content.Count | Should -Be 1
        (Invoke-McpTool -Name 'echo' -Arguments @{ Text = 'still fine' } -Session $script:session).Text | Should -Be 'still fine'
        Get-Content -Path $script:session.StandardErrorPath -Raw | Should -Match 'a warning for the server log'
    }

    It 'recovers from a client-side timeout' {
        { Invoke-McpTool -Name 'count' -Arguments @{ To = 100; DelayMs = 100 } -TimeoutSeconds 1 -Session $script:session } | Should -Throw -ExceptionType ([System.TimeoutException])
        (Invoke-McpTool -Name 'echo' -Arguments @{ Text = 'alive' } -Session $script:session).Text | Should -Be 'alive'
    }

    It 'answers 20 calls in well under a second each' {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        1..20 | ForEach-Object { $null = Invoke-McpTool -Name 'echo' -Arguments @{ Text = "x$_" } -Session $script:session }
        ($stopwatch.ElapsedMilliseconds / 20) | Should -BeLessThan 1000
    }
}

Describe 'Raw stdio behaviour of the example server' -Tag 'Integration' {
    BeforeAll {
        function script:Invoke-RawServer {
            param([string[]] $Lines, [int] $TimeoutSeconds = 60)
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:pwsh
            foreach ($argument in $script:serverArguments) { $startInfo.ArgumentList.Add($argument) }
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
            $process = [System.Diagnostics.Process]::Start($startInfo)
            try {
                $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync(($stdout = [System.IO.MemoryStream]::new()))
                $stderrTask = $process.StandardError.ReadToEndAsync()
                $process.StandardInput.NewLine = "`n"
                foreach ($line in $Lines) { $process.StandardInput.WriteLine($line) }
                $process.StandardInput.Flush()
                Start-Sleep -Milliseconds 1500
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $process.StandardInput.Close()
                $exited = $process.WaitForExit($TimeoutSeconds * 1000)
                if (-not $exited) { $process.Kill($true) }
                $null = $stdoutTask.Wait(5000)
                @{
                    Exited      = $exited
                    ExitMs      = $stopwatch.ElapsedMilliseconds
                    ExitCode    = if ($exited) { $process.ExitCode } else { $null }
                    StdOutBytes = $stdout.ToArray()
                    StdOut      = [System.Text.Encoding]::UTF8.GetString($stdout.ToArray())
                    StdErr      = $stderrTask.GetAwaiter().GetResult()
                }
            } finally {
                $process.Dispose()
            }
        }
    }

    It 'writes nothing but JSON lines to stdout, without a BOM, and exits promptly when stdin closes' {
        $meta = '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'
        $result = Invoke-RawServer -Lines @(
            "{`"jsonrpc`":`"2.0`",`"id`":1,`"method`":`"server/discover`",`"params`":{$meta}}"
            'garbage'
            "{`"jsonrpc`":`"2.0`",`"id`":2,`"method`":`"tools/call`",`"params`":{$meta,`"name`":`"shout`",`"arguments`":{`"Text`":`"x`"}}}"
        )
        $result.Exited | Should -BeTrue
        $result.ExitMs | Should -BeLessThan 15000
        $result.ExitCode | Should -Be 0
        $result.StdOutBytes.Count | Should -BeGreaterThan 3
        ($result.StdOutBytes[0] -eq 0xEF -and $result.StdOutBytes[1] -eq 0xBB) | Should -BeFalse
        $result.StdOut | Should -Not -Match "`r"
        $lines = @($result.StdOut -split "`n" | Where-Object { $_ -ne '' })
        $lines.Count | Should -Be 3
        foreach ($line in $lines) { { Invoke-McpInModule { param($l) ConvertFrom-McpJson $l } $line } | Should -Not -Throw }
        $messages = $lines | ForEach-Object { Invoke-McpInModule { param($l) ConvertFrom-McpJson $l } $_ }
        $messages[0]['id'] | Should -Be 1
        $messages[0]['result']['supportedVersions'] | Should -Be @('2026-07-28')
        $messages[1]['error']['code'] | Should -Be -32700
        $messages[2]['result']['content'][0]['text'] | Should -Be 'X'
        $result.StdOut | Should -Not -Match 'host output must not reach stdout'
        $result.StdErr | Should -Match 'a warning for the server log'
    }
}
