# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Until 1.0.0 the public API is not stable; see
[ROADMAP.md](ROADMAP.md) for the milestone plan and [DEPENDENCY_POLICY.md](DEPENDENCY_POLICY.md) for the
support, dependency and breaking-change policy.

## [Unreleased]

### Added

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
