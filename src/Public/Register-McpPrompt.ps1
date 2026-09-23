function Register-McpPrompt {
    <#
    .SYNOPSIS
        Registers a prompt template (a script block or command that produces messages) on a server.
    .DESCRIPTION
        A prompt is listed by prompts/list and rendered by prompts/get. Its arguments are strings; unless
        -Arguments is given they are derived from the handler's parameters: a mandatory parameter is a
        required argument, the comment-based help describes it, and a ValidateSet offers its values as argument
        completion. Argument values are converted to the parameter types; a parameter named Context receives the
        request context. With -Arguments, a handler that declares a parameter named Arguments receives all
        argument values as a dictionary instead.

        The handler runs in the server's worker runspace pool. Its output becomes the messages: strings are
        joined into one user text message, content blocks (New-McpContent) become user messages, and
        New-McpPromptMessage sets the role (user or assistant) or the content explicitly.
    .PARAMETER Name
        The prompt name; defaults to the command name with -Command.
    .PARAMETER ScriptBlock
        The handler as a script block.
    .PARAMETER Command
        The handler as a command name or CommandInfo of a function, cmdlet or script file.
    .PARAMETER Arguments
        The arguments as hashtables with Name and optionally Title, Description and Required (or plain names);
        replaces the arguments derived from the handler's parameters.
    .PARAMETER Title
        A human-readable title.
    .PARAMETER Description
        The prompt description; defaults to the synopsis of the handler's comment-based help. Clients show it
        in their prompt lists, so every prompt should have one.
    .PARAMETER Icons
        Icon objects (hashtables with src, and optionally mimeType, sizes, theme).
    .PARAMETER Meta
        Additional _meta members of the prompt definition.
    .PARAMETER Completion
        Argument completion: a hashtable of argument name to a list of values (offered when they start with
        the typed text) or a script block that receives the parameters it declares of Value, Argument,
        Arguments and Context and returns the candidates. Replaces the values derived from ValidateSet.
    .PARAMETER Server
        The server to register on; defaults to the server set with New-McpServer -SetDefault.
    .PARAMETER Force
        Replace an existing registration with the same name.
    .PARAMETER PassThru
        Return the registration object.
    .EXAMPLE
        Register-McpPrompt -Name 'summarize' -Description 'Summarises a text.' -ScriptBlock {
            param([Parameter(Mandatory)][string] $Text)
            "Summarise the following text in three sentences:`n$Text"
        }
    .OUTPUTS
        Mcp.PromptRegistration (with -PassThru)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes an in-memory registry only.')]
    [CmdletBinding(DefaultParameterSetName = 'ScriptBlock')]
    [OutputType('Mcp.PromptRegistration')]
    param(
        [Parameter(ParameterSetName = 'ScriptBlock', Mandatory, Position = 0)]
        [Parameter(ParameterSetName = 'Command')]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(ParameterSetName = 'ScriptBlock', Mandatory, Position = 1)]
        [scriptblock] $ScriptBlock,

        [Parameter(ParameterSetName = 'Command', Mandatory)]
        [ValidateNotNull()]
        [object] $Command,

        [object[]] $Arguments,

        [string] $Title,

        [string] $Description,

        [object[]] $Icons,

        [object] $Meta,

        [System.Collections.IDictionary] $Completion,

        [object] $Server,

        [switch] $Force,

        [switch] $PassThru
    )

    $target = Resolve-McpServer -Server $Server
    if ($PSCmdlet.ParameterSetName -eq 'ScriptBlock') {
        $descriptor = New-McpHandlerDescriptor -Prefix 'McpPrompt' -Key $Name -ScriptBlock $ScriptBlock
    } else {
        $commandInfo = Resolve-McpHandlerCommand -Command $Command -Cmdlet $PSCmdlet
        if (-not $Name) { $Name = $commandInfo.Name }
        $descriptor = New-McpHandlerDescriptor -Prefix 'McpPrompt' -Key $Name -CommandInfo $commandInfo
    }
    if ($target.Prompts.Contains($Name) -and -not $Force) {
        throw [System.InvalidOperationException]::new("A prompt named '$Name' is already registered; use -Force to replace it.")
    }
    $handler = $descriptor.Handler
    $help = Get-McpCommandHelp -Ast $descriptor.Ast
    if (-not $Description) {
        $Description = if ($help.Synopsis) { $help.Synopsis } elseif ($help.Description) { $help.Description } else { $null }
    }

    $derivedCompletion = [ordered]@{}
    if ($PSBoundParameters.ContainsKey('Arguments')) {
        $argumentList = ConvertTo-McpPromptArgumentList -Arguments $Arguments
        if ($handler.ParameterNames -contains 'Arguments' -and @($argumentList | Where-Object { $_['name'] -ieq 'Arguments' }).Count -eq 0) {
            $handler.ArgumentStyle = 'Arguments'
        }
    } else {
        $generated = New-McpToolInputSchema -Parameters $descriptor.Parameters -Help $help -Defaults (Get-McpParameterDefaultValue -Ast $descriptor.Ast) -AllowAdditionalProperties
        $handler.ParameterTypes = $generated.ParameterTypes
        $required = @($generated.Schema['required'])
        $argumentList = @(foreach ($entry in @(if ($generated.Schema.Contains('properties')) { $generated.Schema['properties'].GetEnumerator() })) {
                $argument = [ordered]@{ name = [string] $entry.Key }
                if ($entry.Value.Contains('description')) { $argument['description'] = [string] $entry.Value['description'] }
                if ($required -contains $entry.Key) { $argument['required'] = $true }
                if ($entry.Value.Contains('enum')) { $derivedCompletion[[string] $entry.Key] = @($entry.Value['enum'] | ForEach-Object { [string] $_ }) }
                $argument
            })
    }
    $argumentNames = [string[]] @($argumentList | ForEach-Object { $_['name'] })
    foreach ($key in @($derivedCompletion.Keys)) {
        if ($null -ne $Completion -and $Completion.Contains($key)) { $derivedCompletion.Remove($key) }
    }
    if ($null -ne $Completion) {
        foreach ($key in $Completion.Keys) { $derivedCompletion[$key] = $Completion[$key] }
    }
    if (-not $Description) {
        Write-Warning "The prompt '$Name' has no description; clients show descriptions in their prompt lists."
    }

    $registration = [pscustomobject]@{
        PSTypeName  = 'Mcp.PromptRegistration'
        Name        = $Name
        Title       = $Title
        Description = $Description
        Arguments   = $argumentList
        Icons       = ConvertTo-McpIconList -Icons $Icons
        Meta        = ConvertTo-McpMetaObject -Meta $Meta
        Handler     = $handler
        Completion  = ConvertTo-McpCompletionSource -Completion $derivedCompletion -ArgumentNames $argumentNames -Key $Name
    }
    $target.Prompts[$Name] = $registration
    if ($PassThru) { $registration }
}
