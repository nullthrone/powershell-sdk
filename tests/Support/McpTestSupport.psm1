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

function Invoke-McpInModule {
    <#
    .SYNOPSIS
        Runs a script block in the scope of the imported ModelContextProtocol module (access to private functions).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [scriptblock] $ScriptBlock,

        # Named arguments for the script block's param() block; use this for arrays and other enumerables,
        # which positional binding would unroll.
        [hashtable] $Parameters = @{},

        [Parameter(Position = 1, ValueFromRemainingArguments)]
        [object[]] $ArgumentList = @()
    )

    $module = Get-Module -Name ModelContextProtocol
    if (-not $module) { throw 'The ModelContextProtocol module is not imported.' }
    & $module $ScriptBlock @Parameters @ArgumentList
}

function Test-McpSpecShape {
    <#
    .SYNOPSIS
        Validates a wire object against a definition of the vendored specification schema; returns IsValid and Errors.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Definition,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Instance,

        [string] $Revision = '2026-07-28'
    )

    $definitions = Get-McpSpecDefinition -Revision $Revision
    # The references inside the definitions point at $defs (2020-12 schemas) or definitions (draft-07 schemas).
    $container = if ((Get-McpSpecSchema -Revision $Revision).ContainsKey('$defs')) { '$defs' } else { 'definitions' }
    $schema = @{ '$ref' = "#/$container/$Definition"; $container = $definitions }
    Invoke-McpInModule { param($s, $i) Test-McpJsonSchema -Schema $s -Instance $i } -Parameters @{ s = $schema; i = $Instance }
}

function Get-McpFreeTcpPort {
    <#
    .SYNOPSIS
        A TCP port on the loopback interface that is free at the time of the call.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        $listener.LocalEndpoint.Port
    } finally {
        $listener.Stop()
    }
}

function Start-McpTestHttpServer {
    <#
    .SYNOPSIS
        Runs a server object over Streamable HTTP on a free loopback port in a background runspace; returns a handle with Url, Port, Server and Background.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [hashtable] $Parameters = @{},

        [int] $TimeoutSeconds = 15
    )

    $port = Get-McpFreeTcpPort
    $url = "http://127.0.0.1:$port/mcp/"
    $startParameters = @{ Transport = 'Http'; Url = $url }
    foreach ($key in $Parameters.Keys) { $startParameters[$key] = $Parameters[$key] }
    $background = Invoke-McpInModule { param($s, $p) Start-McpBackgroundServer -Server $s -Parameters $p } -Parameters @{ s = $Server; p = $startParameters }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $Server.State.Started) {
        if ($background.PowerShell.InvocationStateInfo.State -in @('Failed', 'Completed', 'Stopped')) {
            throw "The HTTP test server did not start: $($background.PowerShell.InvocationStateInfo.Reason)"
        }
        if ($stopwatch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "The HTTP test server did not start within $TimeoutSeconds seconds." }
        Start-Sleep -Milliseconds 25
    }
    @{ Url = $url; Port = $port; Server = $Server; Background = $background }
}

function Stop-McpTestHttpServer {
    <#
    .SYNOPSIS
        Stops a server started with Start-McpTestHttpServer and waits for its runspace.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Handle
    )

    Stop-McpServer -Server $Handle.Server
    Invoke-McpInModule { param($b) Stop-McpBackgroundServer -Background $b -TimeoutSeconds 20 } -Parameters @{ b = $Handle.Background }
}

function Invoke-McpRawHttp {
    <#
    .SYNOPSIS
        Sends one raw HTTP request (no proxy) and returns Status, ContentType, Headers, Body and, when the body is JSON, Json (hashtables).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $Url,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Body,

        [hashtable] $Headers = @{},

        [string] $Method = 'POST',

        [string] $ContentType = 'application/json',

        [int] $TimeoutSeconds = 30
    )

    $handler = [System.Net.Http.SocketsHttpHandler]::new()
    $handler.UseProxy = $false
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [timespan]::FromSeconds($TimeoutSeconds)
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Url)
        if ($null -ne $Body) {
            $request.Content = [System.Net.Http.ByteArrayContent]::new([System.Text.Encoding]::UTF8.GetBytes($Body))
            if ($ContentType) { $request.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new($ContentType) }
        }
        foreach ($key in $Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation([string] $key, [string] $Headers[$key]) }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $json = $null
            if ($text -and $response.Content.Headers.ContentType -and $response.Content.Headers.ContentType.MediaType -eq 'application/json') {
                try { $json = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 50 } catch { $json = $null }
            }
            $headerTable = @{}
            foreach ($header in $response.Headers) { $headerTable[$header.Key] = @($header.Value) -join ', ' }
            foreach ($header in $response.Content.Headers) { $headerTable[$header.Key] = @($header.Value) -join ', ' }
            @{
                Status      = [int] $response.StatusCode
                ContentType = if ($response.Content.Headers.ContentType) { $response.Content.Headers.ContentType.MediaType } else { $null }
                Headers     = $headerTable
                Body        = $text
                Json        = $json
            }
        } finally {
            $response.Dispose()
        }
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

Export-ModuleMember -Function Invoke-McpInModule, Test-McpSpecShape, Get-McpFreeTcpPort, Start-McpTestHttpServer, Stop-McpTestHttpServer, Invoke-McpRawHttp
