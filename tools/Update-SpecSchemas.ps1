#Requires -Version 7.4
<#
.SYNOPSIS
    Refreshes the vendored specification schemas under tests/Spec from the specification repository.

.DESCRIPTION
    Downloads schema.json and schema.ts for every revision at the given commit of
    modelcontextprotocol/modelcontextprotocol (via raw.githubusercontent.com), stores them as
    tests/Spec/<revision>_schema.{json,ts}, regenerates tests/Spec/manifest.json (commit, retrieval date,
    SHA-256 and definition count per file) and tests/Spec/definitions-checklist.txt (the definition names of the
    primary revision, ordinally sorted, one per line).

.PARAMETER Commit
    Full 40-character commit SHA of the specification repository to vendor.

.PARAMETER Revision
    Revisions to vendor (default: 2026-07-28, 2025-11-25, 2025-06-18).

.PARAMETER PrimaryRevision
    Revision whose definitions form the checklist (default: 2026-07-28).

.PARAMETER OutputPath
    Target folder (default: tests/Spec).

.EXAMPLE
    ./tools/Update-SpecSchemas.ps1 -Commit 24efd6e7cbd7a074e6b3b781eb370891df40afad
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $Commit,

    [string[]] $Revision = @('2026-07-28', '2025-11-25', '2025-06-18'),

    [string] $PrimaryRevision = '2026-07-28',

    [string] $Repository = 'modelcontextprotocol/modelcontextprotocol',

    [string] $OutputPath = (Join-Path $PSScriptRoot '..' 'tests' 'Spec')
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$null = New-Item -ItemType Directory -Path $OutputPath -Force
$OutputPath = (Resolve-Path -Path $OutputPath).Path

$files = foreach ($rev in $Revision) {
    foreach ($name in 'schema.json', 'schema.ts') {
        $upstream = "schema/$rev/$name"
        $uri = "https://raw.githubusercontent.com/$Repository/$Commit/$upstream"
        $target = Join-Path $OutputPath ('{0}_{1}' -f $rev, $name)
        if ($PSCmdlet.ShouldProcess($target, "Download $uri")) {
            Invoke-WebRequest -Uri $uri -OutFile $target
        }
        $entry = [ordered]@{
            path     = Split-Path -Path $target -Leaf
            revision = $rev
            upstream = $upstream
            sha256   = (Get-FileHash -Path $target -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        if ($name -eq 'schema.json') {
            $schema = Get-Content -Path $target -Raw | ConvertFrom-Json -AsHashtable -Depth 100
            $definitions = if ($schema.ContainsKey('$defs')) { $schema['$defs'] } else { $schema['definitions'] }
            $entry['dialect'] = $schema['$schema']
            $entry['definitions'] = $definitions.Count
            if ($rev -eq $PrimaryRevision) {
                $names = @($definitions.Keys)
                [Array]::Sort($names, [System.StringComparer]::Ordinal)
                $checklist = Join-Path $OutputPath 'definitions-checklist.txt'
                if ($PSCmdlet.ShouldProcess($checklist, 'Write definition checklist')) {
                    [System.IO.File]::WriteAllText($checklist, ($names -join "`n") + "`n", $utf8NoBom)
                }
            }
        }
        [pscustomobject] $entry
    }
}

$manifest = [ordered]@{
    source          = "https://github.com/$Repository"
    commit          = $Commit
    retrieved       = (Get-Date -Format 'yyyy-MM-dd')
    primaryRevision = $PrimaryRevision
    files           = @($files)
}
$manifestPath = Join-Path $OutputPath 'manifest.json'
if ($PSCmdlet.ShouldProcess($manifestPath, 'Write provenance manifest')) {
    $json = ($manifest | ConvertTo-Json -Depth 5) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($manifestPath, $json + "`n", $utf8NoBom)
}
$files | Format-Table -Property path, definitions, sha256 -AutoSize
