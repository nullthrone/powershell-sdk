function Read-McpResource {
    <#
    .SYNOPSIS
        Reads resources (resources/read) and returns their contents.
    .DESCRIPTION
        Every content of the result is returned as Mcp.ResourceContent (Uri, MimeType, Text or Blob; GetBytes()
        returns the bytes of either). Results are cached per URI for the ttlMs the server sent with them. A URI
        the server does not know is reported as a non-terminating ObjectNotFound error, both for the -32602
        error of protocol version 2026-07-28 and the -32002 of earlier revisions; other errors are thrown.
    .PARAMETER Uri
        The resource URIs; accepts pipeline input, including Mcp.Resource objects from Get-McpResource.
    .PARAMETER Session
        The session; defaults to the default session.
    .PARAMETER Refresh
        Read from the server even when a cached result is fresh.
    .PARAMETER TimeoutSeconds
        The timeout for each read; defaults to the session's request timeout.
    .PARAMETER LogLevel
        Ask for notifications/message at this level and above (see the session's Log).
    .EXAMPLE
        Read-McpResource -Uri 'config://app' | Select-Object -ExpandProperty Text
    .EXAMPLE
        [System.IO.File]::WriteAllBytes('logo.png', (Read-McpResource 'images://logo').GetBytes())
    .OUTPUTS
        Mcp.ResourceContent
    #>
    [CmdletBinding()]
    [OutputType('Mcp.ResourceContent')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Uri,

        [object] $Session,

        [switch] $Refresh,

        [ValidateRange(0, 86400)]
        [int] $TimeoutSeconds = 0,

        [McpLoggingLevel] $LogLevel
    )

    begin {
        $target = Resolve-McpSession -Session $Session
        $level = if ($PSBoundParameters.ContainsKey('LogLevel')) { $LogLevel } else { $target.LogLevel }
    }
    process {
        foreach ($item in $Uri) {
            $key = "resources/read $item"
            $entry = if ($Refresh) { $null } else { Get-McpClientCacheEntry -Session $target -Key $key }
            if ($null -ne $entry) {
                foreach ($content in $entry.Value) { $content }
                continue
            }
            try {
                $exchange = Invoke-McpClientRequestWithInput -Session $target -Method 'resources/read' -Params ([ordered]@{ uri = $item }) -LogLevel $level -TimeoutMs ($TimeoutSeconds * 1000)
                $result = $exchange.Result
            } catch [McpProtocolException] {
                if (-not (Test-McpResourceNotFoundError -Exception $_.Exception)) { throw }
                $record = [System.Management.Automation.ErrorRecord]::new(
                    [System.Management.Automation.ItemNotFoundException]::new("The server has no resource '$item': $($_.Exception.Message)", $_.Exception),
                    'McpResourceNotFound',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                    $item)
                $PSCmdlet.WriteError($record)
                continue
            }
            if ($result -isnot [System.Collections.IDictionary] -or -not $result.Contains('contents')) {
                throw [System.InvalidOperationException]::new('The resources/read result has no contents member.')
            }
            $contents = @(@($result['contents']) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { ConvertTo-McpResourceContentObject -Content $_ })
            # Results that needed input rounds are not cached (the specification forbids caching them).
            if ($exchange.Rounds -eq 0) { Set-McpClientCacheEntry -Session $target -Key $key -Value $contents -CacheHint (Get-McpResultCacheHint -Result $result) }
            foreach ($content in $contents) { $content }
        }
    }
}
