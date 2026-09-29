function Set-McpLogLevel {
    <#
    .SYNOPSIS
        Sets the level from which the server sends log notifications (notifications/message) to this session.
    .DESCRIPTION
        In revision 2026-07-28 the level travels with every request (io.modelcontextprotocol/logLevel); this
        command sets the session's default, which Invoke-McpTool, Invoke-McpPrompt and Read-McpResource send unless
        they are given -LogLevel. In a legacy session (revision 2025-11-25 or earlier) it sends logging/setLevel,
        which applies to everything the server logs from then on. Logging is deprecated in revision 2026-07-28.
    .PARAMETER Level
        The minimum level: debug, info, notice, warning, error, critical, alert or emergency.
    .PARAMETER Session
        The session; defaults to the default session.
    .EXAMPLE
        Set-McpLogLevel -Level warning
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [McpLoggingLevel] $Level,

        [object] $Session
    )

    $target = Resolve-McpSession -Session $Session
    if (-not $PSCmdlet.ShouldProcess("session '$($target.Name)'", "Set log level $Level")) { return }
    if ($target.Era -eq 'Legacy') { Set-McpLegacyClientLogLevel -Session $target -Level $Level }
    $target.LogLevel = $Level
}
