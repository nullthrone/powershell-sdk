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
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'output'),
    [string[]] $ConformanceRequirements = @('2026-07-28', '2025-11-25'),
    [string[]] $ConformanceLeg,
    [string] $ConformanceScenario
)

Set-StrictMode -Version Latest

$script:ModuleName = 'ModelContextProtocol'
$script:SourcePath = Join-Path $PSScriptRoot 'src'
$script:SourceManifest = Join-Path $script:SourcePath "$script:ModuleName.psd1"
$script:BuildSettings = Join-Path $script:SourcePath 'build.psd1'
$script:TestsPath = Join-Path $PSScriptRoot 'tests'
$script:AnalyzerSettings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
$script:CustomRulePath = Join-Path $PSScriptRoot 'tools' 'ScriptAnalyzerRules' 'McpAnalyzerRules.psm1'
$script:AnalyzerWorker = Join-Path $PSScriptRoot 'tools' 'Invoke-ScriptAnalyzerWorker.ps1'
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
        Runs PSScriptAnalyzer over one path with the repository settings and custom rules; returns the findings.
    .DESCRIPTION
        PSScriptAnalyzer 1.25 runs its rules in parallel tasks that are not entirely thread-safe: now and then a
        rule fails on a file with a NullReferenceException or, after a lost command lookup, with "The term
        'Get-Command' is not recognized", the analyzer keeps that state until the process exits, and once in a
        while an analysis hangs. Every analysis therefore runs in a fresh pwsh process with a timeout
        (tools/Invoke-ScriptAnalyzerWorker.ps1): a failed or timed-out process is retried, and files on which a
        rule failed are re-analysed one by one in further fresh processes, so that a failure never hides a
        finding. Retries are reported as build warnings so that they stay visible in the logs.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $maximumAttempts = 3
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        $result = Invoke-BuildScriptAnalyzerWorker -Path $Path
        if ($null -eq $result) {
            if ($attempt -lt $maximumAttempts) { Start-Sleep -Seconds 2; continue }
            throw "PSScriptAnalyzer could not analyse '$Path' in $maximumAttempts attempts."
        }
        $findings = @($result.Findings)
        $affected = @($result.Failures | Select-Object -ExpandProperty File -Unique)
        if ($affected.Count -eq 0) { return $findings }
        $detail = ($result.Failures | Select-Object -Property File, Message -Unique | Select-Object -First 3 | ForEach-Object { "{0}: {1}" -f (Resolve-Path -Path $_.File -Relative -ErrorAction SilentlyContinue), $_.Message }) -join '; '
        if ($affected.Count -gt 3 -and $attempt -lt $maximumAttempts) {
            # A lost command lookup poisons the process: every file analysed after it fails too. Re-running the
            # whole path in a fresh process is then cheaper than re-analysing every affected file on its own.
            Write-Warning ("PSScriptAnalyzer rules failed on {0} file(s) under '{1}' ({2}); re-running the analysis in a fresh process (attempt {3} of {4})." -f $affected.Count, $Path, $detail, ($attempt + 1), $maximumAttempts)
            Start-Sleep -Seconds 2
            continue
        }
        Write-Warning ("PSScriptAnalyzer rules failed on {0} file(s) under '{1}' ({2}); re-analysing those files in fresh processes." -f $affected.Count, $Path, $detail)
        $findings = @($findings | Where-Object { $_.ScriptPath -notin $affected })
        foreach ($file in $affected) {
            $findings += Invoke-BuildScriptFileAnalysis -Path $file
        }
        return $findings
    }
}

function Invoke-BuildScriptFileAnalysis {
    <#
    .SYNOPSIS
        Analyses one file in fresh processes until no rule fails on it (at most three attempts).
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $maximumAttempts = 3
    $lastMessage = ''
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        $result = Invoke-BuildScriptAnalyzerWorker -Path $Path
        if ($null -ne $result -and @($result.Failures).Count -eq 0) { return @($result.Findings) }
        $lastMessage = if ($null -eq $result) { 'the process failed or timed out' } else { @($result.Failures)[0].Message }
        if ($attempt -lt $maximumAttempts) { Start-Sleep -Seconds 2 }
    }
    throw "PSScriptAnalyzer failed on '$Path' in $maximumAttempts attempts: $lastMessage"
}

function Invoke-BuildScriptAnalyzerWorker {
    <#
    .SYNOPSIS
        Runs tools/Invoke-ScriptAnalyzerWorker.ps1 in a fresh pwsh process with a timeout; returns its result or $null.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [int] $TimeoutSeconds = 300
    )

    $resultFile = Join-Path ([System.IO.Path]::GetTempPath()) ('mcp-analyze-' + [guid]::NewGuid().ToString('n') + '.xml')
    $process = $null
    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Process -Id $PID).Path
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:AnalyzerWorker, '-Path', $Path, '-Settings', $script:AnalyzerSettings, '-CustomRulePath', $script:CustomRulePath, '-ResultPath', $resultFile)) {
            $startInfo.ArgumentList.Add($argument)
        }
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            Write-Warning ("PSScriptAnalyzer did not finish '{0}' within {1} s; the process was stopped and the analysis is retried." -f $Path, $TimeoutSeconds)
            return $null
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or -not (Test-Path -Path $resultFile)) {
            $output = (@($stdout.Result, $stderr.Result) -join "`n").Trim()
            Write-Warning ("PSScriptAnalyzer process failed on '{0}' (exit code {1}): {2}" -f $Path, $process.ExitCode, $output.Split("`n")[0])
            return $null
        }
        Import-Clixml -Path $resultFile
    } finally {
        if ($null -ne $process) { $process.Dispose() }
        Remove-Item -Path $resultFile -Force -ErrorAction SilentlyContinue
    }
}

# Synopsis: Format the PowerShell sources in place with Invoke-Formatter and the repository settings.
task Format {
    Import-Module -Name PSScriptAnalyzer -MinimumVersion 1.25.0 -ErrorAction Stop
    $roots = @('src', 'tests', 'tools', 'examples', 'build.ps1', 'ModelContextProtocol.build.ps1') | ForEach-Object { Join-Path $PSScriptRoot $_ }
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
    $paths = @('src', 'tests', 'tools', 'examples', 'build.ps1', 'ModelContextProtocol.build.ps1') | ForEach-Object { Join-Path $PSScriptRoot $_ }
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

function Start-ConformanceServer {
    <#
    .SYNOPSIS
        Starts tests/Conformance/everything-server.ps1 on a free loopback port and waits until it accepts connections.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Build helper; starts a fixture process for the conformance run.')]
    param(
        [Parameter(Mandatory)]
        [string] $LogPath
    )

    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = $probe.LocalEndpoint.Port
    $probe.Stop()
    $pwsh = (Get-Process -Id $PID).Path
    $script = Join-Path $script:TestsPath 'Conformance' 'everything-server.ps1'
    # The dual-era fixture serves both requirement sets: 2026-07-28 statelessly, 2025-11-25 in legacy sessions.
    $process = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script, '-Era', 'Dual', '-Port', $port) -RedirectStandardError $LogPath -PassThru -NoNewWindow
    $deadline = [datetime]::UtcNow.AddSeconds(60)
    while ([datetime]::UtcNow -lt $deadline) {
        if ($process.HasExited) { throw "The conformance server exited with code $($process.ExitCode); see $LogPath." }
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $client.Connect([System.Net.IPAddress]::Loopback, $port)
            if ($client.Connected) { break }
        } catch {
            Start-Sleep -Milliseconds 250
        } finally {
            $client.Dispose()
        }
    }
    if ([datetime]::UtcNow -ge $deadline) { throw "The conformance server did not start listening on port $port within 60 seconds; see $LogPath." }
    @{ Process = $process; Url = "http://127.0.0.1:$port/mcp"; Port = $port }
}

function Stop-ConformanceServer {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Build helper; stops the fixture process of the conformance run.')]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Handle
    )

    $process = $Handle.Process
    try {
        if (-not $process.HasExited) {
            $process.Kill($true)
            $null = $process.WaitForExit(10000)
        }
    } finally {
        $process.Dispose()
    }
}

# Synopsis: Run the MCP conformance suite (server and client legs) for the requirement sets given with -ConformanceRequirements.
task Conformance Build, {
    $npx = Get-Command -Name npx -ErrorAction SilentlyContinue
    assert ($null -ne $npx) 'npx (Node.js 20 or later) is required for the conformance suite.'
    $requirements = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'requirements.psd1')
    $package = '@modelcontextprotocol/conformance@' + $requirements.Npm['@modelcontextprotocol/conformance']
    $baseline = Join-Path $PSScriptRoot 'conformance-baseline.yml'
    $resultRoot = Join-Path $OutputDirectory 'conformance'
    $null = New-Item -Path $resultRoot -ItemType Directory -Force
    $env:MCP_MODULE_MANIFEST = Get-BuiltModuleManifest
    $pwsh = (Get-Process -Id $PID).Path
    $clientScript = Join-Path $script:TestsPath 'Conformance' 'everything-client.ps1'
    $legs = if ($ConformanceLeg) { @($ConformanceLeg) } else { @('Server', 'Client') }
    $selection = if ($ConformanceScenario) { @('--scenario', $ConformanceScenario) } else { $null }
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($revision in $ConformanceRequirements) {
        $scope = if ($selection) { $selection } else { @('--requirements', $revision) }
        if ('Server' -in $legs) {
            $log = Join-Path $resultRoot "server-$revision.log"
            $handle = Start-ConformanceServer -LogPath $log
            try {
                Write-Build Cyan "Conformance: server leg, requirement set $revision, fixture at $($handle.Url) (log: $log)"
                & $npx.Source --yes $package server --url $handle.Url @scope --expected-failures $baseline --output-dir (Join-Path $resultRoot "server-$revision")
                if ($LASTEXITCODE -ne 0) { $failures.Add("server leg of $revision (exit code $LASTEXITCODE)") }
            } finally {
                Stop-ConformanceServer -Handle $handle
            }
        }
        if ('Client' -in $legs) {
            Write-Build Cyan "Conformance: client leg, requirement set $revision"
            & $npx.Source --yes $package client --command "$pwsh -NoLogo -NoProfile -NonInteractive -File $clientScript" @scope --expected-failures $baseline --output-dir (Join-Path $resultRoot "client-$revision")
            if ($LASTEXITCODE -ne 0) { $failures.Add("client leg of $revision (exit code $LASTEXITCODE)") }
        }
    }
    assert ($failures.Count -eq 0) "Conformance failed: $($failures -join '; '). Results are under $resultRoot."
    Write-Build Green "Conformance: all legs passed against the baseline ($baseline)."
}

# Synopsis: What CI runs: Analyze, Test, Package, PublishLocal.
task CI Analyze, Test, Package, PublishLocal

task . Build
