# Dual era: 2026-07-28 next to 2025-11-25 and 2025-06-18

Implemented in milestone M5. The 2026-07-28 core is stateless; the legacy revisions need sessions,
`initialize`, server-initiated requests and GET-based SSE streams. Both are served by the same process and
endpoint without contaminating the core, and the client speaks both.

## Server

- **Which eras.** `New-McpServer -SupportedVersions` decides: the default `2026-07-28, 2025-11-25,
  2025-06-18` is dual-era, `2026-07-28` alone is modern-only, legacy revisions alone are legacy-only. A server
  with any legacy revision also accepts `2025-03-26` in `initialize` (as a version string, without features
  of its own). `server/discover` and the `data.supported` of `-32022` list the modern versions only.
- **Era selection per message** (`Get-McpMessageEra`, `src/Private/Era.ps1`). Over Streamable HTTP a request
  with `Mcp-Session-Id` belongs to that legacy session (404 when there is none). Otherwise a request whose
  `_meta` carries `io.modelcontextprotocol/protocolVersion` is modern, also `initialize` (a modern client
  asking for a removed method gets 404 and `-32601`); `initialize` without it opens a legacy session; over
  stdio and in memory every other request belongs to the process-wide legacy session once one was opened.
  The methods only the legacy revisions have (`ping`, `logging/setLevel`, `resources/subscribe`,
  `resources/unsubscribe`) are `-32601` for modern requests, `server/discover` and `subscriptions/listen` are
  `-32601` in a legacy session.
- **Modern-only and legacy-only servers.** A modern-only server answers `initialize` with `-32022` and the
  versions it supports (the SHOULD of the versioning page; HTTP 400), keeps GET and DELETE at 405 and
  ignores `Mcp-Session-Id`. A legacy-only server answers requests before `initialize` with `-32600`, an
  error that no 2026-07-28 server sends, so that dual-era clients fall back.
- **Legacy session** (`src/Private/LegacySession.ps1`). `initialize` echoes a requested version the server
  accepts and answers with its newest legacy version otherwise; the `InitializeResult` has
  `protocolVersion`, the capabilities of `server/discover` plus `logging`, `serverInfo` (without
  `description`, `websiteUrl` and `icons` before 2025-11-25) and `instructions`. `notifications/initialized`
  marks the session initialized, `ping` answers `{}`, `logging/setLevel` sets the level from which the
  session's requests send `notifications/message`, `resources/subscribe`/`unsubscribe` maintain the URIs
  whose updates (and those of their sub-resources) the session receives. List changes go to every
  initialized session, unsolicited: over stdio on the line, over HTTP on the session's GET stream (dropped
  while none is open).
- **Server-initiated requests.** Handlers stay era-agnostic: `Request-McpElicitation`, `Request-McpSampling`
  and `Request-McpRoot` check the capabilities the client declared in `initialize` and then, in a legacy
  session, send the request to the client and wait for the answer instead of ending the round with an
  `InputRequiredResult`. The worker enqueues the request for the dispatcher and blocks on the answer, the
  cancellation of its request or the request timeout; the dispatcher writes the request on the line, on the
  SSE stream of the request that asked (over HTTP) or on the session's GET stream, and hands the client's
  response back to the worker. The answer is validated like an input response and cached under its key, so
  `-Defer`/`Wait-McpInput` and repeated calls work unchanged. URL mode needs 2025-11-25 and gets an
  `elicitationId`; `-32042` is not used (the blocking request replaces it).
- **Era-aware serialization in one place** (`ConvertTo-McpEraMessage`, `ConvertTo-McpLegacyResult`). Legacy
  results carry no `resultType`, `ttlMs`, `cacheScope` or `io.modelcontextprotocol/` `_meta` keys; an unknown
  resource is `-32002` instead of `-32602` (`McpResourceNotFoundException`); the error codes that only
  2026-07-28 has become `-32600`. The dispatcher converts what it answers itself, the worker what handlers
  return.
- **Streamable HTTP.** `initialize` returns a UUID as `Mcp-Session-Id`. Requests of a session skip the
  header validation of 2026-07-28; `MCP-Protocol-Version` is optional (absent means 2025-03-26) and must be a
  legacy version. Notifications of a session are dispatched, responses to server-initiated requests are
  accepted with 202. GET with the session id opens the session's stream (one per session, 409 for a second
  one, `Connection: close`), DELETE ends the session (its requests are cancelled, its open server-initiated
  requests fail). Errors of a session are JSON-RPC responses with status 200. `Start-McpServer
  -SessionIdleTimeoutSeconds` (default 1800) ends sessions without requests and without an open GET stream,
  `-MaxSessions` (default 100) answers further `initialize` requests with 503.
- **Request ids** are unique per session only: the requests of a legacy session are keyed with the session's
  prefix, so two sessions and the stateless core can use the same ids at the same time.
- **Not implemented:** SSE resumability on the server (event ids, replay after `Last-Event-ID`; a MAY, and the
  `server-sse-polling` scenario is pending in the suite). A closed POST stream cancels the handler in both
  eras; without resumability its response could not be delivered anyway.

## Client

- **Detection** (`Connect-McpServer -Era Auto`, the default; `src/Private/ClientLegacy.ps1`). The client
  probes with `server/discover` (at most five seconds). A DiscoverResult means modern; `-32020`, `-32021`
  and `-32022` mean modern too (after `-32022` the client retries once with a mutual version). Anything else
  means legacy: another error (a legacy server's answer to an unknown method before `initialize`), no answer
  in time, an HTTP error without a JSON-RPC body, or a result that is not a DiscoverResult. The fallback is
  not keyed to one error code. The era of an HTTP endpoint is cached for the process; a failing cached
  assumption is probed again. `-Era Modern` and `-Era Legacy` skip the detection; a legacy
  `-ProtocolVersion` is the version requested in `initialize` (default 2025-11-25).
- **Legacy lifecycle.** `initialize` with the client info and the capabilities in the shape of the requested
  revision (no `extensions`; elicitation without modes before 2025-11-25), then `notifications/initialized`.
  The server's `protocolVersion` must be 2025-11-25, 2025-06-18 or 2025-03-26. Requests carry no
  per-request `_meta` fields but the progress token; over HTTP they carry `Mcp-Session-Id` and the negotiated
  `MCP-Protocol-Version` instead of `Mcp-Method`, `Mcp-Name` and `Mcp-Param-*`. A 404 on a request of the
  session starts a new session and repeats the request once. `Get-McpServerInfo` returns what `initialize`
  reported; `Disconnect-McpServer` sends DELETE (a refusal is fine).
- **Requests of the server** (`elicitation/create`, `sampling/createMessage`, `roots/list`, `ping`) are
  answered with the same callbacks as input requests (`-OnElicitation`, `-OnSampling`, `-OnRoots`), on stdio,
  on a response stream or on the GET stream; a request without a callback is answered with `-32601`. Over
  HTTP the session opens its GET stream after `initialize` (tolerating 405) and reads it without blocking
  on the caller's thread, also while a request of the session waits for its response, because servers send
  requests that belong to no client request there.
- **Logging.** `-LogLevel` of `Connect-McpServer`, `Set-McpLogLevel` and `-LogLevel` of `Invoke-McpTool`,
  `Invoke-McpPrompt` and `Read-McpResource` send `logging/setLevel` when the level changes and the server
  declares `logging`.
- **Subscriptions.** `Register-McpSubscription` sends `resources/subscribe` for `-ResourceUri` and filters the
  unsolicited list changes; `Unregister-McpSubscription` sends `resources/unsubscribe` for URIs no other
  subscription needs. List changes and resource updates invalidate the cache in any case.
- **Resumption.** A response stream that ends before the response, after the server announced an event id,
  is resumed with GET and `Last-Event-ID` once the announced `retry` time (default one second) has passed;
  the response is read from the new stream. Priming events (an id with an empty data line) are skipped.
- **Results** without `resultType` are complete, `-32002` is an unknown resource (`Read-McpResource` reports
  `ObjectNotFound`).

## Compatibility matrix

`tests/Integration/LegacyClient.Tests.ps1` runs the matrix of the versioning page in memory: a client with
`-Era Auto`, `Modern` or `Legacy` against a modern-only, a legacy-only and a dual-era server. Auto always
connects (modern where the server offers it), Modern fails against a legacy-only server, Legacy fails
against a modern-only server with `-32022` and the supported versions, and every other combination speaks
the era of the client's choice.
