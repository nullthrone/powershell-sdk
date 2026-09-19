#Requires -Version 7.4
<#
.SYNOPSIS
    Extracts the section of a Keep-a-Changelog file for one version.

.DESCRIPTION
    Returns the lines between the heading "## [<Version>]" and the next "## " heading. When no section for the
    version exists and -FallbackToUnreleased is given, the "## [Unreleased]" section is returned instead.

.PARAMETER Version
    Version without a leading "v", for example 0.1.0-preview1.

.PARAMETER Path
    Path to CHANGELOG.md (default: the file in the repository root).

.PARAMETER FallbackToUnreleased
    Use the Unreleased section when the version has no section of its own.

.EXAMPLE
    ./tools/Get-ChangelogSection.ps1 -Version 0.1.0-preview1 -FallbackToUnreleased
#>
[CmdletBinding()]
[OutputType([string])]
param(
    [Parameter(Mandatory)]
    [string] $Version,

    [string] $Path = (Join-Path $PSScriptRoot '..' 'CHANGELOG.md'),

    [switch] $FallbackToUnreleased
)

$ErrorActionPreference = 'Stop'
$lines = Get-Content -Path $Path

function Get-ChangelogSectionContent {
    param([string[]] $Lines, [string] $Heading)
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -eq $Heading) { $start = $i + 1; break }
    }
    if ($start -lt 0) { return $null }
    $end = $Lines.Count
    for ($i = $start; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -like '## *') { $end = $i; break }
    }
    $section = $Lines[$start..($end - 1)]
    # Trim leading and trailing blank lines.
    while ($section.Count -gt 0 -and [string]::IsNullOrWhiteSpace($section[0])) { $section = $section | Select-Object -Skip 1 }
    while ($section.Count -gt 0 -and [string]::IsNullOrWhiteSpace($section[-1])) { $section = $section | Select-Object -SkipLast 1 }
    , $section
}

$section = Get-ChangelogSectionContent -Lines $lines -Heading "## [$Version]"
if ($null -eq $section -and $FallbackToUnreleased) {
    $section = Get-ChangelogSectionContent -Lines $lines -Heading '## [Unreleased]'
}
if ($null -eq $section) {
    throw "CHANGELOG.md has no section for version '$Version'."
}
$section -join "`n"
