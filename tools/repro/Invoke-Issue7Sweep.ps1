# TEMPORARY (issue #7): sweeps the client timeout across the server's switch to SSE (KeepAliveSeconds = 1) so
# that the response headers arrive around the client deadline, and checks after each call whether the server
# stopped the handler. Platform independent; requires a built module under output/.
[CmdletBinding()]
param(
    [int] $FromMs = 950,
    [int] $ToMs = 1300,
    [int] $StepMs = 10,
    [string] $LogPath = (Join-Path $PSScriptRoot '..' '..' 'output' 'repro' 'sweep.log')
)

$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..' '..'
Import-Module (Join-Path $root 'tests' 'Support' 'McpTestSupport.psm1') -Force
Import-Module (Get-McpBuiltModuleManifest) -Force
$null = New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force
$env:MCP_REPRO_LOG = $LogPath
$server = New-McpServer -Name 'sweep' -Version '1.0.0' -RequestTimeoutSeconds 30
Register-McpTool -Name 'count' -Description 'Counts; a marker file records where it stopped.' -ScriptBlock {
    param([int] $To = 3, [int] $DelayMs = 20, [string] $MarkerPath = '', $Context)
    $i = 0
    try {
        for ($i = 1; $i -le $To; $i++) {
            if ($Context.CancellationToken.IsCancellationRequested) { return "cancelled at $i" }
            Start-Sleep -Milliseconds $DelayMs
        }
        "counted to $To"
    } finally {
        if ($MarkerPath) { [System.IO.File]::WriteAllText($MarkerPath, "stopped at $i of $To") }
    }
} -Server $server
$handle = Start-McpTestHttpServer -Server $server -Parameters @{ KeepAliveSeconds = 1 }
$session = Connect-McpServer -Url $handle.Url
$module = Get-Module -Name ModelContextProtocol
$rows = [System.Collections.Generic.List[object]]::new()
try {
    for ($timeout = $FromMs; $timeout -le $ToMs; $timeout += $StepMs) {
        $marker = Join-Path ([System.IO.Path]::GetTempPath()) ('mcp-sweep-' + [guid]::NewGuid().ToString('n') + '.txt')
        $params = [ordered]@{ name = 'count'; arguments = [ordered]@{ To = 200; DelayMs = 50; MarkerPath = $marker } }
        $outcome = 'no timeout'
        try {
            $null = & $module { param($s, $p, $t) Invoke-McpHttpClientRequest -Session $s -Method 'tools/call' -Params $p -TimeoutMs $t } $session $params $timeout
        } catch [System.TimeoutException] {
            $outcome = 'timeout'
        }
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -Path $marker) -and $stopwatch.Elapsed.TotalSeconds -lt 8) { Start-Sleep -Milliseconds 50 }
        $text = if (Test-Path $marker) { [System.IO.File]::ReadAllText($marker) } else { 'MISSING' }
        $stopped = $text -match '^stopped at (\d+) of 200$' -and [int] $Matches[1] -lt 150
        $rows.Add([pscustomobject]@{ TimeoutMs = $timeout; Client = $outcome; StoppedAfterS = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1); Marker = $text; Ok = $stopped })
        Remove-Item -Path $marker -ErrorAction SilentlyContinue
    }
} finally {
    Disconnect-McpServer -Session $session
    Stop-McpTestHttpServer -Handle $handle
    Remove-Item Env:MCP_REPRO_LOG
}
$trace = Get-Content -Raw $LogPath
$leaks = ([regex]::Matches($trace, 'LEAKED RESPONSE')).Count
$bad = @($rows | Where-Object { -not $_.Ok }).Count
$summary = @(
    "## Issue #7 timeout sweep: $($PSVersionTable.OS), pwsh $($PSVersionTable.PSVersion)", '',
    "Handler not stopped: **$bad / $($rows.Count)**; leaked responses in the trace: $leaks", '',
    '| Timeout (ms) | Client | Marker after (s) | Marker | OK |', '|---|---|---|---|---|'
) + ($rows | ForEach-Object { '| {0} | {1} | {2} | {3} | {4} |' -f $_.TimeoutMs, $_.Client, $_.StoppedAfterS, $_.Marker, $_.Ok })
if ($env:GITHUB_STEP_SUMMARY) { $summary | Add-Content -Path $env:GITHUB_STEP_SUMMARY }
$summary | Write-Host
