function Disconnect-McpServer {
    <#
    .SYNOPSIS
        Closes a session: closes the server's standard input, waits for the process to exit and kills it if it does not.
    .DESCRIPTION
        For an in-memory session the background server runspace is stopped as well. Closing the default session
        clears the default.
    .PARAMETER Session
        The session to close; defaults to the default session.
    .PARAMETER ExitTimeoutSeconds
        How long to wait for a server process to exit before it is killed (default: 5).
    .EXAMPLE
        Disconnect-McpServer -Session $session
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [object] $Session,

        [ValidateRange(0, 600)]
        [int] $ExitTimeoutSeconds = 5
    )

    $target = if ($null -ne $Session) { $Session } else { $script:McpDefaultSession }
    if ($null -eq $target) { return }
    if (-not (Test-McpSessionObject -Session $target)) {
        throw [System.ArgumentException]::new('The -Session argument is not a session created by Connect-McpServer.')
    }
    if ($target.Closed) { return }
    if (-not $PSCmdlet.ShouldProcess("session '$($target.Name)'", 'Disconnect')) { return }
    $target.Closed = $true
    Close-McpTransport -Transport $target.Transport -ExitTimeoutSeconds $ExitTimeoutSeconds
    if ($null -ne $target.Background) {
        Stop-McpBackgroundServer -Background $target.Background
        $target.Background = $null
    }
    if ($null -ne $script:McpDefaultSession -and [object]::ReferenceEquals($script:McpDefaultSession, $target)) {
        $script:McpDefaultSession = $null
    }
}
