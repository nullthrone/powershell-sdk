#Requires -Version 7.4
<#
    Helper functions shared by the Pester test files. Import in BeforeAll:
        Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
#>

Set-StrictMode -Version Latest

function Get-McpRepositoryRoot {
    <#
    .SYNOPSIS
        Absolute path of the repository root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    (Resolve-Path -Path (Join-Path $PSScriptRoot '..' '..')).Path
}

function Get-McpBuiltModuleManifest {
    <#
    .SYNOPSIS
        Path of the built module manifest: $env:MCP_MODULE_MANIFEST if set, otherwise the newest build under output/.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($env:MCP_MODULE_MANIFEST) {
        if (-not (Test-Path -Path $env:MCP_MODULE_MANIFEST)) {
            throw "MCP_MODULE_MANIFEST points to '$env:MCP_MODULE_MANIFEST', which does not exist."
        }
        return (Resolve-Path -Path $env:MCP_MODULE_MANIFEST).Path
    }
    $outputRoot = Join-Path (Get-McpRepositoryRoot) 'output' 'ModelContextProtocol'
    $newest = Get-ChildItem -Path $outputRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -as [version] } |
        Sort-Object -Property { [version] $_.Name } -Descending |
        Select-Object -First 1
    if (-not $newest) {
        throw "No built module found under '$outputRoot'. Run ./build.ps1 -Task Build first."
    }
    Join-Path $newest.FullName 'ModelContextProtocol.psd1'
}

function Get-McpSpecSchemaPath {
    <#
    .SYNOPSIS
        Path of the vendored schema.json for a specification revision.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
        [string] $Revision
    )

    Join-Path (Get-McpRepositoryRoot) 'tests' 'Spec' "${Revision}_schema.json"
}

function Get-McpSpecSchema {
    <#
    .SYNOPSIS
        The vendored schema.json of a revision as nested hashtables.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $Revision
    )

    Get-Content -Path (Get-McpSpecSchemaPath -Revision $Revision) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
}

function Get-McpSpecDefinition {
    <#
    .SYNOPSIS
        The definitions table of a vendored schema ($defs for 2020-12 schemas, definitions for draft-07).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $Revision
    )

    $schema = Get-McpSpecSchema -Revision $Revision
    if ($schema.ContainsKey('$defs')) { $schema['$defs'] } else { $schema['definitions'] }
}

function Invoke-McpChildProcess {
    <#
    .SYNOPSIS
        Runs an executable with redirected UTF-8 streams and returns exit code, stdout and stderr.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [string[]] $ArgumentList = @(),

        [int] $TimeoutSeconds = 120
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    foreach ($argument in $ArgumentList) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            throw "Process '$FilePath' did not exit within $TimeoutSeconds seconds."
        }
        $process.WaitForExit()
        @{
            ExitCode = $process.ExitCode
            StdOut   = $stdoutTask.GetAwaiter().GetResult()
            StdErr   = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Get-McpPowerShellPath {
    <#
    .SYNOPSIS
        Path of the pwsh executable running the tests.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    (Get-Process -Id $PID).Path
}

Export-ModuleMember -Function Get-McpRepositoryRoot, Get-McpBuiltModuleManifest, Get-McpSpecSchemaPath, Get-McpSpecSchema, Get-McpSpecDefinition, Invoke-McpChildProcess, Get-McpPowerShellPath
