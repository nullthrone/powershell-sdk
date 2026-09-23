function Write-McpProgress {
    <#
    .SYNOPSIS
        Sends a notifications/progress message for the request a tool handler is serving.
    .DESCRIPTION
        Nothing is sent when the client did not include a progressToken in the request. Progress values must
        increase from call to call; a value that does not increase is ignored with a diagnostic on stderr.
    .PARAMETER Context
        The request context (the handler's Context parameter).
    .PARAMETER Progress
        The progress so far (any increasing number).
    .PARAMETER Total
        The total, when known.
    .PARAMETER Message
        A human-readable status.
    .EXAMPLE
        Write-McpProgress -Context $Context -Progress 1 -Total 3 -Message 'Fetching'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(Mandatory)]
        [double] $Progress,

        [double] $Total = [double]::NaN,

        [string] $Message
    )

    if ($null -eq $Context.ProgressToken -or $null -eq $Context.Sink) { return }
    $state = $Context.ProgressState
    if ($null -ne $state -and $null -ne $state.Last -and $Progress -le [double] $state.Last) {
        Write-McpStderr -Level Warning -Threshold $Context.ServerLogLevel -Logger $Context.Name -Message "Progress $Progress does not increase over $($state.Last); the notification is not sent."
        return
    }
    if ($null -ne $state) { $state.Last = $Progress }
    $params = [ordered]@{
        progressToken = $Context.ProgressToken
        progress      = $Progress
    }
    if (-not [double]::IsNaN($Total)) { $params['total'] = $Total }
    if ($Message) { $params['message'] = $Message }
    $notification = New-McpNotification -Method 'notifications/progress' -Params $params
    Send-McpSinkMessage -Sink $Context.Sink -Kind Notification -RequestId $Context.RequestId -Json (ConvertTo-McpJson -InputObject $notification)
}
