# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Until 1.0.0 the public API is not stable; see
[ROADMAP.md](ROADMAP.md) for the milestone plan and [DEPENDENCY_POLICY.md](DEPENDENCY_POLICY.md) for the
support, dependency and breaking-change policy.

## [Unreleased]

### Added

- Milestone M4 (multi-round-trip requests and subscriptions): handlers ask for input with
  `Request-McpElicitation` (form mode with the flat primitive schema subset, or URL mode),
  `Request-McpSampling` and `Request-McpRoot`; the request is answered with an `InputRequiredResult`, and on
  the retry the handler runs again and receives the answer. `-Defer` and `Wait-McpInput` ask for several
  inputs in one round; answers of earlier rounds and `$Context.State` travel in a `requestState` signed with
  HMAC-SHA256 and bound to method, target, argument digest and expiry (`New-McpServer -RequestStateKey`,
  `-RequestStateTtlSeconds`). Tampered or foreign states, malformed `inputResponses` and answers that do not
  match the request fail with `-32602`; input types the client did not declare fail with `-32021` and
  `data.requiredCapabilities`. Works for `tools/call`, `prompts/get` and `resources/read`.
- `subscriptions/listen` on the server: acknowledgement first with the honoured filter, every notification
  tagged with the subscription id, a strictly honoured filter, `resources/updated` for subscribed URIs and
  their sub-resources, a stream per listen request over Streamable HTTP (dropped when the client closes it),
  cancellation by `notifications/cancelled` over stdio, and a graceful `complete` result for every open
  subscription when the server stops. `Send-McpToolListChanged`, `Send-McpPromptListChanged`,
  `Send-McpResourceListChanged` and `Send-McpResourceUpdated` announce changes from handlers or any runspace.
- Dynamic registration: `Register-McpTool`, `Register-McpResource` and `Register-McpPrompt` on a running server
  and the new `Unregister-McpTool`, `Unregister-McpResource` and `Unregister-McpPrompt` notify subscribers;
  handlers registered after the start are callable at once. `listChanged` and `resources.subscribe` are
  declared as `true`.
- Client: `Connect-McpServer -OnElicitation`, `-OnSampling`, `-OnRoots` (which declare their capabilities)
  and `-MaxInputRounds`; `Invoke-McpTool`, `Invoke-McpPrompt` and `Read-McpResource` run the input rounds
  transparently and echo the `requestState` verbatim. `Register-McpSubscription`,
  `Unregister-McpSubscription` and `Receive-McpNotification` read subscriptions in the background (a reader
  runspace over stdio and in memory, one per stream over Streamable HTTP, with reconnects), invalidate the
  result cache on list changes and resource updates, and run `-Action` callbacks in the caller's runspace.
- Conformance: the fixture server implements the input-request and list-change fixtures, the fixture client
  answers input requests; the server baseline is empty and the client baseline holds only the authorization
  scenarios. `examples/elicitation-server.ps1` demonstrates input requests and list-change notifications.
- Milestone M3 (server primitives): `Register-McpResource` registers resources with fixed text or binary
  content, files, handlers and RFC 6570 resource templates (levels 1 to 3; variables are bound to the
  handler's parameters), and directories as `<base>/{+path}` templates that reject `..`, absolute paths and
  symbolic links leading outside; `resources/list`, `resources/templates/list` and `resources/read` with
  `-32602` and `data.uri` for unknown resources (SEP-2164) and per-resource caching hints (`-TtlMs`,
  `-CacheScope`).
- `Register-McpPrompt` registers prompts whose arguments are derived from the handler's parameters (or given
  with `-Arguments`); `prompts/list` and `prompts/get` with argument validation and message shaping (strings,
  content blocks, `New-McpPromptMessage`). `completion/complete` for prompt arguments and template variables
  from `-Completion` value lists or handlers and from `ValidateSet`, capped at 100 values with `total` and
  `hasMore`.
- The `resources`, `prompts` and `completions` capabilities are declared when something is registered; their
  methods answer `-32601` otherwise. All list methods page with cursors bound to their list.
- `New-McpContent` validates annotations (`audience`, `priority`, `lastModified`) and takes `-Icons` for
  resource links and `-ResourceMeta` for embedded resources; icons of servers, tools, resources and prompts are
  validated; `New-McpPromptMessage` and `New-McpResourceContent` build prompt messages and resource contents.
- Warning, information, verbose and debug records of handlers are sent as `notifications/message` when the
  request asks for log notifications (besides stderr); the request context has a `Name` for every kind of
  handler.
- Client: `Get-McpResource [-Template]`, `Read-McpResource` (pipeline input, non-terminating `ObjectNotFound`
  errors for `-32602` with `data.uri` and the legacy `-32002`), `Get-McpPrompt`, `Invoke-McpPrompt` and
  `Get-McpCompletion`; a per-session cache that reuses `server/discover`, list and `resources/read` results
  for their `ttlMs`; content blocks and resource contents are typed objects with `GetBytes()`; format views
  for the new objects.
- Conformance: the fixture server registers the resources, template, prompts and completions of the
  resource, prompt, completion and caching scenarios, whose baseline entries are removed; the fixture client
  also reads resources and renders prompts when the server declares them. `examples/weather-server.ps1`
  demonstrates every server primitive.
- Milestone M2 (Streamable HTTP): `Start-McpServer -Transport Http -Url ...` serves the MCP endpoint on
  `System.Net.HttpListener`: one JSON-RPC request or notification per POST, responses as a single JSON
  object or as a request-scoped SSE stream (progress and log notifications, keep-alive comments, a closed
  stream cancels the handler), validation of `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` and
  `Mcp-Param-*` against the body including the `=?base64?...?=` sentinel (`-32020`, HTTP 400), `Host` (404)
  and `Origin` validation (403, `-AllowedOrigins`), 405 for GET and DELETE, 404 for unknown and removed methods, 202 for
  notifications, body limits (`-MaxBodyBytes`) and `-KeepAliveSeconds`.
- `Connect-McpServer -Url` (with `-Headers` and `-NoProxy`): the Streamable HTTP client on `HttpClient` with
  the request metadata headers, an SSE reader, timeouts that close the response stream, and `x-mcp-header`
  support: `Get-McpTool` excludes tools with invalid annotations (with a warning), `Invoke-McpTool` mirrors
  annotated arguments into `Mcp-Param-*` headers and retries once after a header mismatch.
- `Register-McpTool -Header @{ Parameter = 'HeaderName' }` annotates the input schema with `x-mcp-header`;
  annotations are validated on registration (field-name tokens, primitive types, uniqueness, reachability).
- Sessions carry `Endpoint`; error responses without a determinable request id omit the `id` member, as the
  specification schema requires; `tools.listChanged` is advertised as false until `subscriptions/listen` lands.
- Conformance: `tests/Conformance/everything-server.ps1` and `everything-client.ps1`, the `Conformance` build
  task (server and client legs of the pinned `@modelcontextprotocol/conformance` alpha against
  `conformance-baseline.yml`), the `Conformance` workflow, and `examples/http-server.ps1`.
- Milestone M1 (protocol core, stdio, tools): the stateless 2026-07-28 lifecycle with `server/discover`,
  per-request `_meta` validation (`-32602`, `-32022` with the supported versions), `tools/list` with cursor
  pagination and caching hints, `tools/call` with JSON Schema validation of the arguments, typed parameter
  binding, result shaping (text, JSON, `structuredContent`, `isError`), `outputSchema` checks,
  `notifications/progress`, `notifications/message` on request and `notifications/cancelled`; handlers run in
  a hostless runspace pool with per-request cancellation tokens and an optional server-side timeout.
- Server commands `New-McpServer`, `Register-McpTool` (functions, cmdlets, script files and script blocks;
  schemas from parameters, validation attributes, comment-based help and defaults), `Start-McpServer`,
  `Stop-McpServer`, `Invoke-McpToolHandler`; handler commands `New-McpContent`, `New-McpToolResult`,
  `Write-McpProgress`, `Write-McpLog`, `Test-McpClientCapability`.
- Client commands `Connect-McpServer` (stdio server processes with captured stderr, or a server object over an
  in-memory transport), `Disconnect-McpServer`, `Get-McpServerInfo`, `Get-McpTool`, `Invoke-McpTool` with
  progress callbacks, log notifications, timeouts and cancellation; format views for the result objects.
- A System.Text.Json codec that keeps wire shapes (ordered, case-sensitive objects, arrays never unrolled,
  request id types preserved), JSON Schema 2020-12 validation through the bundled JsonSchema.Net with a
  PowerShell fallback validator, `McpProtocolException` as a type accelerator, `examples/echo-server.ps1`,
  and a `Format` build task (Invoke-Formatter).
- Milestone M0 (foundation): the `ModelContextProtocol` module skeleton (PowerShell 7.4+, Core edition only,
  no runtime dependencies), assembled from `src/` with ModuleBuilder; engine enums `McpEra` and
  `McpLoggingLevel` exported through type accelerators.
- Build tooling: `build.ps1` (dependency bootstrap from the PowerShell Gallery with NuGet.org and offline
  fallbacks) and Invoke-Build tasks `Clean`, `Build`, `Analyze`, `Test`, `Coverage`, `Help`, `Package`,
  `PublishLocal`, `Publish`, `CI`.
- PSScriptAnalyzer settings with formatting rules and the custom rules `Measure-McpStdoutPurity`
  (nothing but the transport writer may touch stdout or the host) and `Measure-McpNoInvokeExpression`.
- Pester 6 test skeleton: unit, integration (fresh `pwsh` process import must be silent), specification
  (vendored schemas) and compatibility tests (Windows PowerShell 5.1 import guard, pinned version matrix).
- Vendored specification schemas (`schema.json` and `schema.ts`) for revisions 2026-07-28, 2025-11-25 and
  2025-06-18 with a provenance manifest, a definition checklist and `tools/Update-SpecSchemas.ps1`.
- GitHub Actions: CI matrix (ubuntu, windows, macOS × PowerShell 7.4.20, 7.5.11, 7.6.6 installed from pinned
  release assets), lint, 5.1 guard, packaging with a local-repository publish check; release workflow with
  dry run and gated PowerShell Gallery publish; label sync; issue and pull request templates; Dependabot.
- Governance: roadmap, dependency and support policy, security policy, contributing guide, code of conduct,
  conformance baseline file, documentation skeleton.

### Fixed

- A request id can be reused as soon as its response was sent; before, a request that arrived while the
  previous request with the same id was still winding down in its worker was rejected with `-32600`.
- `Connect-McpServer -Server` fails at once for a server object that is already running, instead of waiting
  for the `server/discover` timeout.
- `build.ps1 -Bootstrap` reports why a dependency could not be installed instead of failing with a strict-mode
  error about the missing `Optional` key.
- Script block tools whose names differ only in characters outside `A-Z`, `a-z`, `0-9` and `_` (for example
  `a-b` and `a_b`) no longer share one worker function.
- The `Analyze` build task no longer fails or hangs on PSScriptAnalyzer's sporadic rule failures: every path is
  analysed in a fresh process with a timeout, and files on which a rule failed are re-analysed in further fresh
  processes.

