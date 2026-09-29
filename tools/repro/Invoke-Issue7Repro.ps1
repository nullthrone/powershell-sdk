# TEMPORARY (issue #7): runs the flaky integration test N times in fresh processes and classifies each run from
# the trace written by the instrumented module ($env:MCP_REPRO_LOG). Requires a built module under output/.
[CmdletBinding()]
param(
    [int] $Iterations = 30,
    [string] $LogDirectory = (Join-Path $PSScriptRoot '..' '..' 'output' 'repro'),
    [string] $FullName = '*stops the handler when the client closes the connection on timeout*',
    # Test files relative to tests/; the default runs only the flaky test's file.
    [string[]] $Path = @('Integration/HttpServer.Tests.ps1'),
    [switch] $WholeFiles
)

$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Path $LogDirectory -Force
$LogDirectory = (Resolve-Path $LogDirectory).Path
$testFiles = ($Path | ForEach-Object { "'" + (Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'tests' $_)).Path + "'" }) -join ','
$pwsh = (Get-Process -Id $PID).Path
$rows = [System.Collections.Generic.List[object]]::new()
for ($i = 1; $i -le $Iterations; $i++) {
    $log = Join-Path $LogDirectory ('{0}-run-{1:d2}.log' -f $(if ($WholeFiles) { 'files' } else { 'single' }), $i)
    $env:MCP_REPRO_LOG = $log
    $script = @"
Import-Module Pester -MinimumVersion 6.2.0
`$c = New-PesterConfiguration
`$c.Run.Path = @($testFiles)
`$c.Run.PassThru = `$true
if (-not `$$([bool] $WholeFiles)) { `$c.Filter.FullName = '$FullName' }
`$c.Output.Verbosity = 'Normal'
`$r = Invoke-Pester -Configuration `$c
`$r.Failed | ForEach-Object { 'FAILED TEST: ' + `$_.ExpandedPath }
if (`$r.PassedCount -ge 1 -and `$r.FailedCount -eq 0) { exit 0 } else { exit 1 }
"@
    $output = & $pwsh -NoLogo -NoProfile -NonInteractive -Command $script 2>&1
    $passed = $LASTEXITCODE -eq 0
    $text = if (Test-Path $log) { Get-Content -Raw $log } else { '' }
    $leak = $text -match 'sendTask after Stop-McpHttpSendTask: RanToCompletion'
    $headerTimeout = $text -match 'header timeout'
    $sseTimeout = $text -match 'SSE read timeout'
    $writeFailed = $text -match 'SSE write FAILED'
    $keepAlives = ([regex]::Matches($text, 'keep-alive write OK')).Count
    $slowTicks = ([regex]::Matches($text, 'dispatcher tick took')).Count
    $marker = if ($text -match 'test marker after [^:]+: (.*)') { $Matches[1].Trim() } else { '?' }
    $row = [pscustomobject]@{
        Run = $i; Passed = $passed; ClientPath = $(if ($headerTimeout) { 'header-timeout' } elseif ($sseTimeout) { 'sse-timeout' } else { '?' })
        Leak = $leak; KeepAliveOk = $keepAlives; SlowTicks = $slowTicks; WriteFailed = $writeFailed; Marker = $marker
    }
    $rows.Add($row)
    $row | Format-Table -HideTableHeaders | Out-String | Write-Host
    if (-not $passed) {
        Write-Host "---- run $i FAILED; Pester output ----"
        $output | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
        Write-Host "---- run $i trace (timeout test window) ----"
        $lines = $text -split "`r?`n"
        $start = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match 'header timeout|SSE read timeout' })
        if ($start -lt 0) { $start = 0 }
        $lines[[math]::Max(0, $start - 5)..[math]::Min($lines.Count - 1, $start + 120)] | ForEach-Object { Write-Host $_ }
    }
}
Remove-Item Env:MCP_REPRO_LOG
$failed = @($rows | Where-Object { -not $_.Passed }).Count
$summary = @(
    "## Issue #7 repro ($($Path -join ', '), whole files: $([bool] $WholeFiles)): $($PSVersionTable.OS), pwsh $($PSVersionTable.PSVersion)", '',
    "Failures: **$failed / $Iterations**; late responses (headers arrived during the cancel): $(@($rows | Where-Object Leak).Count)", '',
    '| Run | Passed | Client path | Late response | Keep-alives OK | Slow ticks | Write failed | Marker |', '|---|---|---|---|---|---|---|---|'
) + ($rows | ForEach-Object { '| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f $_.Run, $_.Passed, $_.ClientPath, $_.Leak, $_.KeepAliveOk, $_.SlowTicks, $_.WriteFailed, $_.Marker })
if ($env:GITHUB_STEP_SUMMARY) { $summary | Add-Content -Path $env:GITHUB_STEP_SUMMARY }
$summary | Write-Host
