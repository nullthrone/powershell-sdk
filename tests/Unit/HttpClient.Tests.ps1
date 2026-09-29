[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCorrectCasing', '', Justification = 'PSScriptAnalyzer attributes -ScriptBlock of commands nested in BeforeAll to BeforeAll itself.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    Import-Module (Get-McpBuiltModuleManifest) -Force
}

Describe 'Stop-McpHttpSendTask' {
    It 'disposes the response of a send that completed although it was cancelled' {
        # The response headers arrived between the deadline and the cancellation: the task completed anyway.
        $body = [System.IO.MemoryStream]::new([byte[]] @(1, 2, 3))
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::OK)
        $response.Content = [System.Net.Http.StreamContent]::new($body)
        $task = [System.Threading.Tasks.Task]::FromResult($response)
        $cts = [System.Threading.CancellationTokenSource]::new()
        Invoke-McpInModule { param($t, $c) Stop-McpHttpSendTask -Task $t -Cts $c } -Parameters @{ t = $task; c = $cts }
        $cts.IsCancellationRequested | Should -BeTrue
        $body.CanRead | Should -BeFalse
    }

    It 'cancels a pending send and returns once it settled' {
        $source = [System.Threading.Tasks.TaskCompletionSource[System.Net.Http.HttpResponseMessage]]::new()
        $cts = [System.Threading.CancellationTokenSource]::new()
        $null = $cts.Token.Register([System.Action] { $null = $source.TrySetCanceled() }.GetNewClosure())
        { Invoke-McpInModule { param($t, $c) Stop-McpHttpSendTask -Task $t -Cts $c } -Parameters @{ t = $source.Task; c = $cts } } | Should -Not -Throw
        $source.Task.IsCanceled | Should -BeTrue
    }

    It 'tolerates a failed send and a disposed token source' {
        $failed = [System.Threading.Tasks.Task]::FromException([System.Net.Http.HttpRequestException]::new('refused'))
        $cts = [System.Threading.CancellationTokenSource]::new()
        $cts.Dispose()
        { Invoke-McpInModule { param($t, $c) Stop-McpHttpSendTask -Task $t -Cts $c } -Parameters @{ t = $failed; c = $cts } } | Should -Not -Throw
    }

    It 'returns after the settle time when a send never ends' {
        $source = [System.Threading.Tasks.TaskCompletionSource[System.Net.Http.HttpResponseMessage]]::new()
        $cts = [System.Threading.CancellationTokenSource]::new()
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-McpInModule { param($t, $c) Stop-McpHttpSendTask -Task $t -Cts $c -SettleMs 100 } -Parameters @{ t = $source.Task; c = $cts }
        $stopwatch.ElapsedMilliseconds | Should -BeLessThan 2000
        $source.Task.IsCompleted | Should -BeFalse
    }
}
