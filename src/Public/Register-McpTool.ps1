function Register-McpTool {
    <#
    .SYNOPSIS
        Registers a PowerShell command or script block as an MCP tool on a server.
    .DESCRIPTION
        A tool is a function, cmdlet, script file or script block. Its input schema is generated from the
        parameters (types, validation attributes, comment-based help and constant defaults) unless -InputSchema
        is given. Common parameters and a parameter named Context are never part of the schema; a Context
        parameter receives the request context (Mcp.RequestContext) at call time.

        Arguments of a tools/call request are validated against the input schema, converted to the parameter
        types and splatted onto the command. With -InputSchema, a handler that declares a parameter named
        Arguments receives the raw argument dictionary instead. Handler output becomes the CallToolResult:
        content blocks from New-McpContent pass through, strings become text blocks, and objects become JSON
        text (a single object also becomes structuredContent).

        Handlers run in a worker runspace pool without a host: they must receive everything through their
        parameters, and nothing they write to stdout or the host reaches the client.
    .PARAMETER Command
        The command to expose: a name (resolved with Get-Command) or a CommandInfo of a function, cmdlet or script file.
    .PARAMETER ScriptBlock
        The handler as a script block; its param() block defines the arguments.
    .PARAMETER Name
        The tool name (1-128 characters: letters, digits, '_', '-', '.'); defaults to the command name.
    .PARAMETER Title
        A human-readable title.
    .PARAMETER Description
        The tool description; defaults to the synopsis of the command's comment-based help.
    .PARAMETER InputSchema
        An explicit JSON Schema (hashtable or JSON text) for the arguments; replaces the generated schema.
    .PARAMETER OutputSchema
        A JSON Schema (hashtable or JSON text) that structuredContent must satisfy.
    .PARAMETER Annotations
        Tool annotations: Title, ReadOnlyHint, DestructiveHint, IdempotentHint, OpenWorldHint.
    .PARAMETER Icons
        Icon objects (hashtables with src, and optionally mimeType, sizes, theme).
    .PARAMETER Meta
        Additional _meta members of the tool definition.
    .PARAMETER Header
        Parameters to mirror into HTTP headers over Streamable HTTP, as a map of parameter name to header name
        (the x-mcp-header annotation of the input schema): @{ Region = 'Region' } makes clients send
        Mcp-Param-Region with the value of -Region. Only string, integer and boolean parameters can be
        mirrored; never mirror secrets, header values are visible to intermediaries.
    .PARAMETER AllowAdditionalProperties
        Let the generated schema accept arguments that are not parameters (they are passed through by name).
    .PARAMETER Server
        The server to register on; defaults to the server set with New-McpServer -SetDefault.
    .PARAMETER Force
        Replace an existing registration with the same name.
    .PARAMETER PassThru
        Return the registration object.
    .EXAMPLE
        Register-McpTool -Command Get-Weather -Description 'Current weather for a location.'
    .EXAMPLE
        Register-McpTool -Name echo -ScriptBlock { param([Parameter(Mandatory)][string] $Text) $Text }
    .OUTPUTS
        Mcp.ToolRegistration (with -PassThru)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes an in-memory registry only.')]
    [CmdletBinding(DefaultParameterSetName = 'Command')]
    [OutputType('Mcp.ToolRegistration')]
    param(
        [Parameter(ParameterSetName = 'Command', Mandatory, Position = 0)]
        [ValidateNotNull()]
        [object] $Command,

        [Parameter(ParameterSetName = 'ScriptBlock', Mandatory)]
        [scriptblock] $ScriptBlock,

        [Parameter(ParameterSetName = 'ScriptBlock', Mandatory)]
        [Parameter(ParameterSetName = 'Command')]
        [string] $Name,

        [string] $Title,

        [string] $Description,

        [object] $InputSchema,

        [object] $OutputSchema,

        [hashtable] $Annotations,

        [object[]] $Icons,

        [hashtable] $Meta,

        [hashtable] $Header,

        [switch] $AllowAdditionalProperties,

        [object] $Server,

        [switch] $Force,

        [switch] $PassThru
    )

    $target = Resolve-McpServer -Server $Server
    if ($PSCmdlet.ParameterSetName -eq 'ScriptBlock') {
        if (-not $Name) { throw [System.ArgumentException]::new('A script block tool needs a -Name.') }
        $descriptor = New-McpHandlerDescriptor -Prefix 'McpTool' -Key $Name -ScriptBlock $ScriptBlock
    } else {
        $commandInfo = Resolve-McpHandlerCommand -Command $Command -Cmdlet $PSCmdlet
        if (-not $Name) { $Name = $commandInfo.Name }
        $descriptor = New-McpHandlerDescriptor -Prefix 'McpTool' -Key $Name -CommandInfo $commandInfo
    }
    $handler = $descriptor.Handler
    $ast = $descriptor.Ast
    $parameters = $descriptor.Parameters

    if ($Name -notmatch $script:McpToolNamePattern) {
        throw [System.ArgumentException]::new("'$Name' is not a valid tool name: 1-128 characters from A-Z, a-z, 0-9, '_', '-' and '.'.")
    }
    if ($target.Tools.Contains($Name) -and -not $Force) {
        throw [System.InvalidOperationException]::new("A tool named '$Name' is already registered; use -Force to replace it.")
    }

    $help = Get-McpCommandHelp -Ast $ast
    if (-not $Description) {
        $Description = if ($help.Synopsis) { $help.Synopsis } elseif ($help.Description) { $help.Description } else { $null }
    }
    if ($null -ne $parameters) {
        $generated = New-McpToolInputSchema -Parameters $parameters -Help $help -Defaults (Get-McpParameterDefaultValue -Ast $ast) -AllowAdditionalProperties:$AllowAdditionalProperties
        $handler.ParameterTypes = $generated.ParameterTypes
        $schema = $generated.Schema
    } else {
        $schema = [ordered]@{ type = 'object'; additionalProperties = $false }
    }
    if ($PSBoundParameters.ContainsKey('InputSchema') -and $null -ne $InputSchema) {
        $schema = ConvertTo-McpSchemaObject -Schema $InputSchema
        if ($schema -isnot [System.Collections.IDictionary] -or $schema['type'] -ne 'object') {
            throw [System.ArgumentException]::new('-InputSchema must be a JSON Schema object with "type": "object".')
        }
        Test-McpSchemaLimit -Schema $schema
        if ($handler.ParameterTypes.ContainsKey('Arguments')) { $handler.ArgumentStyle = 'Arguments' }
    }
    if ($Header -and $Header.Count -gt 0) {
        Add-McpHeaderAnnotation -Schema $schema -Header $Header
    }
    $headerParameters = @()
    try {
        $headerParameters = @(Get-McpToolHeaderParameter -InputSchema $schema)
    } catch [System.ArgumentException] {
        throw [System.ArgumentException]::new("Tool '$Name' has an invalid x-mcp-header annotation: $($_.Exception.Message)")
    }
    $outputSchemaObject = $null
    if ($PSBoundParameters.ContainsKey('OutputSchema') -and $null -ne $OutputSchema) {
        $outputSchemaObject = ConvertTo-McpSchemaObject -Schema $OutputSchema
        Test-McpSchemaLimit -Schema $outputSchemaObject
    }

    $registration = [pscustomobject]@{
        PSTypeName       = 'Mcp.ToolRegistration'
        Name             = $Name
        Title            = $Title
        Description      = $Description
        InputSchema      = $schema
        OutputSchema     = $outputSchemaObject
        Annotations      = ConvertTo-McpAnnotationObject -Annotations $Annotations
        Icons            = ConvertTo-McpIconList -Icons $Icons
        Meta             = $Meta
        HeaderParameters = $headerParameters
        Handler          = $handler
    }
    $target.Tools[$Name] = $registration
    if ($PassThru) { $registration }
}
