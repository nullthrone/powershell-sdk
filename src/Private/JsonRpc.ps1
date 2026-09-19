# JSON-RPC 2.0 message model: constructors for requests, notifications, responses and errors, message
# classification and the error codes of the specification (JSON-RPC standard codes and the MCP range).

$script:McpJsonRpcVersion = '2.0'

# Error codes: the JSON-RPC 2.0 standard codes and the codes MCP allocates in -32020..-32099.
$script:McpErrorCode = @{
    ParseError                      = -32700
    InvalidRequest                  = -32600
    MethodNotFound                  = -32601
    InvalidParams                   = -32602
    InternalError                   = -32603
    HeaderMismatch                  = -32020
    MissingRequiredClientCapability = -32021
    UnsupportedProtocolVersion      = -32022
}

function Get-McpErrorCode {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ParseError', 'InvalidRequest', 'MethodNotFound', 'InvalidParams', 'InternalError', 'HeaderMismatch', 'MissingRequiredClientCapability', 'UnsupportedProtocolVersion')]
        [string] $Name
    )

    $script:McpErrorCode[$Name]
}

function New-McpError {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory wire object.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [int] $Code,

        [Parameter(Mandatory)]
        [string] $Message,

        [AllowNull()]
        [object] $Data
    )

    $errorObject = [ordered]@{
        code    = $Code
        message = $Message
    }
    if ($PSBoundParameters.ContainsKey('Data') -and $null -ne $Data) {
        $errorObject['data'] = $Data
    }
    $errorObject
}

function New-McpErrorResponse {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory wire object.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        # The id of the request being answered; $null when the request could not be parsed.
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Id,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ErrorObject
    )

    [ordered]@{
        jsonrpc = $script:McpJsonRpcVersion
        id      = $Id
        error   = $ErrorObject
    }
}

function New-McpResultResponse {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory wire object.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object] $Id,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Result
    )

    [ordered]@{
        jsonrpc = $script:McpJsonRpcVersion
        id      = $Id
        result  = $Result
    }
}

function New-McpRequest {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory wire object.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object] $Id,

        [Parameter(Mandatory)]
        [string] $Method,

        [System.Collections.IDictionary] $Params
    )

    $request = [ordered]@{
        jsonrpc = $script:McpJsonRpcVersion
        id      = $Id
        method  = $Method
    }
    if ($PSBoundParameters.ContainsKey('Params') -and $null -ne $Params) {
        $request['params'] = $Params
    }
    $request
}

function New-McpNotification {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory wire object.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string] $Method,

        [System.Collections.IDictionary] $Params
    )

    $notification = [ordered]@{
        jsonrpc = $script:McpJsonRpcVersion
        method  = $Method
    }
    if ($PSBoundParameters.ContainsKey('Params') -and $null -ne $Params) {
        $notification['params'] = $Params
    }
    $notification
}

function Test-McpRequestId {
    <#
    .SYNOPSIS
        True when the value is a valid JSON-RPC request id for MCP: a string or an integer (null is not allowed).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Id
    )

    if ($null -eq $Id) { return $false }
    if ($Id -is [string]) { return $true }
    if ($Id -is [long] -or $Id -is [int] -or $Id -is [int16] -or $Id -is [byte]) { return $true }
    if ($Id -is [double]) { return [math]::Floor([double] $Id) -eq [double] $Id }
    $false
}

function Get-McpMessageKind {
    <#
    .SYNOPSIS
        Classifies a decoded JSON-RPC message: Request, Notification, Response, ErrorResponse or Invalid.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Message
    )

    if ($Message -isnot [System.Collections.IDictionary]) { return 'Invalid' }
    if (-not $Message.Contains('jsonrpc') -or $Message['jsonrpc'] -ne $script:McpJsonRpcVersion) { return 'Invalid' }
    if ($Message.Contains('method')) {
        if ($Message['method'] -isnot [string] -or [string]::IsNullOrEmpty($Message['method'])) { return 'Invalid' }
        if ($Message.Contains('params') -and $null -ne $Message['params'] -and $Message['params'] -isnot [System.Collections.IDictionary]) { return 'Invalid' }
        if ($Message.Contains('id')) {
            if (Test-McpRequestId -Id $Message['id']) { return 'Request' }
            return 'Invalid'
        }
        return 'Notification'
    }
    if ($Message.Contains('result')) {
        if ($Message.Contains('id') -and (Test-McpRequestId -Id $Message['id'])) { return 'Response' }
        return 'Invalid'
    }
    if ($Message.Contains('error')) {
        if ($Message['error'] -isnot [System.Collections.IDictionary]) { return 'Invalid' }
        return 'ErrorResponse'
    }
    'Invalid'
}

function ConvertTo-McpErrorObject {
    <#
    .SYNOPSIS
        The error object for an exception: the code and data of an McpProtocolException, otherwise an internal error.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Exception] $Exception
    )

    if ($Exception -is [McpProtocolException]) {
        if ($null -ne $Exception.Data -and $Exception.Data -isnot [System.Collections.IDictionary] -and $Exception.Data -isnot [string] -and $Exception.Data -isnot [System.Collections.IList]) {
            return New-McpError -Code $Exception.Code -Message $Exception.Message
        }
        return New-McpError -Code $Exception.Code -Message $Exception.Message -Data $Exception.Data
    }
    New-McpError -Code $script:McpErrorCode.InternalError -Message $Exception.Message
}
