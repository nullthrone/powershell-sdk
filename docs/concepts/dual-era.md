# Dual era: 2026-07-28 next to 2025-11-25 and 2025-06-18

Implemented in milestone M5. The 2026-07-28 core is stateless; the legacy revisions need sessions,
`initialize`, server-initiated requests and GET-based SSE streams. Both are served by the same process and
endpoint without contaminating the core.

- **Era selection per message.** A message with the mandatory `_meta` fields of 2026-07-28 is handled
  statelessly. An `initialize` request opens a legacy session (process-wide on stdio; keyed by
  `Mcp-Session-Id` on HTTP). Follow-up requests are associated through the session.
- **Legacy component.** `McpLegacySession` implements `initialize`/`initialized`, capability negotiation,
  `ping`, `logging/setLevel`, `resources/subscribe`/`unsubscribe`, server-initiated `elicitation/create`,
  `sampling/createMessage` and `roots/list` with a pending-request table, the GET SSE stream, DELETE, and the
  era-specific error codes (`-32002`, `-32042`). Resumability (`Last-Event-ID`) is not implemented.
- **Era-aware serialization in one place.** Legacy responses omit `resultType`, `ttlMs` and `cacheScope`
  and use the legacy elicitation shapes; not-found is `-32002` instead of `-32602`.
- **Client.** On stdio the client probes with `server/discover`; on HTTP it sends a modern POST and inspects
  a 400 body for `-32020`/`-32021`/`-32022` before falling back to `initialize`. The detected era is cached
  per server. 2025-03-26 is accepted as a version string without additional features.
- **Handlers stay era-agnostic.** The MRTR cmdlets (`Request-McpElicitation` and friends) run as input
  requests in the modern era and as blocking server-initiated requests in a legacy session.
