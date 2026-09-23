# Roadmap

This roadmap tracks the implementation of the Model Context Protocol specification, revision **2026-07-28**
(with dual-era support for 2025-11-25 and 2025-06-18), in the `ModelContextProtocol` PowerShell module. It is
the published roadmap required by the [SDK tiering policy](https://modelcontextprotocol.io/community/sdk-tiers)
and is updated at the end of every milestone. The detailed design is in
[docs/implementation-plan.md](docs/implementation-plan.md).

Conformance is measured with `@modelcontextprotocol/conformance` (version pinned in `requirements.psd1`)
against the requirement sets `2026-07-28` (37 server + 32 client scenarios) and `2025-11-25` (30 server +
18 client scenarios). `conformance-baseline.yml` lists the expected failures and may only shrink. Version
1.0.0 is the first release with an empty baseline for both requirement sets.

## Milestones

| Milestone | Scope | Exit criterion | Status |
|---|---|---|---|
| **M0 Foundation** | Toolchain, module skeleton, ModuleBuilder build, analyzer rules, Pester skeleton, vendored schemas, CI matrix, release dry run, governance documents | CI green on all matrix cells with the empty module; side-effect-free import; publishing to a local repository works | Done |
| **M1 Protocol core, stdio, tools (modern)** | System.Text.Json codec, JSON-RPC model, `_meta` validation, error codes, router, `server/discover`, capabilities, extension registry, in-memory transport, dispatcher and runspace pool, stdio server and client transports, `tools/list`, `tools/call` (text), schema generator and validator, progress, cancellation | Unit and integration tests green; Inspector CLI `tools/list` against `examples/echo-server.ps1`; startup and per-request overhead measured | Done |
| **M2 Streamable HTTP (modern)** | HttpListener host, header validation, Origin allowlist, JSON/SSE selection, keep-alive, disconnect → cancel; client HTTP transport with SSE parser; conformance fixtures and workflow | Conformance 2026-07-28: `server-stateless`, `tools-list`, `tools-call-simple-text/-error/-with-progress`, `dns-rebinding-protection`, `http-header-validation`, `http-custom-header-server-validation`; client `tools_call`, `request-metadata`, `http-*`, `json-schema-ref-no-deref`; first `0.1.0-preview` on the PowerShell Gallery | Done (the Gallery preview is published from the release workflow by tagging `v0.1.0-preview1`) |
| **M3 Server primitives** | Resources (static, file, templates, blob), prompts, completion, pagination, caching fields, all content types, `structuredContent`/`outputSchema`, icons, annotations, `notifications/message`; client counterparts with TTL cache | `tools-call-image/-audio/-embedded-resource/-mixed-content`, `json-schema-2020-12`, `resources-*`, `sep-2164-resource-not-found`, `prompts-*`, `completion-complete`, `caching`; client `json-schema-2020-12-preservation` | Done |
| **M4 MRTR and subscriptions** | Input-required machinery with signed `requestState`, capability gating, elicitation validator, sampling and roots as input requests, client retry loop; `subscriptions/listen` on server and client | All 14 `input-required-result-*`, `server-sse-multiple-streams`; client `sep-2322-client-request-state` | Planned |
| **M5 Dual era** | Legacy session (`initialize`, `ping`, `logging/setLevel`, `resources/subscribe`, server-initiated requests, HTTP sessions, GET SSE, DELETE), era-aware serialization, client legacy lifecycle | `--requirements 2025-11-25`: server 30/30, client 18/18; 2026-07-28 still green on the dual-era instance | Planned |
| **M6 Authorization** | Client OAuth provider (discovery, PKCE, resource indicators, `iss`, CIMD/DCR/pre-registered clients, scope step-up, token store); server bearer middleware and protected-resource metadata | All client `auth/*` scenarios of the 2026-07-28 requirement set | Planned |
| **M7 Extensions** | Tasks, Skills, Apps (server side), OAuth client credentials, enterprise-managed authorization | `tasks-*` (10), `auth/client-credentials-*`, `auth/enterprise-managed-authorization` | Planned |
| **M8 Developer experience and 1.0** | Discovery styles, launcher and client-configuration helpers, scaffolder, examples, PlatyPS help, concept documentation, performance pass | Empty baseline for both requirement sets; PowerShell Gallery release 1.0.0 | Planned |

## Protocol coverage by milestone (2026-07-28 core)

| Area | Milestone |
|---|---|
| `server/discover`, `_meta` validation, error codes `-32020`/`-32021`/`-32022`, capabilities | M1 |
| `tools/list`, `tools/call` | M1 (text), M2 (all content types, structured output; the `tools-call-*` scenarios pass) |
| stdio transport (server and client) | M1 |
| Streamable HTTP (server and client), header validation, Origin protection | M2 |
| `resources/*`, `prompts/*`, `completion/complete`, caching (`ttlMs`, `cacheScope`), pagination | M3 |
| `notifications/progress`, `notifications/cancelled`, `notifications/message` (including handler streams) | M1 / M3 |
| MRTR: `elicitation/create`, `sampling/createMessage`, `roots/list` as input requests | M4 |
| `subscriptions/listen`, list-changed and resource-updated notifications | M4 |
| Legacy revisions 2025-11-25 and 2025-06-18 (both roles) | M5 |
| Authorization (client flows, server bearer validation) | M6 |
| Extensions: Tasks, Skills, Apps (server), authorization extensions | M7 |

Out of scope: Windows PowerShell 5.1, an Apps host, the 2024-11-05 HTTP+SSE transport as a server, an
authorization server, the experimental 2025-11-25 Tasks API.

## Support policy

See [DEPENDENCY_POLICY.md](DEPENDENCY_POLICY.md) for the PowerShell version floor (7.4 today; 7.6 after 7.4 and
7.5 reach end of support on 2026-11-10), dependency pinning and the breaking-change policy.
