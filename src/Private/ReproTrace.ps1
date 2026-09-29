# TEMPORARY (issue #7 diagnostics): appends a timestamped line to $env:MCP_REPRO_LOG when it is set.
function Write-McpReproTrace {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    $path = $env:MCP_REPRO_LOG
    if (-not $path) { return }
    $line = '{0} [t{1}] {2}{3}' -f [datetime]::UtcNow.ToString('HH:mm:ss.fff', [System.Globalization.CultureInfo]::InvariantCulture), [System.Threading.Thread]::CurrentThread.ManagedThreadId, $Message, [Environment]::NewLine
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try { [System.IO.File]::AppendAllText($path, $line); return } catch { [System.Threading.Thread]::Sleep(2) }
    }
}
