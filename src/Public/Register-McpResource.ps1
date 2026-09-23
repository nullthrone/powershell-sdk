function Register-McpResource {
    <#
    .SYNOPSIS
        Registers a resource (fixed content, a file, a handler) or a resource template (a handler or a directory) on a server.
    .DESCRIPTION
        A resource has a URI and is listed by resources/list; a resource template has an RFC 6570 URI template
        (levels 1 to 3, for example 'weather://{city}/current' or 'docs://{+path}') and is listed by
        resources/templates/list. resources/read serves an exact resource URI first and otherwise the first
        template, in registration order, that matches the URI.

        The content comes from one source:
        - -Content: fixed text (string) or binary data (byte[]), answered without running user code.
        - -ScriptBlock or -Command: a handler that runs in the server's worker runspace pool. It receives the
          parameters it declares of: Uri (the requested URI), Variables (the template variables as a
          dictionary), every template variable by name, and Context (the request context). Strings become text
          contents, byte arrays blob contents, FileInfo objects the contents of the file, other objects JSON
          text; New-McpResourceContent returns several contents or sets their MIME type and _meta. A handler
          that returns nothing or throws ItemNotFoundException reports the resource as not found.
        - -Path to a file: the file, read at request time (text for text MIME types, otherwise a blob). The URI
          defaults to the file:// URI of the file.
        - -Path to a directory: a template for every file below the directory, 'file:///<directory>/{+path}' or
          '<Uri>/{+path}'. Paths that leave the directory ('..', absolute paths, symbolic links to the outside)
          are reported as not found.
    .PARAMETER Uri
        The resource URI (an absolute URI such as 'config://app' or 'https://example.com/data.json'); with -Path
        to a directory, the base of the template URI.
    .PARAMETER UriTemplate
        The URI template of a resource template.
    .PARAMETER Path
        A file or directory to expose.
    .PARAMETER Content
        Fixed content: a string (text) or byte[] (blob).
    .PARAMETER ScriptBlock
        The handler as a script block.
    .PARAMETER Command
        The handler as a command name or CommandInfo of a function, cmdlet or script file.
    .PARAMETER Name
        The name of the resource or template; defaults to the URI, the URI template or the file name.
    .PARAMETER Title
        A human-readable title.
    .PARAMETER Description
        A description of the resource.
    .PARAMETER MimeType
        The MIME type of the content. Defaults to text/plain for text and application/octet-stream for binary
        -Content, and to the type derived from the file extension for -Path.
    .PARAMETER Size
        The size of the raw content in bytes, listed with the resource (computed for -Content and files).
    .PARAMETER Annotations
        Annotations: Audience (user, assistant), Priority (0 to 1), LastModified (DateTime or ISO 8601 text).
    .PARAMETER Icons
        Icon objects (hashtables with src, and optionally mimeType, sizes, theme).
    .PARAMETER Meta
        Additional _meta members of the resource definition.
    .PARAMETER TtlMs
        The ttlMs caching hint of resources/read results of this resource; defaults to the server's.
    .PARAMETER CacheScope
        The cacheScope caching hint (public or private) of resources/read results; defaults to the server's.
    .PARAMETER Completion
        Argument completion for template variables: a hashtable of variable name to a list of values (offered
        when they start with the typed text) or a script block that receives the parameters it declares of
        Value, Argument, Arguments and Context and returns the candidates.
    .PARAMETER Server
        The server to register on; defaults to the server set with New-McpServer -SetDefault.
    .PARAMETER Force
        Replace an existing registration with the same URI or URI template.
    .PARAMETER PassThru
        Return the registration object.
    .EXAMPLE
        Register-McpResource -Uri 'config://app' -Name 'app-config' -MimeType 'application/json' -Content '{ "mode": "demo" }'
    .EXAMPLE
        Register-McpResource -UriTemplate 'weather://{city}/current' -Name 'current-weather' -ScriptBlock { param($city) Get-Weather -Location $city }
    .EXAMPLE
        Register-McpResource -Path ./docs -Uri 'docs://' -Description 'Project documentation'
    .OUTPUTS
        Mcp.ResourceRegistration (with -PassThru)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes an in-memory registry only.')]
    [CmdletBinding(DefaultParameterSetName = 'Uri')]
    [OutputType('Mcp.ResourceRegistration')]
    param(
        [Parameter(ParameterSetName = 'Uri', Mandatory, Position = 0)]
        [Parameter(ParameterSetName = 'Path')]
        [ValidateNotNullOrEmpty()]
        [string] $Uri,

        [Parameter(ParameterSetName = 'UriTemplate', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $UriTemplate,

        [Parameter(ParameterSetName = 'Path', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(ParameterSetName = 'Uri')]
        [object] $Content,

        [Parameter(ParameterSetName = 'Uri')]
        [Parameter(ParameterSetName = 'UriTemplate')]
        [scriptblock] $ScriptBlock,

        [Parameter(ParameterSetName = 'Uri')]
        [Parameter(ParameterSetName = 'UriTemplate')]
        [object] $Command,

        [string] $Name,

        [string] $Title,

        [string] $Description,

        [string] $MimeType,

        [ValidateRange(0, [long]::MaxValue)]
        [long] $Size,

        [object] $Annotations,

        [object[]] $Icons,

        [object] $Meta,

        [ValidateRange(0, [int]::MaxValue)]
        [int] $TtlMs,

        [ValidateSet('public', 'private')]
        [string] $CacheScope,

        [Parameter(ParameterSetName = 'UriTemplate')]
        [Parameter(ParameterSetName = 'Path')]
        [System.Collections.IDictionary] $Completion,

        [object] $Server,

        [switch] $Force,

        [switch] $PassThru
    )

    $target = Resolve-McpServer -Server $Server
    $sources = @('Content', 'ScriptBlock', 'Command') | Where-Object { $PSBoundParameters.ContainsKey($_) }
    $kind = 'Resource'
    $source = $null
    $template = $null
    $handler = $null
    $filePath = $null

    switch ($PSCmdlet.ParameterSetName) {
        'Uri' {
            if (@($sources).Count -ne 1) { throw [System.ArgumentException]::new('A resource needs exactly one of -Content, -ScriptBlock and -Command.') }
            $source = if ($sources -eq 'Content') { 'Content' } else { 'Handler' }
        }
        'UriTemplate' {
            if (@($sources).Count -ne 1) { throw [System.ArgumentException]::new('A resource template needs exactly one of -ScriptBlock and -Command.') }
            $kind = 'Template'
            $source = 'Handler'
        }
        'Path' {
            $resolved = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
            if ([System.IO.Directory]::Exists($resolved)) {
                $kind = 'Template'
                $source = 'Directory'
                $filePath = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($resolved))
                $base = if ($Uri) { $Uri } else { [System.Uri]::new($filePath, [System.UriKind]::Absolute).AbsoluteUri }
                $UriTemplate = if ($base.EndsWith('/')) { $base + '{+path}' } else { $base + '/{+path}' }
                if (-not $Name) { $Name = [System.IO.Path]::GetFileName($filePath) }
            } elseif ([System.IO.File]::Exists($resolved)) {
                $source = 'File'
                $filePath = [System.IO.Path]::GetFullPath($resolved)
                if (-not $Uri) { $Uri = [System.Uri]::new($filePath, [System.UriKind]::Absolute).AbsoluteUri }
                if (-not $Name) { $Name = [System.IO.Path]::GetFileName($filePath) }
                if (-not $MimeType) { $MimeType = Get-McpMimeType -Path $filePath }
            } else {
                throw [System.Management.Automation.ItemNotFoundException]::new("The path '$Path' does not exist.")
            }
        }
    }

    if ($kind -eq 'Resource') {
        if (-not (Test-McpResourceUri -Uri $Uri)) { throw [System.ArgumentException]::new("'$Uri' is not an absolute URI.") }
        if ($target.Resources.Contains($Uri) -and -not $Force) {
            throw [System.InvalidOperationException]::new("A resource with the URI '$Uri' is already registered; use -Force to replace it.")
        }
        if (-not $Name) { $Name = $Uri }
        $key = $Uri
    } else {
        $template = ConvertFrom-McpUriTemplate -Template $UriTemplate
        if ($target.ResourceTemplates.Contains($UriTemplate) -and -not $Force) {
            throw [System.InvalidOperationException]::new("A resource template '$UriTemplate' is already registered; use -Force to replace it.")
        }
        if (-not $Name) { $Name = $UriTemplate }
        $key = $UriTemplate
    }

    if ($source -eq 'Handler') {
        $descriptor = if ($PSBoundParameters.ContainsKey('ScriptBlock')) {
            New-McpHandlerDescriptor -Prefix 'McpResource' -Key $key -ScriptBlock $ScriptBlock
        } else {
            New-McpHandlerDescriptor -Prefix 'McpResource' -Key $key -CommandInfo (Resolve-McpHandlerCommand -Command $Command -Cmdlet $PSCmdlet)
        }
        $handler = $descriptor.Handler
        if (-not $Description) {
            $help = Get-McpCommandHelp -Ast $descriptor.Ast
            $Description = if ($help.Synopsis) { $help.Synopsis } elseif ($help.Description) { $help.Description } else { $null }
        }
    }
    if ($source -eq 'Content') {
        if ($Content -is [string]) {
            if (-not $MimeType) { $MimeType = 'text/plain' }
        } elseif ($null -ne $Content -and ($Content -is [byte[]] -or $Content -is [System.Collections.IEnumerable])) {
            $Content = [System.Convert]::FromBase64String((ConvertTo-McpBase64 -Data $Content))
            if (-not $MimeType) { $MimeType = 'application/octet-stream' }
        } else {
            throw [System.ArgumentException]::new('-Content must be a string or a byte[].')
        }
    }

    $completionSources = $null
    if ($kind -eq 'Template') {
        $completionSources = ConvertTo-McpCompletionSource -Completion $Completion -ArgumentNames $template.Variables -Key $key
    }

    $registration = [pscustomobject]@{
        PSTypeName  = 'Mcp.ResourceRegistration'
        Kind        = $kind
        Uri         = if ($kind -eq 'Resource') { $Uri } else { $null }
        UriTemplate = if ($kind -eq 'Template') { $UriTemplate } else { $null }
        Template    = $template
        Name        = $Name
        Title       = $Title
        Description = $Description
        MimeType    = $MimeType
        Size        = if ($PSBoundParameters.ContainsKey('Size')) { $Size } else { $null }
        Annotations = ConvertTo-McpContentAnnotation -Annotations $Annotations
        Icons       = ConvertTo-McpIconList -Icons $Icons
        Meta        = ConvertTo-McpMetaObject -Meta $Meta
        TtlMs       = if ($PSBoundParameters.ContainsKey('TtlMs')) { $TtlMs } else { $null }
        CacheScope  = if ($CacheScope) { $CacheScope } else { $null }
        Source      = $source
        Content     = $null
        Path        = $filePath
        Handler     = $handler
        Completion  = $completionSources
    }
    # Assigned separately: an if expression would enumerate a byte[] into an object[].
    if ($source -eq 'Content') { $registration.Content = $Content }
    if ($kind -eq 'Resource') { $target.Resources[$Uri] = $registration } else { $target.ResourceTemplates[$UriTemplate] = $registration }
    if ($target.State.Started) { $null = Send-McpServerNotification -Method 'notifications/resources/list_changed' -Server $target }
    if ($PassThru) { $registration }
}
