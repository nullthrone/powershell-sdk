# TEMPORARY (issue #7): runs the flaky integration test N times in fresh processes and classifies each run from
# the trace written by the instrumented module ($env:MCP_REPRO_LOG). Requires a built module under output/.
[CmdletBinding()]
param(
    [int] $Iterations = 30,
    [string] $LogDirectory = (Join-Path $PSScriptRoot '..' '..' 'output' 'repro'),
    [string] $FullName = '*stops the handler when the client closes the connection on timeout*'
)

$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Path $LogDirectory -Force
$LogDirectory = (Resolve-Path $LogDirectory).Path
$testFile = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'tests' 'Integration' 'HttpServer.Tests.ps1')).Path
$pwsh = (Get-Process -Id $PID).Path
$rows = [System.Collections.Generic.List[object]]::new()
for ($i = 1; $i -le $Iterations; $i++) {
    $log = Join-Path $LogDirectory ('run-{0:d2}.log' -f $i)
    $env:MCP_REPRO_LOG = $log
    $script = @"
Import-Module Pester -MinimumVersion 6.2.0
`$c = New-PesterConfiguration
`$c.Run.Path = '$testFile'
`$c.Run.PassThru = `$true
`$c.Filter.FullName = '$FullName'
`$c.Output.Verbosity = 'Normal'
`$r = Invoke-Pester -Configuration `$c
if (`$r.PassedCount -eq 1 -and `$r.FailedCount -eq 0) { exit 0 } else { exit 1 }
"@
    $output = & $pwsh -NoLogo -NoProfile -NonInteractive -Command $script 2>&1
    $passed = $LASTEXITCODE -eq 0
    $text = if (Test-Path $log) { Get-Content -Raw $log } else { '' }
    $leak = $text -match 'LEAKED RESPONSE'
    $headerTimeout = $text -match 'header timeout'
    $sseTimeout = $text -match 'SSE read timeout'
    $writeFailed = $text -match 'SSE write FAILED'
    $keepAlives = ([regex]::Matches($text, 'keep-alive write OK')).Count
    $marker = if ($text -match 'test marker after [^:]+: (.*)') { $Matches[1].Trim() } else { '?' }
    $row = [pscustomobject]@{
        Run = $i; Passed = $passed; ClientPath = $(if ($headerTimeout) { 'header-timeout' } elseif ($sseTimeout) { 'sse-timeout' } else { '?' })
        Leak = $leak; KeepAliveOk = $keepAlives; WriteFailed = $writeFailed; Marker = $marker
    }
    $rows.Add($row)
    $row | Format-Table -HideTableHeaders | Out-String | Write-Host
    if (-not $passed) {
        Write-Host "---- run $i FAILED; Pester output ----"
        $output | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
        Write-Host "---- run $i trace ----"
        Write-Host $text
    }
}
Remove-Item Env:MCP_REPRO_LOG
$failed = @($rows | Where-Object { -not $_.Passed }).Count
$summary = @(
    "## Issue #7 repro: $($PSVersionTable.OS), pwsh $($PSVersionTable.PSVersion)", '',
    "Failures: **$failed / $Iterations**; leaked responses: $(@($rows | Where-Object Leak).Count)", '',
    '| Run | Passed | Client path | Leak | Keep-alives OK | Write failed | Marker |', '|---|---|---|---|---|---|---|'
) + ($rows | ForEach-Object { '| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $_.Run, $_.Passed, $_.ClientPath, $_.Leak, $_.KeepAliveOk, $_.WriteFailed, $_.Marker })
if ($env:GITHUB_STEP_SUMMARY) { $summary | Add-Content -Path $env:GITHUB_STEP_SUMMARY }
$summary | Write-Host
