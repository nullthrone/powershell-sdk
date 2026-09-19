#Requires -Version 7.4
<#
    Custom PSScriptAnalyzer rules for the ModelContextProtocol repository.

    Loaded with -CustomRulePath by the Analyze task (ModelContextProtocol.build.ps1) and by
    tests/Unit/ScriptAnalyzerRules.Tests.ps1. Rule functions take the ScriptBlockAst of the analysed file and
    return DiagnosticRecord objects. Findings carry the function name as RuleName, and that plain name is
    what SuppressMessageAttribute must reference, for example
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('Measure-McpStdoutPurity', '', Justification = '...')].
#>

Set-StrictMode -Version Latest

$script:StdoutRuleName = 'Measure-McpStdoutPurity'
$script:InvokeExpressionRuleName = 'Measure-McpNoInvokeExpression'

# Commands that write to the host or to stdout, or read from the console.
$script:HostBoundCommands = @(
    'Write-Host', 'Out-Host', 'Out-Default', 'Out-Printer', 'Out-GridView', 'Read-Host', 'Show-Command'
)

# Static members of [Console] that touch stdout (stderr members such as Error and OpenStandardError are allowed).
$script:ConsoleStdoutMembers = @('Write', 'WriteLine', 'Out', 'OpenStandardOutput', 'SetOut')

# Files below src/ that implement the transport writer and therefore may use the console and stdout.
$script:TransportWriterFilePatterns = @('*Stdio*.ps1', '*Transport*.ps1', '*ConsoleWriter*.ps1')

function Test-McpSourceFile {
    <#
    .SYNOPSIS
        True when the analysed file is a module source file (below src/) that is not a transport writer.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Path
    )

    if ([string]::IsNullOrEmpty($Path)) { return $false }
    $normalized = $Path -replace '\\', '/'
    if ($normalized -notmatch '/src/') { return $false }
    $leaf = Split-Path -Path $normalized -Leaf
    foreach ($pattern in $script:TransportWriterFilePatterns) {
        if ($leaf -like $pattern) { return $false }
    }
    $true
}

function Test-McpConsoleTypeExpression {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [System.Management.Automation.Language.ExpressionAst] $Expression
    )

    if ($Expression -isnot [System.Management.Automation.Language.TypeExpressionAst]) { return $false }
    $name = $Expression.TypeName.FullName
    $name -eq 'Console' -or $name -eq 'System.Console'
}

function Get-McpMemberName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [System.Management.Automation.Language.MemberExpressionAst] $Member
    )

    if ($Member.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return $Member.Member.Value
    }
    $null
}

function New-McpDiagnosticRecord {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record; no system state changes.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'The DiagnosticRecord type resolves only after PSScriptAnalyzer loaded its assembly, so it is declared by name.')]
    [CmdletBinding()]
    [OutputType('Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord')]
    param(
        [Parameter(Mandatory)]
        [string] $Message,

        [Parameter(Mandatory)]
        [System.Management.Automation.Language.IScriptExtent] $Extent,

        [Parameter(Mandatory)]
        [string] $RuleName,

        [Parameter(Mandatory)]
        [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity] $Severity
    )

    [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{
        Message  = $Message
        Extent   = $Extent
        RuleName = $RuleName
        Severity = $Severity
    }
}

function Measure-McpStdoutPurity {
    <#
    .SYNOPSIS
        Nothing but the transport writer may write to stdout or use the host.
    .DESCRIPTION
        Over a stdio transport, stdout carries protocol messages only. This rule flags host-bound commands
        (Write-Host, Out-Host, Out-Default, Out-Printer, Out-GridView, Read-Host, Show-Command), stdout members of
        [Console] (Write, WriteLine, Out, OpenStandardOutput, SetOut) and any use of $Host.UI in files below src/,
        except in the transport writer files (*Stdio*.ps1, *Transport*.ps1, *ConsoleWriter*.ps1).
        Diagnostics belong on stderr ([Console]::Error, Write-Verbose, Write-Warning) or in notifications/message.
    .OUTPUTS
        Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord
    #>
    [CmdletBinding()]
    [OutputType('Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.Language.ScriptBlockAst] $ScriptBlockAst
    )

    process {
        # PSScriptAnalyzer invokes the rule for every ScriptBlockAst in the file; analyse only the top-level one.
        if ($null -ne $ScriptBlockAst.Parent) { return }
        if (-not (Test-McpSourceFile -Path $ScriptBlockAst.Extent.File)) { return }
        $errorSeverity = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity]::Error

        $commands = $ScriptBlockAst.FindAll({
                param($ast)
                $ast -is [System.Management.Automation.Language.CommandAst] -and $ast.GetCommandName() -in $script:HostBoundCommands
            }, $true)
        foreach ($command in $commands) {
            New-McpDiagnosticRecord -RuleName $script:StdoutRuleName -Severity $errorSeverity -Extent $command.Extent -Message (
                "'{0}' writes to the host or stdout. Only the transport writer may do that; use Write-Verbose, Write-Warning, [Console]::Error or notifications/message instead." -f $command.GetCommandName())
        }

        $members = $ScriptBlockAst.FindAll({
                param($ast)
                $ast -is [System.Management.Automation.Language.MemberExpressionAst]
            }, $true)
        foreach ($member in $members) {
            $memberName = Get-McpMemberName -Member $member
            if (-not $memberName) { continue }
            if ((Test-McpConsoleTypeExpression -Expression $member.Expression) -and $memberName -in $script:ConsoleStdoutMembers) {
                New-McpDiagnosticRecord -RuleName $script:StdoutRuleName -Severity $errorSeverity -Extent $member.Extent -Message (
                    "[Console]::{0} touches stdout. Only the transport writer may do that; use [Console]::Error for diagnostics." -f $memberName)
                continue
            }
            if ($memberName -eq 'UI' -and $member.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and $member.Expression.VariablePath.UserPath -eq 'Host') {
                New-McpDiagnosticRecord -RuleName $script:StdoutRuleName -Severity $errorSeverity -Extent $member.Extent -Message (
                    '$Host.UI writes to the host. Only the transport writer may do that.')
            }
        }
    }
}

function Measure-McpNoInvokeExpression {
    <#
    .SYNOPSIS
        Do not evaluate strings as code.
    .DESCRIPTION
        Flags Invoke-Expression (and its alias iex), $ExecutionContext.InvokeCommand.InvokeScript and
        InvokeCommand.ExpandString as errors, and [scriptblock]::Create as a warning that needs a justified
        suppression, in every analysed file. Handler code reaches the runspace pool as function definitions
        derived from the caller's AST, never through string evaluation.
    .OUTPUTS
        Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord
    #>
    [CmdletBinding()]
    [OutputType('Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.Language.ScriptBlockAst] $ScriptBlockAst
    )

    process {
        # PSScriptAnalyzer invokes the rule for every ScriptBlockAst in the file; analyse only the top-level one.
        if ($null -ne $ScriptBlockAst.Parent) { return }
        $errorSeverity = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity]::Error
        $warningSeverity = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity]::Warning

        $commands = $ScriptBlockAst.FindAll({
                param($ast)
                $ast -is [System.Management.Automation.Language.CommandAst] -and $ast.GetCommandName() -in @('Invoke-Expression', 'iex')
            }, $true)
        foreach ($command in $commands) {
            New-McpDiagnosticRecord -RuleName $script:InvokeExpressionRuleName -Severity $errorSeverity -Extent $command.Extent -Message (
                "'{0}' evaluates a string as code and is forbidden in this repository." -f $command.GetCommandName())
        }

        $invocations = $ScriptBlockAst.FindAll({
                param($ast)
                $ast -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
            }, $true)
        foreach ($invocation in $invocations) {
            $memberName = Get-McpMemberName -Member $invocation
            if (-not $memberName) { continue }
            if ($memberName -in @('InvokeScript', 'ExpandString') -and $invocation.Expression.Extent.Text -match 'InvokeCommand$') {
                New-McpDiagnosticRecord -RuleName $script:InvokeExpressionRuleName -Severity $errorSeverity -Extent $invocation.Extent -Message (
                    "InvokeCommand.{0} evaluates a string as code and is forbidden in this repository." -f $memberName)
                continue
            }
            if ($memberName -eq 'Create' -and $invocation.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and $invocation.Expression.TypeName.FullName -in @('scriptblock', 'System.Management.Automation.ScriptBlock')) {
                New-McpDiagnosticRecord -RuleName $script:InvokeExpressionRuleName -Severity $warningSeverity -Extent $invocation.Extent -Message (
                    '[scriptblock]::Create compiles a string into code. Derive script blocks from an existing AST instead, or suppress this finding with a justification.')
            }
        }
    }
}

Export-ModuleMember -Function Measure-McpStdoutPurity, Measure-McpNoInvokeExpression
