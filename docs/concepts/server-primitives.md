# Server primitives

Tools (milestone M1), resources, prompts and completion (milestone M3) are implemented. This page records how
they map onto PowerShell, the contract for their handlers, and the caching behaviour on both sides.

## Registration and capabilities

| Primitive | Server command | Methods | Capability in `server/discover` |
|---|---|---|---|
| Tool | `Register-McpTool` | `tools/list`, `tools/call` | `tools` (always) |
| Resource | `Register-McpResource -Uri` or `-Path <file>` | `resources/list`, `resources/read` | `resources` once a resource or template exists |
| Resource template | `Register-McpResource -UriTemplate` or `-Path <directory>` | `resources/templates/list`, `resources/read` | `resources` |
| Prompt | `Register-McpPrompt` | `prompts/list`, `prompts/get` | `prompts` once a prompt exists |
| Completion | `-Completion` on prompts and templates, `ValidateSet` of prompt parameters | `completion/complete` | `completions` once a source exists |

A capability that is not declared has no methods: they answer `-32601`, as the specification requires (the
`server-stateless` conformance scenario checks this for prompts). `listChanged` and `subscribe` are `false`
until `subscriptions/listen` can deliver the notifications (milestone M4).

The list methods and everything without user code (fixed `-Content`, value-list completions) are answered by
the dispatcher itself. `tools/call`, `resources/read` of files, directories and handlers, `prompts/get` and
completion handlers run in the worker runspace pool, with the request's cancellation token and timeout.

## Handler contract

Handlers run in a hostless runspace pool. They see only their parameters, so pass all data through them. The
request context arrives in a parameter named `Context` (`Mcp.RequestContext`: `RequestId`, `Method`, `Name`,
`ProtocolVersion`, `ClientInfo`, `ClientCapabilities`, `LogLevel`, `ProgressToken`, `CancellationToken`).
Warnings, information, verbose and debug records go to stderr and, when the request carried
`io.modelcontextprotocol/logLevel`, to the client as `notifications/message` (warning, info, debug). Resource,
prompt and completion handlers also report non-terminating errors as `error`.

| Handler | Parameters it may declare | Output |
|---|---|---|
| Resource | `Uri`, `Variables` (all template variables), each template variable by name, `Context` | strings (joined into one text content), `byte[]` (a blob; `return $bytes` works too), `FileInfo` (the file), objects (JSON text), `New-McpResourceContent` (several contents, own URI, MIME type, `_meta`). No output or `ItemNotFoundException` means not found. |
| Prompt | each argument by name (converted to the parameter type), or `Arguments` (all values) with explicit `-Arguments`; `Context` | strings (joined into one user text message), content blocks (`New-McpContent`, one user message each), `New-McpPromptMessage` (role and content), objects (JSON text) |
| Completion | `Value` (typed so far), `Argument` (its name), `Arguments` (`context.arguments`), `Context` | candidate strings, returned as given (the handler filters) |

Prompt arguments are strings on the wire. Without `-Arguments` they are derived from the handler's parameters:
a mandatory parameter is a required argument, the comment-based help describes it, and a `ValidateSet`
becomes a completion source. Every prompt should have a description (`-Description` or `.SYNOPSIS`); the
registration warns otherwise, because clients show descriptions in their prompt lists.

## URIs and templates

Resource URIs must be absolute (RFC 3986). `resources/read` serves an exact resource URI first and otherwise
the first template, in registration order, whose RFC 6570 template matches. Levels 1 to 3 are supported: the
operators none, `+`, `#`, `.`, `/`, `;`, `?` and `&`. Values are percent-decoded before they reach the
handler. The level 4 modifiers (prefix `:n` and explode `*`) are rejected at registration, because matching
them in reverse is ambiguous.

`Register-McpResource -Path <directory>` registers the template `<base>/{+path}` (the base defaults to the
`file://` URI of the directory). The path is combined with the directory and normalised; `..` segments,
absolute paths and symbolic links whose target lies outside the directory are answered as not found, which
satisfies the specification's requirement to sanitise file resources against directory traversal.

## Errors

| Situation | Error |
|---|---|
| Unknown resource URI, a handler without output or throwing `ItemNotFoundException`, a missing file | `-32602` `Resource not found` with `data.uri` (SEP-2164; never an empty `contents`) |
| `uri` missing or not an absolute URI, unknown prompt, missing required argument, non-string argument value | `-32602` |
| Unknown completion reference, argument or template variable | `-32602` |
| A resource, prompt or completion handler throws | `-32603` with the message |
| A tool handler throws | a tool result with `isError` (the model sees it), as for every tool execution error |

Over Streamable HTTP these map to the HTTP statuses of the transport (400 for `-32602`), and the `Mcp-Name`
header of `resources/read` (`params.uri`) and `prompts/get` (`params.name`) is validated against the body.

## Caching

Every `complete` result that the specification makes cacheable carries `ttlMs` and `cacheScope`:
`server/discover`, the four list methods (the server defaults, `New-McpServer -DefaultTtlMs
-DefaultCacheScope`, on every page so that all pages share one scope) and `resources/read` (the resource's own
`-TtlMs`/`-CacheScope`, else the server defaults). `prompts/get`, `completion/complete` and `tools/call`
results are not cacheable.

The client keeps a cache per session. `Get-McpServerInfo`, `Get-McpTool`, `Get-McpResource`,
`Get-McpPrompt` and `Read-McpResource` (per URI) reuse a result until its `ttlMs` has elapsed; for a list
the shortest `ttlMs` of its pages applies. A `ttlMs` of 0 (immediately stale) is never cached. `-Refresh`
bypasses the cache. The cache is session-local, so private and public results are both reusable; the scope is
kept with each entry. Invalidation by list-changed notifications follows with `subscriptions/listen` (M4).

## Pagination

The list methods page with `New-McpServer -PageSize`. Cursors are opaque base64 strings that name their list
and the offset of the next page; a cursor of one list is rejected by another (`-32602 Invalid cursor.`). The
client follows `nextCursor` through all pages.
