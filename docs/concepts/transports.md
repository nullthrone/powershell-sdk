# Transports

stdio (milestone M1) and Streamable HTTP (milestone M2) are implemented. This page records the design and its
constraints.

Transports are plain data inside the module (a hashtable with a line reader and a line writer per kind) used
only through a handful of private functions, so the same dispatcher and client code runs in whichever
runspace hosts it. Besides stdio there is an in-memory transport (a pair of channels) that
`Connect-McpServer -Server` uses to run a server object in a background runspace of the same process.

## stdio

- The dispatcher owns raw streams from `[Console]::OpenStandardInput/Output/Error()` wrapped in UTF-8
  readers and writers without BOM and with `"\n"` as line terminator; one writer instance emits atomic lines.
- stdout carries protocol messages only. Handlers run in a hostless runspace pool, so `Write-Host`,
  progress and other host output never reach stdout; their streams are routed to stderr or to
  `notifications/message`. The analyzer rule `Measure-McpStdoutPurity` enforces the same for the module
  sources.
- Launch contract for hosts: `pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <abs>`.
- Shutdown: EOF on stdin ends the server; the client closes the child's stdin, waits, then kills the process
  tree.
- The client captures the server's stderr in a file (`StandardErrorPath` of the session), unbuffered, so that
  diagnostics can be read while the server runs.

## Streamable HTTP

`Start-McpServer -Transport Http -Url http://127.0.0.1:8080/mcp/` serves the MCP endpoint;
`Connect-McpServer -Url` connects to one.

**Server (`src/Private/HttpServer.ps1`)**

- Host: `System.Net.HttpListener` with exactly the prefix of `-Url` (`scheme://host:port/path/`). The
  server answers requests whose `Host` header does not name that host and port with 404, so clients must use
  the same host name or address; this is the first line of DNS-rebinding protection and is checked by the
  server itself because the listener implementations differ (the managed listener on Linux and macOS rejects
  other hosts on its own, http.sys on Windows delivers any `Host` to a prefix bound to an IP address). The
  default binding is the loopback address. TLS is not terminated by the module: put a reverse
  proxy in front, or use an http.sys certificate binding on Windows. On Windows, users without administrative
  rights need a URL reservation (`netsh http add urlacl`) for the prefix.
- The dispatcher loop (`Invoke-McpHttpDispatcherLoop`) accepts connections, reads bodies asynchronously
  (`-MaxBodyBytes`, 413 beyond), and gives every request a *channel*: its HTTP response. `server/discover` and
  `tools/list` are answered by the dispatcher; `tools/call` runs in the worker pool and its notifications and
  response travel through the outbound queue to the channel, like over stdio.
- Screening order per request: path (404), `Origin` (403; absent or loopback origins and the server's own
  origin are accepted by default, `-AllowedOrigins` overrides), method (GET and DELETE answer 405 with
  `Allow: POST`; revision 2026-07-28 has neither a GET stream nor sessions), content type (415), size (413),
  JSON (400 with `-32700`), message kind (notifications answer 202 and are not processed further, JSON-RPC
  responses and invalid messages 400 with `-32600`).
- Header validation (`-32020`, HTTP 400): `MCP-Protocol-Version` present and equal to
  `_meta.io.modelcontextprotocol/protocolVersion`, `Mcp-Method` equal to the method (case-sensitive, optional
  whitespace trimmed), `Mcp-Name` for `tools/call`, `resources/read` and `prompts/get` equal to `params.name`
  or `params.uri` after decoding the `=?base64?...?=` sentinel, and for `tools/call` every `x-mcp-header`
  annotated argument that is present in the body must arrive as `Mcp-Param-{Name}` with the same value
  (integers compare numerically, strings exactly; a header without a body value, a missing header, a
  malformed sentinel or invalid characters are mismatches). `initialize` is answered before the header checks
  with `-32601` naming the supported versions, so that legacy clients get a diagnostic.
- HTTP status by JSON-RPC error code: 400 for `-32700`, `-32600`, `-32602`, `-32020`, `-32021` and `-32022`;
  404 for `-32601`; 200 for everything else (including `-32603` and tool errors reported with `isError`).
- Response mode: a single JSON object (`application/json`) unless the handler sends a notification
  (progress, log message), which starts an SSE stream (`text/event-stream`, `event: message` + `data:` lines,
  `X-Accel-Buffering: no`); the response is the last event and closes the stream. A request that outlives
  `-KeepAliveSeconds` (default 5) also switches to SSE and receives keep-alive comments: a failed keep-alive
  write means the client closed the connection, which cancels the handler (token and pipeline stop). The
  same happens when the final write fails.
- Shutdown (`Stop-McpServer`): the listener stops accepting, running handlers get the grace period, open
  channels receive an error response (`-32603`, "shutting down") and are closed.

**Client (`src/Private/HttpClient.ps1`)**

- `HttpClient` on `SocketsHttpHandler` (no redirects, no cookies, no proxy for loopback URLs or with
  `-NoProxy`, infinite client timeout); every request is a POST with `Content-Type: application/json`,
  `Accept: application/json, text/event-stream`, `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` where the
  method has one (sentinel-encoded when not header-safe), the session's static `-Headers` and the
  `Mcp-Param-*` headers of the call.
- The response is read with `ResponseHeadersRead`: `application/json` bodies are one JSON-RPC message
  (error responses on any status become `McpProtocolException`), `text/event-stream` bodies are parsed event
  by event (`data:` lines joined, comments and `id`/`retry` fields ignored) with notifications dispatched to
  the progress and log callbacks until the response with the request id arrives. A deadline cancels the
  request and disposes the response, which closes the stream: the cancellation signal of this transport.
- `Get-McpTool` validates the `x-mcp-header` annotations of every tool (`Get-McpToolHeaderParameter`) and
  excludes invalid tools with a warning; `Invoke-McpTool` derives the `Mcp-Param-*` headers from the cached
  annotations and, after a `-32020` from the server, refreshes the list and retries once.
- Not implemented on purpose: the removed GET stream, `Mcp-Session-Id`, `Last-Event-ID` resumption; the
  legacy `initialize` fallback arrives with milestone M5 (dual era).
