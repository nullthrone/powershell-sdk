# Transports

stdio is implemented (milestone M1); Streamable HTTP follows in M2. This page records the design constraints.

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

- Host: `System.Net.HttpListener` behind a small host abstraction (request context, JSON writer, SSE writer
  with keep-alive and disconnect → cancel). Default binding `http://127.0.0.1:<port>/mcp/`, Origin allowlist
  (403), TLS only via a reverse proxy or an http.sys certificate binding on Windows.
- 2026-07-28: POST only; `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` and `Mcp-Param-*` header
  validation against the request body (`-32020` on mismatch, 400); notifications answer 202; unknown methods
  404 with `-32601`; GET and DELETE answer 405 unless the legacy layer is enabled.
- Response mode: JSON when the request carries no progress token, log level or listen semantics; SSE
  (`data: <json>\n\n`, initial comment line) otherwise. `subscriptions/listen` streams stay open with
  keep-alives.
- Client: `HttpClient` with `SocketsHttpHandler` (no auto-redirect, infinite timeout with own cancellation
  tokens), `ResponseHeadersRead`, an SSE parser, header mirroring for `x-mcp-header` tool parameters.
