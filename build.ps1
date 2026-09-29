#Requires -Version 7.4
<#
.SYNOPSIS
    Build entry point: installs the build dependencies on demand and runs Invoke-Build tasks.

.DESCRIPTION
    Reads requirements.psd1, verifies that every build dependency is installed in the declared version range
    (installing it with -Bootstrap when it is not) and then runs the requested tasks from
    ModelContextProtocol.build.ps1 through Invoke-Build.

    Dependency sources, tried in this order with -DependencySource Auto:
      1. PSGallery  - Install-PSResource from the PowerShell Gallery.
      2. NuGet      - api.nuget.org for packages that are also published there (Pester, Invoke-Build).
      3. Offline    - a local repository made from the .nupkg files in tools/packages (see tools/README.md).

    requirements.psd1 lists every module the build needs, including the transitive dependencies of ModuleBuilder
    (Configuration, Metadata), so that all versions are pinned. Install-PSResource therefore runs with
    -SkipDependencyCheck: the package source's own dependency resolution is neither needed nor trusted.

.PARAMETER Task
    One or more Invoke-Build task names (default: Build), separated by spaces or commas so that both
    `./build.ps1 -Task Analyze, Test` and `pwsh -File build.ps1 -Task Analyze,Test` work. Use '?' to list the tasks.

.PARAMETER Bootstrap
    Install missing build dependencies before running the tasks.

.PARAMETER DependencySource
    Where to install missing dependencies from: Auto (default), PSGallery, NuGet or Offline.

.PARAMETER OfflinePackagePath
    Folder with .nupkg files for the Offline source (default: tools/packages).

.PARAMETER SemVer
    Version to build, e.g. 0.1.0-preview1. Defaults to ModuleVersion and Prerelease of src/ModelContextProtocol.psd1.

.PARAMETER CodeCoverage
    Collect JaCoCo code coverage while running the Test task.

.PARAMETER TestTag
    Only run Pester tests with one of these tags.

.PARAMETER ExcludeTestTag
    Skip Pester tests with one of these tags.

.PARAMETER ConformanceRequirements
    Requirement sets of the Conformance task (default: 2026-07-28 and 2025-11-25). Each set runs the server and
    the client leg; both server legs run against the same dual-era fixture.

.PARAMETER ConformanceLeg
    Restrict the Conformance task to the Server or the Client leg.

.PARAMETER ConformanceScenario
    Run a single conformance scenario instead of a requirement set.

.EXAMPLE
    ./build.ps1 -Bootstrap -Task CI

.EXAMPLE
    ./build.ps1 -Task Test -CodeCoverage
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Build script; console output is the purpose.')]
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]] $Task = @('Build'),

    [switch] $Bootstrap,

    [ValidateSet('Auto', 'PSGallery', 'NuGet', 'Offline')]
    [string] $DependencySource = 'Auto',

    [string] $OfflinePackagePath = (Join-Path $PSScriptRoot 'tools' 'packages'),

    [string] $SemVer,

    [switch] $CodeCoverage,

    [string[]] $TestTag,

    [string[]] $ExcludeTestTag,

    [string[]] $ConformanceRequirements = @('2026-07-28', '2025-11-25'),

    [ValidateSet('Server', 'Client')]
    [string[]] $ConformanceLeg,

    [string] $ConformanceScenario
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

# Under `pwsh -File`, "Analyze, Test" arrives as the literal tokens "Analyze," and "Test".
$Task = @($Task -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Task.Count -eq 0) { $Task = @('Build') }

$script:Requirements = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'requirements.psd1')
$script:NuGetFlatContainer = 'https://api.nuget.org/v3-flatcontainer'

function ConvertFrom-BuildVersionRange {
    <#
    .SYNOPSIS
        Parses the NuGet range subset used in requirements.psd1: '[min,max)', '[min,max]', '(min,max)', '[min]', 'min'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Range
    )

    $pattern = '^\s*(?<open>[\[\(])?\s*(?<min>[^,\]\)\s]*)\s*(?:(?<comma>,)\s*(?<max>[^,\]\)\s]*)\s*)?(?<close>[\]\)])?\s*$'
    if ($Range -notmatch $pattern) {
        throw "Unsupported version range '$Range'."
    }
    $min = $Matches['min']
    $max = $Matches['max']
    $exact = -not $Matches['comma'] -and $Matches['open'] -eq '[' -and $min

    [pscustomobject]@{
        Minimum          = if ($min) { [version] $min } else { $null }
        MinimumInclusive = $Matches['open'] -ne '('
        Maximum          = if ($max) { [version] $max } elseif ($exact) { [version] $min } else { $null }
        MaximumInclusive = $Matches['close'] -eq ']' -or $exact
    }
}

function Test-BuildVersionInRange {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [version] $Version,

        [Parameter(Mandatory)]
        [string] $Range
    )

    $r = ConvertFrom-BuildVersionRange -Range $Range
    if ($r.Minimum) {
        if ($r.MinimumInclusive) {
            if ($Version -lt $r.Minimum) { return $false }
        } elseif ($Version -le $r.Minimum) {
            return $false
        }
    }
    if ($r.Maximum) {
        if ($r.MaximumInclusive) {
            if ($Version -gt $r.Maximum) { return $false }
        } elseif ($Version -ge $r.Maximum) {
            return $false
        }
    }
    $true
}

function Get-BuildInstalledDependency {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSModuleInfo])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $Range
    )

    Get-Module -ListAvailable -Name $Name |
        Where-Object { Test-BuildVersionInRange -Version $_.Version -Range $Range } |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
}

function Get-BuildUserModulePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($IsWindows) {
        Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell' 'Modules'
    } else {
        Join-Path $HOME '.local' 'share' 'powershell' 'Modules'
    }
}

function Install-BuildDependencyFromGallery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $Range
    )

    # Transitive dependencies are declared in requirements.psd1 (see the header), hence -SkipDependencyCheck.
    Install-PSResource -Name $Name -Version $Range -Repository PSGallery -TrustRepository -Scope CurrentUser -SkipDependencyCheck -Quiet -ErrorAction Stop
}

function Install-BuildDependencyFromNuGet {
    <#
    .SYNOPSIS
        Installs a package from api.nuget.org. The NuGet packages of Pester and Invoke-Build use the Chocolatey
        layout (module files below tools/), so the module folder is located by its manifest and copied to the
        CurrentUser module path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $NuGetId,

        [Parameter(Mandatory)]
        [string] $Range
    )

    $id = $NuGetId.ToLowerInvariant()
    $index = Invoke-RestMethod -Uri "$script:NuGetFlatContainer/$id/index.json" -ErrorAction Stop
    $candidates = @($index.versions | Where-Object {
            $_ -match '^\d+(\.\d+){1,3}$' -and (Test-BuildVersionInRange -Version ([version] $_) -Range $Range)
        })
    if (-not $candidates) {
        throw "No stable version of NuGet package '$NuGetId' satisfies '$Range'."
    }
    $version = @($candidates | Sort-Object -Property { [version] $_ } -Descending)[0]

    $staging = Join-Path ([IO.Path]::GetTempPath()) "mcp-build-dependency-$id-$version"
    if (Test-Path $staging) { Remove-Item -Path $staging -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $staging
    $archive = Join-Path $staging "$id.$version.zip"
    Invoke-WebRequest -Uri "$script:NuGetFlatContainer/$id/$version/$id.$version.nupkg" -OutFile $archive -ErrorAction Stop
    $extracted = Join-Path $staging 'content'
    Expand-Archive -Path $archive -DestinationPath $extracted -Force

    $manifest = Get-ChildItem -Path $extracted -Recurse -Filter "$Name.psd1" |
        Sort-Object -Property { $_.FullName.Length } |
        Select-Object -First 1
    if (-not $manifest) {
        throw "NuGet package '$NuGetId' $version does not contain a module manifest '$Name.psd1'."
    }
    $moduleVersion = (Import-PowerShellDataFile -Path $manifest.FullName).ModuleVersion
    $destination = Join-Path (Get-BuildUserModulePath) $Name $moduleVersion
    if (Test-Path $destination) { Remove-Item -Path $destination -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $destination -Force
    Copy-Item -Path (Join-Path $manifest.DirectoryName '*') -Destination $destination -Recurse -Force
    foreach ($leftover in '_rels', 'package', '[Content_Types].xml', '.signature.p7s', 'VERIFICATION.txt', "$id.nuspec", 'chocolateyInstall.ps1') {
        Remove-Item -LiteralPath (Join-Path $destination $leftover) -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
}

function Install-BuildDependencyFromOffline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $Range,

        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -Path $Path) -or -not (Get-ChildItem -Path $Path -Filter '*.nupkg')) {
        throw "Offline package folder '$Path' does not exist or contains no .nupkg files."
    }
    $repositoryName = 'McpOfflinePackages'
    $uri = (Resolve-Path -Path $Path).Path
    $existing = Get-PSResourceRepository -Name $repositoryName -ErrorAction SilentlyContinue
    if ($existing -and $existing.Uri.LocalPath -ne $uri) {
        Unregister-PSResourceRepository -Name $repositoryName
        $existing = $null
    }
    if (-not $existing) {
        Register-PSResourceRepository -Name $repositoryName -Uri $uri -Trusted
    }
    Install-PSResource -Name $Name -Version $Range -Repository $repositoryName -TrustRepository -Scope CurrentUser -SkipDependencyCheck -Quiet -ErrorAction Stop
}

function Install-BuildDependency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [hashtable] $Requirement,

        [Parameter(Mandatory)]
        [string] $Source,

        [Parameter(Mandatory)]
        [string] $OfflinePath
    )

    $range = $Requirement.Version
    $sources = switch ($Source) {
        'Auto' { @('PSGallery', 'NuGet', 'Offline') }
        default { @($Source) }
    }
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($source in $sources) {
        try {
            switch ($source) {
                'PSGallery' {
                    Install-BuildDependencyFromGallery -Name $Name -Range $range
                }
                'NuGet' {
                    if (-not $Requirement.ContainsKey('NuGetId')) {
                        throw 'not published on NuGet.org'
                    }
                    Install-BuildDependencyFromNuGet -Name $Name -NuGetId $Requirement.NuGetId -Range $range
                }
                'Offline' {
                    Install-BuildDependencyFromOffline -Name $Name -Range $range -Path $OfflinePath
                }
            }
            if (Get-BuildInstalledDependency -Name $Name -Range $range) {
                Write-Host "  installed $Name from $source" -ForegroundColor Green
                return $true
            }
            $errors.Add("${source}: installation reported success but no module in range '$range' was found")
        } catch {
            $errors.Add("${source}: $($_.Exception.Message)")
        }
    }
    $message = "Could not install '$Name' $range.`n  " + ($errors -join "`n  ")
    if ($Requirement.ContainsKey('Optional') -and $Requirement.Optional) {
        Write-Warning "$message`n  '$Name' is optional; tasks that need it will be skipped."
        return $false
    }
    throw $message
}

Write-Host 'Build dependencies:' -ForegroundColor Cyan
$missing = [System.Collections.Generic.List[string]]::new()
foreach ($entry in ($script:Requirements.Modules.GetEnumerator() | Sort-Object -Property Key)) {
    $name = $entry.Key
    $requirement = $entry.Value
    $installed = Get-BuildInstalledDependency -Name $name -Range $requirement.Version
    if ($installed) {
        Write-Host ("  {0,-32} {1,-14} ok ({2})" -f $name, $requirement.Version, $installed.Version)
        continue
    }
    if ($Bootstrap) {
        Write-Host ("  {0,-32} {1,-14} installing..." -f $name, $requirement.Version)
        $null = Install-BuildDependency -Name $name -Requirement $requirement -Source $DependencySource -OfflinePath $OfflinePackagePath
    } elseif ($requirement.ContainsKey('Optional') -and $requirement.Optional) {
        Write-Host ("  {0,-32} {1,-14} missing (optional)" -f $name, $requirement.Version) -ForegroundColor Yellow
    } else {
        Write-Host ("  {0,-32} {1,-14} missing" -f $name, $requirement.Version) -ForegroundColor Red
        $missing.Add($name)
    }
}
if ($missing.Count -gt 0) {
    throw "Missing build dependencies: $($missing -join ', '). Run ./build.ps1 -Bootstrap (see DEPENDENCY_POLICY.md for the sources)."
}

Import-Module -Name InvokeBuild -MinimumVersion 5.12.0 -ErrorAction Stop

$invokeBuildParameters = @{
    Task = $Task
    File = Join-Path $PSScriptRoot 'ModelContextProtocol.build.ps1'
}
if ($SemVer) { $invokeBuildParameters['SemVer'] = $SemVer }
if ($CodeCoverage) { $invokeBuildParameters['CodeCoverage'] = $true }
if ($TestTag) { $invokeBuildParameters['TestTag'] = $TestTag }
if ($ExcludeTestTag) { $invokeBuildParameters['ExcludeTestTag'] = $ExcludeTestTag }
if ($ConformanceRequirements) { $invokeBuildParameters['ConformanceRequirements'] = $ConformanceRequirements }
if ($ConformanceLeg) { $invokeBuildParameters['ConformanceLeg'] = $ConformanceLeg }
if ($ConformanceScenario) { $invokeBuildParameters['ConformanceScenario'] = $ConformanceScenario }

Invoke-Build @invokeBuildParameters
