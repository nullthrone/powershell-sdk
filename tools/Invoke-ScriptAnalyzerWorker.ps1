<#
.SYNOPSIS
    Runs PSScriptAnalyzer over one path in this process and writes findings and rule failures to a Clixml file.
.DESCRIPTION
    Worker of the Analyze task (ModelContextProtocol.build.ps1). The build runs every analysis in a fresh pwsh
    process with a timeout because PSScriptAnalyzer 1.25 runs its rules in parallel tasks that are not entirely
    thread-safe: a rule occasionally fails on a file with a NullReferenceException or, after a lost command
    lookup, with "The term 'Get-Command' is not recognized", and the process keeps that state until it exits.
    The analyzer reports such a failure as a non-terminating error whose target is the affected file and still
    returns the findings of every other rule, so this worker records both: the findings (Severity, RuleName,
    ScriptPath, Line, Message) and the failures (File, Message). The build re-analyses the affected files in
    fresh processes.
.PARAMETER Path
    The file or folder (recursive) to analyse.
.PARAMETER Settings
    The PSScriptAnalyzer settings file of the repository.
.PARAMETER CustomRulePath
    The custom rule module of the repository.
.PARAMETER ResultPath
    Where the Clixml result (a hashtable with Findings and Failures) is written.
.OUTPUTS
    None. Exit code 0 when the analysis ran, 1 when it could not run at all.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Path,

    [Parameter(Mandatory)]
    [string] $Settings,

    [Parameter(Mandatory)]
    [string] $CustomRulePath,

    [Parameter(Mandatory)]
    [string] $ResultPath
)

$ErrorActionPreference = 'Stop'
Import-Module -Name PSScriptAnalyzer -MinimumVersion 1.25.0

$ruleErrors = @()
$parameters = @{
    Path                = $Path
    Settings            = $Settings
    CustomRulePath      = $CustomRulePath
    IncludeDefaultRules = $true
    ErrorAction         = 'SilentlyContinue'
    ErrorVariable       = 'ruleErrors'
}
if (Test-Path -Path $Path -PathType Container) { $parameters['Recurse'] = $true }
$findings = @(Invoke-ScriptAnalyzer @parameters | Select-Object -Property Severity, RuleName, ScriptPath, Line, Message)
$failures = @(foreach ($record in $ruleErrors) {
        $file = if ($record.TargetObject -is [string] -and $record.TargetObject) { $record.TargetObject } else { $Path }
        [pscustomobject]@{ File = $file; Message = $record.Exception.Message.Split("`n")[0].Trim() }
    })
@{ Findings = $findings; Failures = $failures } | Export-Clixml -Path $ResultPath -Depth 3
