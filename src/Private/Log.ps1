# Diagnostics go to stderr: over stdio, stdout carries protocol messages only. Lines are "timestamp [level]
# [logger] message" in UTF-8; the level threshold comes from the server options (default: warning).

$script:McpDefaultLogLevel = [McpLoggingLevel]::Warning

function ConvertTo-McpLoggingLevel {
    [CmdletBinding()]
    [OutputType([McpLoggingLevel])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Level
    )

    if ($null -eq $Level) { return $script:McpDefaultLogLevel }
    if ($Level -is [McpLoggingLevel]) { return $Level }
    $parsed = [McpLoggingLevel]::Debug
    if ([System.Enum]::TryParse([McpLoggingLevel], [string] $Level, $true, [ref] $parsed)) { return $parsed }
    throw [System.ArgumentException]::new("'$Level' is not a logging level (debug, info, notice, warning, error, critical, alert, emergency).")
}

function Write-McpStderr {
    <#
    .SYNOPSIS
        Writes a diagnostic line to stderr when its level reaches the threshold.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Message,

        [object] $Level = [McpLoggingLevel]::Info,

        [object] $Threshold = $script:McpDefaultLogLevel,

        [string] $Logger
    )

    $levelValue = ConvertTo-McpLoggingLevel -Level $Level
    $thresholdValue = ConvertTo-McpLoggingLevel -Level $Threshold
    if ([int] $levelValue -lt [int] $thresholdValue) { return }
    $prefix = if ($Logger) { "[$Logger] " } else { '' }
    $line = '{0} [{1}] {2}{3}' -f [datetime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture), $levelValue.ToString().ToLowerInvariant(), $prefix, $Message
    [Console]::Error.WriteLine($line)
}
