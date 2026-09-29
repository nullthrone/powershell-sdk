# Resource registry: static resources (fixed content, files, handlers) and resource templates (RFC 6570,
# handlers or directories), the Resource and ResourceTemplate definitions of the list methods, the resolution
# of a URI to a registration, and the shaping of content into ReadResourceResult.

$script:McpMimeTypes = @{
    '.txt' = 'text/plain'; '.log' = 'text/plain'; '.md' = 'text/markdown'; '.markdown' = 'text/markdown'
    '.csv' = 'text/csv'; '.tsv' = 'text/tab-separated-values'; '.html' = 'text/html'; '.htm' = 'text/html'
    '.css' = 'text/css'; '.js' = 'text/javascript'; '.mjs' = 'text/javascript'; '.ts' = 'text/plain'
    '.ps1' = 'text/plain'; '.psm1' = 'text/plain'; '.psd1' = 'text/plain'; '.ps1xml' = 'application/xml'
    '.py' = 'text/x-python'; '.cs' = 'text/plain'; '.sh' = 'text/x-shellscript'; '.ini' = 'text/plain'
    '.json' = 'application/json'; '.xml' = 'application/xml'; '.yaml' = 'application/yaml'; '.yml' = 'application/yaml'
    '.toml' = 'application/toml'; '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'
    '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif'; '.webp' = 'image/webp'; '.ico' = 'image/x-icon'
    '.bmp' = 'image/bmp'; '.pdf' = 'application/pdf'; '.zip' = 'application/zip'; '.gz' = 'application/gzip'
    '.wav' = 'audio/wav'; '.mp3' = 'audio/mpeg'; '.ogg' = 'audio/ogg'; '.mp4' = 'video/mp4'
}
$script:McpTextMimeTypes = @('application/json', 'application/xml', 'application/yaml', 'application/toml', 'application/javascript', 'image/svg+xml')

function Get-McpMimeType {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($script:McpMimeTypes.ContainsKey($extension)) { return $script:McpMimeTypes[$extension] }
    'application/octet-stream'
}

function Test-McpTextMimeType {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [string] $MimeType
    )

    if (-not $MimeType) { return $false }
    $essence = $MimeType.Split(';')[0].Trim().ToLowerInvariant()
    $essence.StartsWith('text/') -or $essence -in $script:McpTextMimeTypes -or $essence.EndsWith('+json') -or $essence.EndsWith('+xml')
}

function Test-McpResourceUri {
    <#
    .SYNOPSIS
        Whether a string is an absolute URI (RFC 3986) as the uri members of resources require.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Uri
    )

    if ($Uri -isnot [string] -or $Uri.Length -eq 0 -or $Uri -match '\s') { return $false }
    $parsed = $null
    [uri]::TryCreate($Uri, [System.UriKind]::Absolute, [ref] $parsed) -and $Uri -match '^[A-Za-z][A-Za-z0-9+.-]*:'
}

function Test-McpResourceCapability {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server
    )

    ($Server.Resources.Count + $Server.ResourceTemplates.Count) -gt 0
}

function Get-McpResourceSize {
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Registration
    )

    if ($null -ne $Registration.Size) { return [long] $Registration.Size }
    switch ($Registration.Source) {
        'Content' {
            if ($Registration.Content -is [byte[]]) { return [long] $Registration.Content.Length }
            return [long] [System.Text.Encoding]::UTF8.GetByteCount([string] $Registration.Content)
        }
        'File' {
            $info = [System.IO.FileInfo]::new($Registration.Path)
            if ($info.Exists) { return [long] $info.Length }
        }
    }
    [long] -1
}

function ConvertTo-McpResourceDefinition {
    <#
    .SYNOPSIS
        The Resource object (as sent in resources/list) of a static resource registration.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Registration
    )

    $resource = [ordered]@{
        uri  = $Registration.Uri
        name = $Registration.Name
    }
    if ($Registration.Title) { $resource['title'] = $Registration.Title }
    if ($Registration.Description) { $resource['description'] = $Registration.Description }
    if ($Registration.MimeType) { $resource['mimeType'] = $Registration.MimeType }
    $size = Get-McpResourceSize -Registration $Registration
    if ($size -ge 0) { $resource['size'] = $size }
    if ($null -ne $Registration.Icons) { $resource['icons'] = @($Registration.Icons) }
    if ($null -ne $Registration.Annotations) { $resource['annotations'] = $Registration.Annotations }
    if ($null -ne $Registration.Meta) { $resource['_meta'] = $Registration.Meta }
    $resource
}

function ConvertTo-McpResourceTemplateDefinition {
    <#
    .SYNOPSIS
        The ResourceTemplate object (as sent in resources/templates/list) of a template registration.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Registration
    )

    $template = [ordered]@{
        uriTemplate = $Registration.UriTemplate
        name        = $Registration.Name
    }
    if ($Registration.Title) { $template['title'] = $Registration.Title }
    if ($Registration.Description) { $template['description'] = $Registration.Description }
    if ($Registration.MimeType) { $template['mimeType'] = $Registration.MimeType }
    if ($null -ne $Registration.Icons) { $template['icons'] = @($Registration.Icons) }
    if ($null -ne $Registration.Annotations) { $template['annotations'] = $Registration.Annotations }
    if ($null -ne $Registration.Meta) { $template['_meta'] = $Registration.Meta }
    $template
}

function Get-McpResourceListResult {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [AllowNull()]
        [object] $Cursor
    )

    Get-McpPagedListResult -Server $Server -Kind 'resources' -Items @($Server.Resources.Values) -Cursor $Cursor -Converter { param($registration) ConvertTo-McpResourceDefinition -Registration $registration }
}

function Get-McpResourceTemplateListResult {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [AllowNull()]
        [object] $Cursor
    )

    Get-McpPagedListResult -Server $Server -Kind 'resourceTemplates' -Items @($Server.ResourceTemplates.Values) -Cursor $Cursor -Converter { param($registration) ConvertTo-McpResourceTemplateDefinition -Registration $registration }
}

function New-McpResourceNotFoundException {
    <#
    .SYNOPSIS
        The error for a URI that names no resource: -32602 with the URI in data (SEP-2164); -32002 in the legacy revisions.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an exception object.')]
    [CmdletBinding()]
    [OutputType([McpProtocolException])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Uri
    )

    [McpResourceNotFoundException]::new($Uri)
}

function Resolve-McpResourceRequest {
    <#
    .SYNOPSIS
        The registration serving a URI (exact static match first, then templates in registration order) and the template variables.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [Parameter(Mandatory)]
        [string] $Uri
    )

    if ($Server.Resources.Contains($Uri)) {
        return @{ Registration = $Server.Resources[$Uri]; Variables = [ordered]@{} }
    }
    foreach ($registration in $Server.ResourceTemplates.Values) {
        $variables = Test-McpUriTemplateMatch -Template $registration.Template -Uri $Uri
        if ($null -ne $variables) {
            return @{ Registration = $registration; Variables = $variables }
        }
    }
    throw (New-McpResourceNotFoundException -Uri $Uri)
}

function Get-McpResourceCacheHint {
    <#
    .SYNOPSIS
        The ttlMs and cacheScope of a resources/read result: the registration's, else the server defaults.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server,

        [Parameter(Mandatory)]
        [pscustomobject] $Registration
    )

    @{
        TtlMs      = if ($null -ne $Registration.TtlMs) { [long] $Registration.TtlMs } else { [long] $Server.Options.DefaultTtlMs }
        CacheScope = if ($Registration.CacheScope) { $Registration.CacheScope } else { $Server.Options.DefaultCacheScope }
    }
}

function New-McpResourceContentObject {
    <#
    .SYNOPSIS
        A TextResourceContents or BlobResourceContents wire object.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory wire object.')]
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter(ParameterSetName = 'Text', Mandatory)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(ParameterSetName = 'Blob', Mandatory)]
        [object] $Blob,

        [AllowNull()]
        [string] $MimeType,

        [AllowNull()]
        [System.Collections.IDictionary] $Meta
    )

    $content = [ordered]@{ uri = $Uri }
    if ($MimeType) { $content['mimeType'] = $MimeType }
    if ($PSCmdlet.ParameterSetName -eq 'Text') { $content['text'] = $Text } else { $content['blob'] = ConvertTo-McpBase64 -Data $Blob }
    if ($null -ne $Meta -and $Meta.Count -gt 0) { $content['_meta'] = $Meta }
    $content
}

function Read-McpFileResourceContent {
    <#
    .SYNOPSIS
        The contents of a file as text (text MIME types, UTF-8) or blob; $null when the file does not exist.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Uri,

        [AllowNull()]
        [string] $MimeType
    )

    if (-not [System.IO.File]::Exists($Path)) { return $null }
    if (-not $MimeType) { $MimeType = Get-McpMimeType -Path $Path }
    if (Test-McpTextMimeType -MimeType $MimeType) {
        return New-McpResourceContentObject -Uri $Uri -Text ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)) -MimeType $MimeType
    }
    New-McpResourceContentObject -Uri $Uri -Blob ([System.IO.File]::ReadAllBytes($Path)) -MimeType $MimeType
}

function Get-McpRealPath {
    <#
    .SYNOPSIS
        The path with every symbolic link along it resolved.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [int] $Depth = 0
    )

    if ($Depth -gt 32) { throw [System.IO.IOException]::new('Too many levels of symbolic links.') }
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    $current = $root
    $separators = [char[]] @([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    foreach ($part in $full.Substring($root.Length).Split($separators, [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $next = [System.IO.Path]::Combine($current, $part)
        $item = if ([System.IO.Directory]::Exists($next)) { [System.IO.DirectoryInfo]::new($next) } else { [System.IO.FileInfo]::new($next) }
        if ($null -ne $item.LinkTarget) {
            $target = $item.ResolveLinkTarget($true)
            if ($null -ne $target) { $next = Get-McpRealPath -Path $target.FullName -Depth ($Depth + 1) }
        }
        $current = $next
    }
    $current
}

function Test-McpPathWithin {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Root
    )

    $comparison = if ($IsLinux) { [System.StringComparison]::Ordinal } else { [System.StringComparison]::OrdinalIgnoreCase }
    $prefix = if ([System.IO.Path]::EndsInDirectorySeparator($Root)) { $Root } else { $Root + [System.IO.Path]::DirectorySeparatorChar }
    $Path.StartsWith($prefix, $comparison)
}

function Resolve-McpDirectoryResourcePath {
    <#
    .SYNOPSIS
        The file a relative path names below a directory resource root; $null when it escapes the root or does not exist.
    .DESCRIPTION
        The path is combined with the root and normalised; '..' segments, absolute paths and symbolic links
        that lead outside the root are rejected, as the specification requires for file resources.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $RelativePath
    )

    if (-not $RelativePath -or $RelativePath.Contains([char] 0)) { return $null }
    try {
        $rootFull = [System.IO.Path]::GetFullPath($Root)
        $candidate = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($rootFull, $RelativePath.TrimStart('/')))
        if ([System.IO.Path]::IsPathRooted($RelativePath.TrimStart('/')) -or -not (Test-McpPathWithin -Path $candidate -Root $rootFull)) { return $null }
        if (-not [System.IO.File]::Exists($candidate)) { return $null }
        $real = Get-McpRealPath -Path $candidate
        if (-not (Test-McpPathWithin -Path $real -Root (Get-McpRealPath -Path $rootFull))) { return $null }
        $candidate
    } catch [System.IO.IOException] {
        $null
    } catch [System.ArgumentException] {
        $null
    } catch [System.UnauthorizedAccessException] {
        $null
    }
}

function ConvertTo-McpResourceContentList {
    <#
    .SYNOPSIS
        Shapes the output of a resource handler into resource contents.
    .DESCRIPTION
        New-McpResourceContent objects (Mcp.ResourceContents) pass through; their uri defaults to the
        requested URI. Consecutive strings become one text content, byte arrays (or a stream of bytes) a blob content, FileInfo objects
        the contents of the file, and other objects JSON text. Without an explicit MIME type text is
        text/plain, JSON application/json and binary application/octet-stream.
    #>
    [CmdletBinding()]
    [OutputType([object[]], [System.Array])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Output,

        [Parameter(Mandatory)]
        [pscustomobject] $Registration,

        [Parameter(Mandatory)]
        [string] $Uri
    )

    # A loop instead of the pipeline keeps byte[] items whole; a handler that wrote a byte[] to the pipeline
    # (return $bytes) produced single bytes, which are joined again.
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Output)) {
        if ($null -ne $item) { $items.Add($item) }
    }
    if ($items.Count -gt 0 -and @($items | Where-Object { $_ -isnot [byte] }).Count -eq 0) {
        $items = @(, [byte[]] $items.ToArray())
    }
    $contents = [System.Collections.Generic.List[object]]::new()
    $texts = [System.Collections.Generic.List[string]]::new()
    $objects = [System.Collections.Generic.List[object]]::new()
    $mimeType = $Registration.MimeType
    $flush = {
        if ($texts.Count -gt 0) {
            $contents.Add((New-McpResourceContentObject -Uri $Uri -Text ($texts -join "`n") -MimeType $(if ($mimeType) { $mimeType } else { 'text/plain' })))
            $texts.Clear()
        }
        if ($objects.Count -gt 0) {
            $value = if ($objects.Count -eq 1) { $objects[0] } else { , $objects.ToArray() }
            $contents.Add((New-McpResourceContentObject -Uri $Uri -Text (ConvertTo-McpJson -InputObject $value) -MimeType $(if ($mimeType) { $mimeType } else { 'application/json' })))
            $objects.Clear()
        }
    }
    foreach ($item in $items) {
        if ($item.PSObject.TypeNames -contains 'Mcp.ResourceContents') {
            . $flush
            $content = [ordered]@{}
            foreach ($property in $item.PSObject.Properties) {
                if ($null -ne $property.Value) { $content[$property.Name] = $property.Value }
            }
            if (-not $content.Contains('uri')) {
                $ordered = [ordered]@{ uri = $Uri }
                foreach ($key in $content.Keys) { $ordered[$key] = $content[$key] }
                $content = $ordered
            }
            $contents.Add($content)
        } elseif ($item -is [byte[]]) {
            . $flush
            $contents.Add((New-McpResourceContentObject -Uri $Uri -Blob $item -MimeType $(if ($mimeType) { $mimeType } else { 'application/octet-stream' })))
        } elseif ($item -is [System.IO.FileInfo]) {
            . $flush
            $fileContent = Read-McpFileResourceContent -Path $item.FullName -Uri $Uri -MimeType $mimeType
            if ($null -ne $fileContent) { $contents.Add($fileContent) }
        } elseif ($item -is [string]) {
            if ($objects.Count -gt 0) { . $flush }
            $texts.Add($item)
        } elseif ($item -is [valuetype] -or $item -is [enum] -or $item -is [uri] -or $item -is [version]) {
            if ($objects.Count -gt 0) { . $flush }
            $texts.Add([System.Management.Automation.LanguagePrimitives]::ConvertTo($item, [string]))
        } else {
            if ($texts.Count -gt 0) { . $flush }
            $objects.Add($item)
        }
    }
    . $flush
    , $contents.ToArray()
}

function ConvertTo-McpReadResourceResult {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Contents,

        [Parameter(Mandatory)]
        [hashtable] $CacheHint
    )

    [ordered]@{
        resultType = 'complete'
        contents   = $Contents
        ttlMs      = [long] $CacheHint.TtlMs
        cacheScope = $CacheHint.CacheScope
    }
}

function Invoke-McpResourceHandler {
    <#
    .SYNOPSIS
        Reads a resource: fixed content, a file, a file below a directory root or the output of a handler.
    .DESCRIPTION
        Returns the ReadResourceResult. A resource that yields no contents, a missing file and a handler that
        throws ItemNotFoundException are reported as resource not found (-32602 with the URI); other handler
        failures become internal errors (-32603).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Registration,

        [Parameter(Mandatory)]
        [string] $Uri,

        [System.Collections.IDictionary] $Variables = [ordered]@{},

        [AllowNull()]
        [object] $Context,

        [Parameter(Mandatory)]
        [hashtable] $CacheHint,

        [switch] $UseCommandName
    )

    $contents = @()
    switch ($Registration.Source) {
        'Content' {
            $contents = ConvertTo-McpResourceContentList -Output @(, $Registration.Content) -Registration $Registration -Uri $Uri
        }
        'File' {
            $content = Read-McpFileResourceContent -Path $Registration.Path -Uri $Uri -MimeType $Registration.MimeType
            if ($null -ne $content) { $contents = @($content) }
        }
        'Directory' {
            $path = Resolve-McpDirectoryResourcePath -Root $Registration.Path -RelativePath $Variables['path']
            if ($null -ne $path) {
                $contents = @(Read-McpFileResourceContent -Path $path -Uri $Uri -MimeType $null)
            }
        }
        'Handler' {
            $values = [ordered]@{ Uri = $Uri; Variables = $Variables }
            foreach ($key in $Variables.Keys) {
                if (-not $values.Contains($key)) { $values[$key] = $Variables[$key] }
            }
            $splat = New-McpHandlerSplat -Handler $Registration.Handler -Values $values -Context $Context
            $threshold = if ($null -ne $Context -and $null -ne $Context.ServerLogLevel) { $Context.ServerLogLevel } else { $script:McpDefaultLogLevel }
            try {
                $merged = @(Invoke-McpHandlerCommand -Handler $Registration.Handler -Splat $splat -UseCommandName:$UseCommandName)
            } catch [System.Management.Automation.PipelineStoppedException] {
                throw
            } catch {
                $exception = Get-McpHandlerException -Exception $_.Exception
                if ($exception -is [McpProtocolException]) { throw $exception }
                if ($exception -is [System.Management.Automation.ItemNotFoundException] -or $exception -is [System.IO.FileNotFoundException]) { throw (New-McpResourceNotFoundException -Uri $Uri) }
                throw [McpProtocolException]::new($script:McpErrorCode.InternalError, "Reading resource '$Uri' failed: $($exception.Message)")
            }
            $parts = Split-McpHandlerOutput -Merged $merged
            Write-McpHandlerDiagnostic -Diagnostics $parts.Diagnostics -Name $Uri -Threshold $threshold -Context $Context -ErrorRecords $parts.Errors
            $contents = ConvertTo-McpResourceContentList -Output $parts.Output -Registration $Registration -Uri $Uri
            if ($contents.Count -eq 0 -and $parts.Errors.Count -gt 0) {
                throw [McpProtocolException]::new($script:McpErrorCode.InternalError, "Reading resource '$Uri' failed: $($parts.Errors[0].ToString())")
            }
        }
    }
    if (@($contents).Count -eq 0) { throw (New-McpResourceNotFoundException -Uri $Uri) }
    ConvertTo-McpReadResourceResult -Contents @($contents) -CacheHint $CacheHint
}
