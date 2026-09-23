# Subscriptions (`subscriptions/listen`)

Revision 2026-07-28 replaces the GET SSE stream and `resources/subscribe` of earlier revisions with one
long-lived request: `subscriptions/listen`. Its params name the notifications the client wants:

```json
{ "notifications": { "toolsListChanged": true, "promptsListChanged": true, "resourcesListChanged": true,
                     "resourceSubscriptions": ["file:///var/log/app.log"] } }
```

The server answers with a stream: first `notifications/subscriptions/acknowledged` with the subset it
honours, then the requested notifications as they occur, every one of them (the acknowledgement included)
tagged with `_meta["io.modelcontextprotocol/subscriptionId"]`, the id of the listen request. The request
ends when the client cancels it, or with a result when the server shuts down.

## Server

**Capabilities.** A server declares `tools.listChanged: true`, and `listChanged: true` for prompts and
resources plus `resources.subscribe: true` when it has prompts or resources; the acknowledgement honours
exactly the requested types that are declared. `notifications/resources/updated` for a subscribed URI
covers its sub-resources too (`<uri>/...`).

**Announcing changes.** Registering or removing a tool, prompt or resource on a running server
(`Register-McpTool`, `Unregister-McpTool`, and the prompt and resource counterparts) sends the matching
`list_changed` notification. Handlers registered after the start are callable at once: workers define them
on first use. For changes the server cannot see (a resource whose content changed, a list computed by a
handler) there are explicit commands:

| Command | Notification |
|---|---|
| `Send-McpToolListChanged` | `notifications/tools/list_changed` |
| `Send-McpPromptListChanged` | `notifications/prompts/list_changed` |
| `Send-McpResourceListChanged` | `notifications/resources/list_changed` |
| `Send-McpResourceUpdated -Uri <uri[]>` | `notifications/resources/updated` |

They work from a handler (`-Context $Context`) and from any runspace that holds the server object
(`-Server $server`, for example a thread job that watches a file; `Start-McpServer` itself blocks the host
script's runspace); on a server that is not running they do nothing.

```powershell
Register-McpResource -Uri 'logs://app' -Name 'app-log' -ScriptBlock { Get-Content -Raw -Path /var/log/app.log }
$null = Start-ThreadJob -ArgumentList $server -ScriptBlock {
    param($server)
    Import-Module ModelContextProtocol
    $watcher = [System.IO.FileSystemWatcher]::new('/var/log', 'app.log')
    while ($true) {
        $null = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::Changed)
        Send-McpResourceUpdated -Server $server -Uri 'logs://app'
    }
}
Start-McpServer -Server $server
```

**Transports.** Listen requests never occupy a worker. Over stdio the notifications share the output stream
with the responses; `notifications/cancelled` with the listen request's id ends the subscription without a
response. Over Streamable HTTP every listen request gets its own SSE response stream, kept open with
keep-alive comments; a client that closes the stream is detected by the next failed write and dropped.
Request-scoped notifications (progress, log messages) never go to listen streams.

**Shutdown.** `Stop-McpServer`, the end of stdin and the end of the HTTP listener close every open
subscription gracefully: its request is answered with `{ "resultType": "complete" }` carrying the
subscription id and the server info.

## Client

```powershell
$subscription = Register-McpSubscription -ToolsListChanged -ResourceUri 'file:///var/log/app.log'
$subscription.Honoured                                    # what the server acknowledged
Receive-McpNotification -Subscription $subscription -TimeoutSeconds 60
Unregister-McpSubscription -Subscription $subscription
```

`Register-McpSubscription` sends the listen request, waits for the acknowledgement and returns an
`Mcp.Subscription` (`Id`, `State` Open, Reconnecting, Closed or Failed, `Requested`, `Honoured`,
`Reconnects`, `Error`). Received notifications (`Mcp.Notification`: `Method`, `Uri`, `SubscriptionId`,
`Params`, `Received`) are queued for `Receive-McpNotification`, which returns what is queued and, with
`-TimeoutSeconds`, waits for the first one. With `-Action { param($Notification) ... }` they are passed to the
script block instead.

Every notification also invalidates the session's result cache: a list change drops the cached list, a
resource update drops the cached contents of the resource and its sub-resources. The next `Get-McpTool` or
`Read-McpResource` then asks the server again.

**Threading.** Notifications arrive while no command runs, so they are read in the background: over stdio
and in memory, the first subscription switches the session to a reader runspace that moves every line of
the server's output into an inbox, from which requests read their responses too; over Streamable HTTP each
subscription's stream has its own reader runspace. `-Action` script blocks and cache invalidation run in
the caller's runspace, whenever a client command of this module runs on the session;
`Receive-McpNotification -TimeoutSeconds` is the way to wait for them.

**Reconnects.** When an HTTP stream closes abruptly, the reader sends the listen request again with a new id,
after 1, 2, 4, 8 and 16 seconds, then gives up (`State` Closed, `Error` with the reason);
`-NoReconnect` turns this off. `CurrentId` is the id of the current listen request, with which the server
tags its notifications; `Id` stays the same. A graceful close by the server ends the subscription without
a reconnect. Over stdio a server that exits ends every subscription.

`Disconnect-McpServer` ends all subscriptions of the session before it closes the transport.
