#Requires -Version 7.4
<#
.SYNOPSIS
    Invoke-Build tasks for the ModelContextProtocol module. Run them through ./build.ps1.

.DESCRIPTION
    Tasks: Clean, Build, Analyze, Test, Coverage, Help, Package, PublishLocal, Publish, Conformance, CI.
    The default task is Build. Parameters are supplied by build.ps1.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are consumed by the Invoke-Build tasks defined below.')]
param(
    [string] $SemVer,
    [switch] $CodeCoverage,
    [string[]] $TestTag,
    [string[]] $ExcludeTestTag,
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'output')
)

Set-StrictMode -Version Latest

$script:ModuleName = 'ModelContextProtocol'
$script:SourcePath = Join-Path $PSScriptRoot 'src'
$script:SourceManifest = Join-Path $script:SourcePath "$script:ModuleName.psd1"
$script:BuildSettings = Join-Path $script:SourcePath 'build.psd1'
$script:TestsPath = Join-Path $PSScriptRoot 'tests'
$script:AnalyzerSettings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
$script:CustomRulePath = Join-Path $PSScriptRoot 'tools' 'ScriptAnalyzerRules' 'McpAnalyzerRules.psm1'
$script:ModuleOutputRoot = Join-Path $OutputDirectory $script:ModuleName
$script:PackageDirectory = Join-Path $OutputDirectory 'packages'

function Get-BuildSemVer {
    if ($SemVer) { return $SemVer }
    $manifest = Import-PowerShellDataFile -Path $script:SourceManifest
    $prerelease = $manifest.PrivateData.PSData.Prerelease
    if ($prerelease) { "$($manifest.ModuleVersion)-$prerelease" } else { [string] $manifest.ModuleVersion }
}

function Get-BuildModuleVersion {
    [version] (Get-BuildSemVer).Split('-', 2)[0]
}

function Get-BuiltModuleDirectory {
    Join-Path $script:ModuleOutputRoot (Get-BuildModuleVersion).ToString()
}

function Get-BuiltModuleManifest {
    Join-Path (Get-BuiltModuleDirectory) "$script:ModuleName.psd1"
}

function Get-BuildPlatformTag {
    $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    '{0}-pwsh{1}' -f $os, $PSVersionTable.PSVersion
}

function Invoke-BuildScriptAnalysis {
    <#
    .SYNOPSIS
        Runs PSScriptAnalyzer over one path with the repository settings and custom rules.
    .DESCRIPTION
        PSScriptAnalyzer 1.25 occasionally fails while initialising its internal command-info cache and the runspace
        that runs custom rules: either with "The term 'Get-Command' is not recognized" or with a
        NullReferenceException ("Object reference not set to an instance of an object"). Neither failure is
        reproducible on demand, and once it has happened the analyzer's process-wide cache can stay broken, so
        the first attempt runs in-process and up to two further attempts run the same analysis in fresh pwsh
        processes. A retry is reported as a build warning so that it stays visible in the logs.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $maximumAttempts = 3
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        try {
            if ($attempt -eq 1) {
                return Invoke-ScriptAnalyzer -Path $Path -Recurse -Settings $script:AnalyzerSettings -CustomRulePath $script:CustomRulePath -IncludeDefaultRules -ErrorAction Stop
            }
            return Invoke-BuildScriptAnalysisInChildProcess -Path $Path
        } catch {
            $message = $_.Exception.Message
            $transient = $_.Exception -is [System.NullReferenceException]
            foreach ($pattern in "*'Get-Command' is not recognized*", '*Object reference not set to an instance of an object*') {
                if ($message -like $pattern) { $transient = $true }
            }
            if ($attempt -lt $maximumAttempts -and $transient) {
                Write-Warning ("PSScriptAnalyzer failed transiently on '{0}' (attempt {1} of {2}): {3} Retrying in a fresh process." -f $Path, $attempt, $maximumAttempts, $message.Split("`n")[0].Trim())
                Start-Sleep -Seconds 2
                continue
            }
            throw
        }
    }
}

function Invoke-BuildScriptAnalysisInChildProcess {
    <#
    .SYNOPSIS
        Runs the analysis of one path in a fresh pwsh process and returns the findings (deserialised).
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $resultFile = Join-Path ([System.IO.Path]::GetTempPath()) ('mcp-analyze-' + [guid]::NewGuid().ToString('n') + '.xml')
    $command = @(
        'Import-Module -Name PSScriptAnalyzer -MinimumVersion 1.25.0 -ErrorAction Stop'
        "`$findings = @(Invoke-ScriptAnalyzer -Path '$Path' -Recurse -Settings '$($script:AnalyzerSettings)' -CustomRulePath '$($script:CustomRulePath)' -IncludeDefaultRules -ErrorAction Stop)"
        "`$findings | Select-Object -Property Severity, RuleName, ScriptPath, Line, Message | Export-Clixml -Path '$resultFile' -Depth 3"
        'exit 0'
    ) -join '; '
    try {
        $output = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -Command $command 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -Path $resultFile)) {
            throw (($output | ForEach-Object { [string] $_ }) -join "`n")
        }
        @(Import-Clixml -Path $resultFile)
    } finally {
        Remove-Item -Path $resultFile -Force -ErrorAction SilentlyContinue
    }
}

# Synopsis: Format the PowerShell sources in place with Invoke-Formatter and the repository settings.
task Format {
    Import-Module -Name PSScriptAnalyzer -MinimumVersion 1.25.0 -ErrorAction Stop
    $roots = @('src', 'tests', 'tools', 'build.ps1', 'ModelContextProtocol.build.ps1') | ForEach-Object { Join-Path $PSScriptRoot $_ }
    $files = foreach ($root in $roots) {
        if (Test-Path -Path $root -PathType Container) {
            Get-ChildItem -Path $root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1'
        } else {
            Get-Item -Path $root
        }
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $changed = 0
    foreach ($file in $files) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        $formatted = (Invoke-Formatter -ScriptDefinition $text -Settings $script:AnalyzerSettings).TrimEnd() + "`n"
        if ($formatted -ne $text) {
            [System.IO.File]::WriteAllText($file.FullName, $formatted, $utf8)
            Write-Build Yellow "Format: $(Resolve-Path -Path $file.FullName -Relative)"
            $changed++
        }
    }
    Write-Build Green "Format: $changed file(s) changed."
}

# Synopsis: Remove the output directory.
task Clean {
    remove $OutputDirectory
}

# Synopsis: Assemble src/ into output/ModelContextProtocol/<version>/ with ModuleBuilder.
task Build {
    Import-Module -Name ModuleBuilder -MinimumVersion 3.1.0 -ErrorAction Stop
    $semver = Get-BuildSemVer
    Write-Build Cyan "Building $script:ModuleName $semver"

    $built = Build-Module -SourcePath $script:BuildSettings -OutputDirectory $OutputDirectory -SemVer $semver -Target CleanBuild -Passthru
    $moduleDirectory = Get-BuiltModuleDirectory
    equals $built.ModuleBase (Convert-Path $moduleDirectory)

    Copy-Item -Path (Join-Path $PSScriptRoot 'LICENSE') -Destination $moduleDirectory -Force
    $manifest = Test-ModuleManifest -Path (Get-BuiltModuleManifest) -ErrorAction Stop
    Write-Build Green ("Built {0} {1}{2} -> {3}" -f $manifest.Name, $manifest.Version, ($(if ($manifest.PrivateData.PSData.Prerelease) { '-' + $manifest.PrivateData.PSData.Prerelease })), $moduleDirectory)
}

# Synopsis: Run PSScriptAnalyzer (default rules, formatting rules and the repository's custom rules).
task Analyze {
    Import-Module -Name PSScriptAnalyzer -MinimumVersion 1.25.0 -ErrorAction Stop
    # Warm-up on a trivial script: initialises the analyzer's command-info cache and the custom-rule runspace in this
    # session, where the transient failures described in Invoke-BuildScriptAnalysis originate. Its outcome is ignored.
    try {
        $null = Invoke-ScriptAnalyzer -ScriptDefinition 'param() Get-Date' -Settings $script:AnalyzerSettings -CustomRulePath $script:CustomRulePath -IncludeDefaultRules -ErrorAction Stop
    } catch {
        Write-Warning ("PSScriptAnalyzer warm-up failed: {0}" -f $_.Exception.Message.Split("`n")[0].Trim())
    }
    $paths = @('src', 'tests', 'tools', 'build.ps1', 'ModelContextProtocol.build.ps1') | ForEach-Object { Join-Path $PSScriptRoot $_ }
    $findings = @(foreach ($path in $paths) { Invoke-BuildScriptAnalysis -Path $path })
    if ($findings.Count -gt 0) {
        $findings |
            Sort-Object -Property Severity, ScriptPath, Line |
            Format-Table -Property Severity, RuleName, @{ Name = 'Location'; Expression = { '{0}:{1}' -f (Resolve-Path -Path $_.ScriptPath -Relative), $_.Line } }, Message -AutoSize -Wrap |
            Out-String -Width 200 |
            ForEach-Object { Write-Build Yellow $_ }
    }
    assert ($findings.Count -eq 0) "PSScriptAnalyzer reported $($findings.Count) finding(s)."
    Write-Build Green 'PSScriptAnalyzer: no findings.'
}

# Synopsis: Build, then run the Pester test suites (Unit, Integration, Spec, Compat) against the built module.
task Test Build, {
    Import-Module -Name Pester -MinimumVersion 6.2.0 -ErrorAction Stop
    $manifest = Get-BuiltModuleManifest
    $env:MCP_MODULE_MANIFEST = $manifest
    $resultsDirectory = Join-Path $OutputDirectory 'test-results'
    $null = New-Item -ItemType Directory -Path $resultsDirectory -Force

    $configuration = New-PesterConfiguration
    $configuration.Run.Path = @('Unit', 'Integration', 'Spec', 'Compat') | ForEach-Object { Join-Path $script:TestsPath $_ }
    $configuration.Run.PassThru = $true
    $configuration.Run.Exit = $false
    $configuration.Output.Verbosity = if ($env:CI) { 'Detailed' } else { 'Normal' }
    $configuration.Output.CIFormat = 'Auto'
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'NUnitXml'
    $configuration.TestResult.OutputPath = Join-Path $resultsDirectory ('pester-{0}.xml' -f (Get-BuildPlatformTag))
    if ($TestTag) { $configuration.Filter.Tag = $TestTag }
    if ($ExcludeTestTag) { $configuration.Filter.ExcludeTag = $ExcludeTestTag }
    if ($CodeCoverage) {
        $coverageDirectory = Join-Path $OutputDirectory 'coverage'
        $null = New-Item -ItemType Directory -Path $coverageDirectory -Force
        $configuration.CodeCoverage.Enabled = $true
        $configuration.CodeCoverage.Path = @(Join-Path (Get-BuiltModuleDirectory) "$script:ModuleName.psm1")
        $configuration.CodeCoverage.OutputFormat = 'JaCoCo'
        $configuration.CodeCoverage.OutputPath = Join-Path $coverageDirectory ('jacoco-{0}.xml' -f (Get-BuildPlatformTag))
    }

    $result = Invoke-Pester -Configuration $configuration
    assert ($null -ne $result) 'Pester returned no result object.'
    Write-Build Cyan ("Pester: {0} passed, {1} failed, {2} skipped, {3} total ({4})" -f $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.TotalCount, $result.Result)
    assert ($result.FailedCount -eq 0 -and $result.Result -eq 'Passed') "Pester reported $($result.FailedCount) failed test(s) (result: $($result.Result))."
}

# Synopsis: Run the tests with JaCoCo code coverage (output/coverage/).
task Coverage {
    $script:CodeCoverage = $true
}, Test

# Synopsis: Generate command help with Microsoft.PowerShell.PlatyPS (markdown under docs/help, MAML in the built module).
task Help Build, {
    $manifest = Test-ModuleManifest -Path (Get-BuiltModuleManifest) -ErrorAction Stop
    $exported = @($manifest.ExportedFunctions.Keys)
    if ($exported.Count -eq 0) {
        Write-Build Yellow 'Help: the module exports no commands yet; nothing to generate.'
        return
    }
    $platyPS = Get-Module -ListAvailable -Name Microsoft.PowerShell.PlatyPS | Sort-Object -Property Version -Descending | Select-Object -First 1
    if (-not $platyPS) {
        Write-Build Yellow 'Help: Microsoft.PowerShell.PlatyPS is not installed; skipping (run ./build.ps1 -Bootstrap).'
        return
    }
    Import-Module -Name Microsoft.PowerShell.PlatyPS -MinimumVersion 1.0.0 -ErrorAction Stop
    $module = Import-Module -Name (Get-BuiltModuleManifest) -Force -PassThru
    $markdownDirectory = Join-Path $PSScriptRoot 'docs' 'help'
    $null = New-Item -ItemType Directory -Path $markdownDirectory -Force
    if (Get-ChildItem -Path $markdownDirectory -Filter '*.md' -ErrorAction SilentlyContinue) {
        Update-MarkdownCommandHelp -Path $markdownDirectory
    }
    New-MarkdownCommandHelp -ModuleInfo $module -OutputFolder $markdownDirectory -Force
    $help = Import-MarkdownCommandHelp -Path (Get-ChildItem -Path $markdownDirectory -Filter '*.md').FullName
    $help | Export-MamlCommandHelp -OutputFolder (Join-Path (Get-BuiltModuleDirectory) 'en-US') -Force
    Write-Build Green "Help: generated $($exported.Count) command topic(s)."
}

# Synopsis: Build, then create the NuGet package under output/packages/.
task Package Build, {
    Import-Module -Name Microsoft.PowerShell.PSResourceGet -ErrorAction Stop
    $moduleDirectory = Get-BuiltModuleDirectory
    $null = New-Item -ItemType Directory -Path $script:PackageDirectory -Force
    Get-ChildItem -Path $script:PackageDirectory -Filter "$script:ModuleName.*.nupkg" -ErrorAction SilentlyContinue | Remove-Item -Force

    if (Get-Command -Name Compress-PSResource -ErrorAction SilentlyContinue) {
        Compress-PSResource -Path $moduleDirectory -DestinationPath $script:PackageDirectory -ErrorAction Stop
    } else {
        # PSResourceGet 1.0.x (early 7.4 releases) has no Compress-PSResource; publishing to a local repository yields the nupkg.
        $repositoryName = 'McpPackageStaging'
        if (Get-PSResourceRepository -Name $repositoryName -ErrorAction SilentlyContinue) { Unregister-PSResourceRepository -Name $repositoryName }
        Register-PSResourceRepository -Name $repositoryName -Uri $script:PackageDirectory -Trusted
        try {
            Publish-PSResource -Path $moduleDirectory -Repository $repositoryName -ErrorAction Stop
        } finally {
            Unregister-PSResourceRepository -Name $repositoryName
        }
    }
    $package = Get-ChildItem -Path $script:PackageDirectory -Filter "$script:ModuleName.*.nupkg" | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    assert ($null -ne $package) 'No package was produced.'
    Write-Build Green "Package: $($package.FullName) ($([math]::Round($package.Length / 1KB)) KB)"
}

# Synopsis: Publish the built module to a local file-share repository and install it from there (release dry run).
task PublishLocal Build, {
    Import-Module -Name Microsoft.PowerShell.PSResourceGet -ErrorAction Stop
    $moduleDirectory = Get-BuiltModuleDirectory
    $repositoryName = 'McpLocalRepository'
    $repositoryPath = Join-Path $OutputDirectory 'local-repository'
    $installPath = Join-Path $OutputDirectory 'local-install'
    foreach ($path in $repositoryPath, $installPath) {
        if (Test-Path -Path $path) { Remove-Item -Path $path -Recurse -Force }
        $null = New-Item -ItemType Directory -Path $path -Force
    }
    if (Get-PSResourceRepository -Name $repositoryName -ErrorAction SilentlyContinue) { Unregister-PSResourceRepository -Name $repositoryName }
    Register-PSResourceRepository -Name $repositoryName -Uri $repositoryPath -Trusted
    try {
        Publish-PSResource -Path $moduleDirectory -Repository $repositoryName -ErrorAction Stop
        $found = Find-PSResource -Name $script:ModuleName -Repository $repositoryName -Prerelease -ErrorAction Stop
        assert ($null -ne $found) "Find-PSResource did not find $script:ModuleName in the local repository."
        Write-Build Cyan ("PublishLocal: found {0} {1}{2} in {3}" -f $found.Name, $found.Version, ($(if ($found.Prerelease) { '-' + $found.Prerelease })), $repositoryPath)
        Save-PSResource -Name $script:ModuleName -Repository $repositoryName -Path $installPath -Prerelease -TrustRepository -ErrorAction Stop
        $savedManifest = Get-ChildItem -Path $installPath -Recurse -Filter "$script:ModuleName.psd1" | Select-Object -First 1
        assert ($null -ne $savedManifest) 'Save-PSResource did not produce a module manifest.'
        $pwsh = (Get-Process -Id $PID).Path
        exec { & $pwsh -NoLogo -NoProfile -NonInteractive -Command "Import-Module '$($savedManifest.FullName)' -ErrorAction Stop; exit 0" }
        Write-Build Green "PublishLocal: package installs and imports from the local repository ($($savedManifest.DirectoryName))."
    } finally {
        Unregister-PSResourceRepository -Name $repositoryName -ErrorAction SilentlyContinue
    }
}

# Synopsis: Publish the built module to the PowerShell Gallery (requires PSGALLERY_API_KEY).
task Publish Build, {
    Import-Module -Name Microsoft.PowerShell.PSResourceGet -ErrorAction Stop
    $apiKey = $env:PSGALLERY_API_KEY
    assert (-not [string]::IsNullOrWhiteSpace($apiKey)) 'PSGALLERY_API_KEY is not set. Use the PublishLocal task for a dry run.'
    Publish-PSResource -Path (Get-BuiltModuleDirectory) -Repository PSGallery -ApiKey $apiKey -ErrorAction Stop
    Write-Build Green "Published $script:ModuleName $(Get-BuildSemVer) to the PowerShell Gallery."
}

# Synopsis: Run the MCP conformance suite (available from milestone M2).
task Conformance {
    throw 'The conformance harness (tests/Conformance) is introduced in milestone M2; see ROADMAP.md and docs/conformance.md.'
}

# Synopsis: What CI runs: Analyze, Test, Package, PublishLocal.
task CI Analyze, Test, Package, PublishLocal

task . Build
