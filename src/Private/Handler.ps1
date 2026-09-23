# Handlers of tools, resources, prompts and completions: resolving the command or script block given at
# registration, the descriptor that lets the worker runspaces invoke it by name, parameter binding and the
# invocation itself with all streams merged.

function Resolve-McpHandlerCommand {
    <#
    .SYNOPSIS
        The CommandInfo of a command given by name (resolved in the caller's scope first) or as CommandInfo.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.CommandInfo])]
    param(
        [Parameter(Mandatory)]
        [object] $Command,

        # The PSCmdlet of the public registration command; names resolve in its caller's scope first so that
        # functions of the calling script are found.
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCmdlet] $Cmdlet
    )

    $commandInfo = $Command
    if ($Command -is [string]) {
        $commandInfo = $Cmdlet.SessionState.InvokeCommand.GetCommand($Command, [System.Management.Automation.CommandTypes]::All)
        if ($null -eq $commandInfo) {
            $commandInfo = Get-Command -Name $Command -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($null -eq $commandInfo) {
            throw [System.Management.Automation.CommandNotFoundException]::new("The command '$Command' was not found. Pass the result of Get-Command for functions defined in a nested scope.")
        }
    }
    if ($commandInfo -isnot [System.Management.Automation.CommandInfo]) {
        throw [System.ArgumentException]::new('-Command must be a command name or a CommandInfo object.')
    }
    if ($commandInfo -is [System.Management.Automation.AliasInfo]) {
        $commandInfo = $commandInfo.ResolvedCommand
    }
    $commandInfo
}

function Get-McpHandlerFunctionName {
    <#
    .SYNOPSIS
        The function name under which a script block handler exists in the worker runspaces.
    .DESCRIPTION
        Characters outside A-Z, a-z, 0-9 and '_' are replaced; a name that needed replacing gets a hash suffix
        so that, for example, the tools 'a-b' and 'a_b' do not share a function.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Prefix,

        [Parameter(Mandatory)]
        [string] $Key
    )

    $sanitised = $Key -replace '[^A-Za-z0-9_]', '_'
    if ($sanitised.Length -gt 64) { $sanitised = $sanitised.Substring(0, 64) }
    $name = $Prefix + '_' + $sanitised
    if ($sanitised -cne $Key) {
        $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Key))
        $name += '_' + [System.Convert]::ToHexString($hash, 0, 4).ToLowerInvariant()
    }
    $name
}

function New-McpHandlerDescriptor {
    <#
    .SYNOPSIS
        Describes a handler given as script block or CommandInfo: how workers invoke it and which parameters it has.
    .OUTPUTS
        A hashtable with Handler (the descriptor stored on the registration), Ast, Parameters and CommandName.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory descriptor.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # The function-name prefix of script block handlers: McpTool, McpResource, McpPrompt or McpCompletion.
        [Parameter(Mandatory)]
        [string] $Prefix,

        [Parameter(Mandatory)]
        [string] $Key,

        [scriptblock] $ScriptBlock,

        [System.Management.Automation.CommandInfo] $CommandInfo
    )

    $handler = @{
        Kind             = $null
        CommandName      = $null
        Definition       = $null
        ModuleName       = $null
        ModulePath       = $null
        CommandInfo      = $null
        ScriptBlock      = $null
        ArgumentStyle    = 'Splat'
        ContextParameter = $null
        ParameterTypes   = @{}
        ParameterNames   = @()
    }
    $ast = $null
    $parameters = $null

    if ($null -ne $ScriptBlock) {
        $handler.Kind = 'ScriptBlock'
        $handler.ScriptBlock = $ScriptBlock
        $handler.Definition = $ScriptBlock.ToString()
        $handler.CommandName = Get-McpHandlerFunctionName -Prefix $Prefix -Key $Key
        $ast = $ScriptBlock.Ast
        $temporaryName = 'McpTemporaryHandler_' + [guid]::NewGuid().ToString('n')
        Set-Item -Path "function:script:$temporaryName" -Value $ScriptBlock
        try {
            $parameters = (Get-Command -Name $temporaryName -CommandType Function).Parameters
        } finally {
            Remove-Item -Path "function:script:$temporaryName" -ErrorAction SilentlyContinue
        }
    } elseif ($null -ne $CommandInfo) {
        $handler.CommandInfo = $CommandInfo
        switch ($CommandInfo.GetType().Name) {
            'FunctionInfo' {
                $handler.Kind = 'Function'
                $handler.CommandName = $CommandInfo.Name
                $ast = $CommandInfo.ScriptBlock.Ast
                if ($CommandInfo.Module -and $CommandInfo.Module.Path) {
                    $handler.ModuleName = $CommandInfo.Module.Name
                    $handler.ModulePath = $CommandInfo.Module.Path
                } else {
                    $handler.Definition = $CommandInfo.Definition
                }
            }
            'CmdletInfo' {
                $handler.Kind = 'Cmdlet'
                $handler.CommandName = $CommandInfo.Name
                if ($CommandInfo.Module) {
                    $handler.ModuleName = $CommandInfo.Module.Name
                    $handler.ModulePath = $CommandInfo.Module.Path
                } elseif ($CommandInfo.ModuleName) {
                    $handler.ModuleName = $CommandInfo.ModuleName
                }
            }
            'ExternalScriptInfo' {
                $handler.Kind = 'Script'
                $handler.CommandName = $CommandInfo.Path
                $ast = $CommandInfo.ScriptBlock.Ast
            }
            default {
                throw [System.ArgumentException]::new("Commands of type $($CommandInfo.CommandType) cannot be registered as handlers.")
            }
        }
        $parameters = $CommandInfo.Parameters
    } else {
        throw [System.ArgumentException]::new('A handler needs a script block or a command.')
    }

    $names = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $parameters) {
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters + [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
        foreach ($entry in $parameters.GetEnumerator()) {
            $name = [string] $entry.Value.Name
            if ($name -in $common) { continue }
            if ($name -ieq 'Context') { $handler.ContextParameter = $name; continue }
            $names.Add($name)
            $handler.ParameterTypes[$name] = $entry.Value.ParameterType
        }
    }
    $handler.ParameterNames = $names.ToArray()
    @{
        Handler     = $handler
        Ast         = $ast
        Parameters  = $parameters
        CommandName = if ($null -ne $CommandInfo) { $CommandInfo.Name } else { $null }
    }
}

function Get-McpHandlerParameterName {
    <#
    .SYNOPSIS
        The declared parameter name matching a name exactly, then case-insensitively; $null when there is none.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Handler,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($Handler.ParameterNames -ccontains $Name) { return $Name }
    foreach ($candidate in $Handler.ParameterNames) {
        if ($candidate -ieq $Name) { return $candidate }
    }
    $null
}

function New-McpHandlerSplat {
    <#
    .SYNOPSIS
        A splatting table with the values whose names the handler declares, converted to the declared types.
    .DESCRIPTION
        Used for resource, prompt and completion handlers: a handler declares only the parameters it wants
        (for example a template variable, Uri, Arguments or Context); values without a matching parameter are
        not passed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory table.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Handler,

        [System.Collections.IDictionary] $Values = @{},

        [AllowNull()]
        [object] $Context
    )

    $splat = @{}
    foreach ($key in $Values.Keys) {
        $parameterName = Get-McpHandlerParameterName -Handler $Handler -Name ([string] $key)
        if ($null -eq $parameterName -or $splat.ContainsKey($parameterName)) { continue }
        $splat[$parameterName] = ConvertTo-McpParameterValue -Value $Values[$key] -Type $Handler.ParameterTypes[$parameterName] -Name $parameterName
    }
    if ($Handler.ContextParameter -and $null -ne $Context) {
        $splat[$Handler.ContextParameter] = $Context
    }
    $splat
}

function Invoke-McpHandlerCommand {
    <#
    .SYNOPSIS
        Invokes a handler with all streams merged into the output (split them with Split-McpHandlerOutput).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Handler,

        [hashtable] $Splat = @{},

        # Invoke by command name in the current runspace (the worker runspaces, where handlers exist as
        # functions) instead of the script block or command object captured at registration.
        [switch] $UseCommandName
    )

    if ($UseCommandName) {
        & $Handler.CommandName @Splat *>&1
    } elseif ($Handler.Kind -eq 'ScriptBlock') {
        & $Handler.ScriptBlock @Splat *>&1
    } else {
        & $Handler.CommandInfo @Splat *>&1
    }
}

function Get-McpHandlerException {
    <#
    .SYNOPSIS
        The exception a handler failed with, unwrapped from the RuntimeException PowerShell adds around it.
    #>
    [CmdletBinding()]
    [OutputType([System.Exception])]
    param(
        [Parameter(Mandatory)]
        [System.Exception] $Exception
    )

    if ($Exception -is [System.Management.Automation.RuntimeException] -and $null -ne $Exception.InnerException -and $Exception.GetType() -eq [System.Management.Automation.RuntimeException]) {
        return $Exception.InnerException
    }
    $Exception
}

function Get-McpServerHandler {
    <#
    .SYNOPSIS
        All handler descriptors registered on a server (tools, resources, templates, prompts, completions).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Server
    )

    foreach ($registration in $Server.Tools.Values) { $registration.Handler }
    foreach ($registration in @($Server.Resources.Values) + @($Server.ResourceTemplates.Values) + @($Server.Prompts.Values)) {
        if ($null -ne $registration.Handler) { $registration.Handler }
        if ($null -ne $registration.Completion) {
            foreach ($source in $registration.Completion.Values) {
                if ($null -ne $source.Handler) { $source.Handler }
            }
        }
    }
}
