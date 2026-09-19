# Transports as data: a transport is a hashtable with Kind (Stdio, Process, InMemory or Http), used only
# through functions so that the same code runs in whichever runspace hosts the dispatcher or the client. The
# line-based kinds have a line reader and a line writer: Stdio and Process transports wrap raw UTF-8 streams
# (no BOM, "\n" newlines), the in-memory transport is a pair of System.Threading.Channels channels for tests
# and in-process clients. The Http kinds (HttpServer.ps1, HttpClient.ps1) carry a listener or an HttpClient.
#
# This file is the only place in the module that touches the console streams (see Measure-McpStdoutPurity).

$script:McpAsyncWaitHandleProperty = [System.IAsyncResult].GetProperty('AsyncWaitHandle')

function Get-McpTaskWaitHandle {
    [CmdletBinding()]
    [OutputType([System.Threading.WaitHandle])]
    param(
        [Parameter(Mandatory)]
        [System.Threading.Tasks.Task] $Task
    )

    $script:McpAsyncWaitHandleProperty.GetValue($Task)
}

function New-McpUtf8Encoding {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an encoding object.')]
    [CmdletBinding()]
    [OutputType([System.Text.UTF8Encoding])]
    param()

    [System.Text.UTF8Encoding]::new($false)
}

function New-McpStdioServerTransport {
    <#
    .SYNOPSIS
        A transport over the process's standard input and output streams.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $encoding = New-McpUtf8Encoding
    $reader = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), $encoding, $false, 65536)
    $writer = [System.IO.StreamWriter]::new([Console]::OpenStandardOutput(), $encoding, 65536)
    $writer.NewLine = "`n"
    $writer.AutoFlush = $true
    @{
        Kind        = 'Stdio'
        Reader      = $reader
        Writer      = $writer
        PendingRead = $null
        Closed      = $false
    }
}

function New-McpProcessTransport {
    <#
    .SYNOPSIS
        Starts a server process and returns a transport over its standard input and output; stderr goes to a file.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The caller (Connect-McpServer) owns the ShouldProcess decision.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [string[]] $ArgumentList = @(),

        [string] $WorkingDirectory,

        [hashtable] $Environment,

        [string] $StandardErrorPath
    )

    $encoding = New-McpUtf8Encoding
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    foreach ($argument in $ArgumentList) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $encoding
    $startInfo.StandardErrorEncoding = $encoding
    $startInfo.StandardInputEncoding = $encoding
    if ($WorkingDirectory) { $startInfo.WorkingDirectory = $WorkingDirectory }
    if ($Environment) {
        foreach ($key in $Environment.Keys) { $startInfo.Environment[[string] $key] = [string] $Environment[$key] }
    }
    if (-not $StandardErrorPath) {
        $StandardErrorPath = Join-Path ([System.IO.Path]::GetTempPath()) ('mcp-server-' + [guid]::NewGuid().ToString('n') + '.stderr.log')
    }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.AutoFlush = $true
    $process.StandardInput.NewLine = "`n"
    # Buffer size 1 turns buffering off, so that the file shows the server's stderr while it runs.
    $stderrFile = [System.IO.FileStream]::new($StandardErrorPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite, 1)
    $stderrPump = $process.StandardError.BaseStream.CopyToAsync($stderrFile)
    @{
        Kind              = 'Process'
        Reader            = $process.StandardOutput
        Writer            = $process.StandardInput
        PendingRead       = $null
        Closed            = $false
        Process           = $process
        StandardErrorPath = $StandardErrorPath
        StandardErrorPump = $stderrPump
        StandardErrorFile = $stderrFile
    }
}

function New-McpInMemoryTransportPair {
    <#
    .SYNOPSIS
        Two connected in-memory transports: Server (read from the client, write to the client) and Client.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates in-memory objects.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $toServer = [System.Threading.Channels.Channel]::CreateUnbounded[string]()
    $toClient = [System.Threading.Channels.Channel]::CreateUnbounded[string]()
    @{
        Server = @{ Kind = 'InMemory'; Reader = $toServer.Reader; Writer = $toClient.Writer; PendingRead = $null; Closed = $false }
        Client = @{ Kind = 'InMemory'; Reader = $toClient.Reader; Writer = $toServer.Writer; PendingRead = $null; Closed = $false }
    }
}

function Read-McpTransportLineAsync {
    <#
    .SYNOPSIS
        The pending read task of a transport, started if none is pending. The task yields $null at end of stream.
    #>
    [CmdletBinding()]
    [OutputType([System.Threading.Tasks.Task])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Transport
    )

    if ($null -ne $Transport.PendingRead) { return $Transport.PendingRead }
    $task = if ($Transport.Kind -eq 'InMemory') {
        $Transport.Reader.ReadAsync([System.Threading.CancellationToken]::None).AsTask()
    } else {
        $Transport.Reader.ReadLineAsync()
    }
    $Transport.PendingRead = $task
    $task
}

function Complete-McpTransportRead {
    <#
    .SYNOPSIS
        The line of a completed read task, or $null at end of stream; clears the pending read.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Transport,

        [Parameter(Mandatory)]
        [System.Threading.Tasks.Task] $Task
    )

    $Transport.PendingRead = $null
    if ($Task.IsCanceled) { return $null }
    if ($Task.IsFaulted) {
        $inner = $Task.Exception.InnerException
        if ($inner -is [System.Threading.Channels.ChannelClosedException] -or $inner -is [System.IO.IOException] -or $inner -is [System.ObjectDisposedException]) {
            return $null
        }
        throw $inner
    }
    $Task.Result
}

function Receive-McpTransportLine {
    <#
    .SYNOPSIS
        Waits up to a timeout for the next line; returns a hashtable with Status (Line, Eof or Timeout) and Line.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Transport,

        [Parameter(Mandatory)]
        [int] $TimeoutMs
    )

    $task = Read-McpTransportLineAsync -Transport $Transport
    $completed = $false
    try {
        $completed = $task.Wait($TimeoutMs)
    } catch [System.AggregateException] {
        $completed = $true
    }
    if (-not $completed) {
        return @{ Status = 'Timeout'; Line = $null }
    }
    $line = Complete-McpTransportRead -Transport $Transport -Task $task
    if ($null -eq $line) { return @{ Status = 'Eof'; Line = $null } }
    @{ Status = 'Line'; Line = $line }
}

function Send-McpTransportLine {
    <#
    .SYNOPSIS
        Writes one message line; the line must not contain a newline.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Transport,

        [Parameter(Mandatory)]
        [string] $Line
    )

    if ($Transport.Closed) { throw [System.IO.IOException]::new('The transport is closed.') }
    if ($Transport.Kind -eq 'InMemory') {
        if (-not $Transport.Writer.TryWrite($Line)) { throw [System.IO.IOException]::new('The transport is closed.') }
        return
    }
    $Transport.Writer.WriteLine($Line)
}

function Close-McpTransport {
    <#
    .SYNOPSIS
        Closes the write side (and, for a server process, waits for it to exit before killing it).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Transport,

        [int] $ExitTimeoutSeconds = 5
    )

    if ($Transport.Closed) { return }
    if ($Transport.Kind -eq 'Http') {
        if ($Transport.ContainsKey('Listener')) { Close-McpHttpServerTransport -Transport $Transport } else { Close-McpHttpClientTransport -Transport $Transport }
        return
    }
    $Transport.Closed = $true
    try {
        if ($Transport.Kind -eq 'InMemory') {
            # TryComplete has an optional parameter, which PowerShell cannot omit.
            $null = $Transport.Writer.TryComplete($null)
        } else {
            $Transport.Writer.Dispose()
        }
    } catch {
        Write-McpStderr -Level Warning -Message "Closing the transport writer failed: $($_.Exception.Message)"
    }
    if ($Transport.Kind -eq 'Process' -and $null -ne $Transport.Process) {
        $process = $Transport.Process
        try {
            if (-not $process.HasExited -and -not $process.WaitForExit($ExitTimeoutSeconds * 1000)) {
                $process.Kill($true)
                $null = $process.WaitForExit(5000)
            }
        } catch {
            Write-McpStderr -Level Warning -Message "Stopping the server process failed: $($_.Exception.Message)"
        }
        try {
            if ($null -ne $Transport.StandardErrorPump) { $null = $Transport.StandardErrorPump.Wait(2000) }
            $Transport.StandardErrorFile.Dispose()
        } catch {
            Write-Debug "Closing the stderr capture failed: $($_.Exception.Message)"
        }
    }
    if ($Transport.Kind -eq 'Stdio') {
        try { $Transport.Reader.Dispose() } catch { Write-Debug 'Closing stdin failed.' }
    }
}
