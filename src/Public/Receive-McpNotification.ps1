function Receive-McpNotification {
    <#
    .SYNOPSIS
        Returns the notifications received on subscriptions, waiting up to a timeout for the first one.
    .DESCRIPTION
        Returns and removes the queued notifications (Mcp.Notification) of the given subscriptions, or of all
        subscriptions of the session. With -TimeoutSeconds it waits until at least one notification has arrived
        or the timeout has passed; without, it returns what is queued. Notifications of subscriptions with an
        -Action are passed to the script block instead (while this command waits, too) and are not returned.
    .PARAMETER Subscription
        The subscriptions to read; defaults to all subscriptions of the session.
    .PARAMETER TimeoutSeconds
        How long to wait for a notification (default: 0, do not wait).
    .PARAMETER Session
        Without -Subscription, the session; defaults to the default session.
    .EXAMPLE
        Receive-McpNotification -Subscription $subscription -TimeoutSeconds 30
    .OUTPUTS
        Mcp.Notification
    #>
    [CmdletBinding()]
    [OutputType('Mcp.Notification')]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [object[]] $Subscription,

        [ValidateRange(0, 86400)]
        [double] $TimeoutSeconds = 0,

        [object] $Session
    )

    begin {
        $selected = [System.Collections.Generic.List[object]]::new()
    }
    process {
        foreach ($item in $Subscription) {
            if ($item.PSObject.TypeNames -notcontains 'Mcp.Subscription') {
                throw [System.ArgumentException]::new('-Subscription takes subscriptions returned by Register-McpSubscription.')
            }
            $selected.Add($item)
        }
    }
    end {
        $target = if ($selected.Count -gt 0) { $selected[0].Session } else { Resolve-McpSession -Session $Session }
        if ($target.Closed) {
            # A closed session keeps what was queued before it closed.
            $sources = @($selected)
        } else {
            $null = Resolve-McpSession -Session $target
            $sources = if ($selected.Count -gt 0) { @($selected) } else { @($target.Subscriptions.Values) }
            $hasQueued = { foreach ($source in $sources) { if (-not $source.Notifications.IsEmpty) { return $true } }; $false }
            $null = Wait-McpClientEvent -Session $target -Condition $hasQueued -TimeoutMs ([int] ($TimeoutSeconds * 1000))
        }
        foreach ($source in $sources) {
            $notification = $null
            while ($source.Notifications.TryDequeue([ref] $notification)) { $notification }
        }
    }
}
