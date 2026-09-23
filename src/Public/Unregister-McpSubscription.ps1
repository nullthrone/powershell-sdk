function Unregister-McpSubscription {
    <#
    .SYNOPSIS
        Ends subscriptions opened with Register-McpSubscription.
    .DESCRIPTION
        Over stdio the listen request is cancelled with notifications/cancelled; over Streamable HTTP its
        stream is closed. Notifications still queued on the subscription stay readable with
        Receive-McpNotification -Subscription.
    .PARAMETER Subscription
        The subscriptions to end (Mcp.Subscription); accepts pipeline input.
    .PARAMETER All
        End all subscriptions of the session.
    .PARAMETER Session
        With -All, the session; defaults to the default session.
    .EXAMPLE
        Unregister-McpSubscription -Subscription $subscription
    .EXAMPLE
        Unregister-McpSubscription -All
    #>
    [CmdletBinding(DefaultParameterSetName = 'Subscription', SupportsShouldProcess)]
    param(
        [Parameter(ParameterSetName = 'Subscription', Mandatory, Position = 0, ValueFromPipeline)]
        [ValidateNotNull()]
        [object[]] $Subscription,

        [Parameter(ParameterSetName = 'All', Mandatory)]
        [switch] $All,

        [Parameter(ParameterSetName = 'All')]
        [object] $Session
    )

    process {
        $targets = if ($All) {
            $resolved = Resolve-McpSession -Session $Session
            @($resolved.Subscriptions.Values)
        } else {
            foreach ($item in $Subscription) {
                if ($item.PSObject.TypeNames -notcontains 'Mcp.Subscription') {
                    throw [System.ArgumentException]::new('-Subscription takes subscriptions returned by Register-McpSubscription.')
                }
                $item
            }
        }
        foreach ($item in $targets) {
            if ($item.State -in @('Closed', 'Failed') -and -not $item.Session.Subscriptions.Contains([string] $item.Id)) { continue }
            if (-not $PSCmdlet.ShouldProcess("subscription $($item.Id)", 'Unregister')) { continue }
            Close-McpClientSubscription -Session $item.Session -Subscription $item
        }
    }
}
