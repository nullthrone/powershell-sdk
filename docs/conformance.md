# Conformance

The SDK is measured with the official suite `@modelcontextprotocol/conformance`. The npm `latest` dist-tag
(0.1.x) does not know revision 2026-07-28; the version pinned in `requirements.psd1` (alpha channel) does.
The fixtures live in `tests/Conformance/` (`everything-server.ps1`, a Streamable HTTP server with every tool
the server scenarios call; `everything-client.ps1`, a client that discovers, lists and calls tools as the
client scenarios expect), the build task `Conformance` runs both legs, and `.github/workflows/conformance.yml`
runs them on every push and pull request.

## Running the suite

```powershell
./build.ps1 -Task Conformance                                    # both legs, requirement set 2026-07-28
./build.ps1 -Task Conformance -ConformanceLeg Server              # one leg
./build.ps1 -Task Conformance -ConformanceScenario tools-list     # one scenario (both legs try it)
```

Node.js 20 or later is required (`npx` runs the pinned package). The task builds the module, starts the
fixture server on a free loopback port with `MCP_MODULE_MANIFEST` pointing at the build, waits for the port,
runs the server leg, stops the fixture, then runs the client leg with the fixture client. Results
(`checks.json` per scenario, the fixture server log) are written to `output/conformance/`. The task fails
when a leg exits with a non-zero code: an unexpected failure or a stale baseline entry.

## State after milestone M2

Requirement set `2026-07-28`, server leg: `server-stateless` (25 checks), `tools-list`, the seven
`tools-call-*` scenarios, `sep-2164-resource-not-found`, `dns-rebinding-protection` and
`server-sse-multiple-streams` pass; the not-scored `json-schema-2020-12`, `http-header-validation` and
`http-custom-header-server-validation` pass too. Client leg: `tools_call`, `request-metadata`,
`auth/resource-mismatch`, `http-standard-headers`, `http-custom-headers`, `http-invalid-tool-headers`,
`json-schema-ref-no-deref` and the not-scored `json-schema-2020-12-preservation` pass. Everything else is in
`conformance-baseline.yml`, grouped by the milestone that removes it.

## Requirement sets

| Requirement set | Server scenarios | Client scenarios | Wire |
|---|---|---|---|
| `2026-07-28` | 37 | 32 | stateless, per-request `_meta` |
| `2025-11-25` | 30 | 18 | stateful `initialize` handshake |

Each set is scored only at its own wire, so the server is run twice (a modern-only instance and a legacy or
dual-era instance) and the client is invoked with `--requirements` for each set. Scenarios classified as
`extension`, `added-after-release` or `pending` run but never affect the score.

## Commands behind the task

```bash
npx --yes @modelcontextprotocol/conformance@<pinned> server --url http://127.0.0.1:3001/mcp --requirements 2026-07-28 --expected-failures conformance-baseline.yml
npx --yes @modelcontextprotocol/conformance@<pinned> server --url http://127.0.0.1:3002/mcp --requirements 2025-11-25 --expected-failures conformance-baseline.yml
npx --yes @modelcontextprotocol/conformance@<pinned> client --command "pwsh -NoProfile -NonInteractive -File tests/Conformance/everything-client.ps1" --requirements 2026-07-28 --expected-failures conformance-baseline.yml
npx --yes @modelcontextprotocol/conformance@<pinned> client --command "pwsh -NoProfile -NonInteractive -File tests/Conformance/everything-client.ps1" --requirements 2025-11-25 --expected-failures conformance-baseline.yml
```

The harness appends the fixture server URL as the last argument of the client command and sets
`MCP_CONFORMANCE_SCENARIO`, `MCP_CONFORMANCE_CONTEXT` (JSON) and `MCP_CONFORMANCE_PROTOCOL_VERSION`.

## Baseline

`conformance-baseline.yml` has the keys `server:` and `client:`, each a list of scenario names or
`<scenario>:<check-id>` entries (no whitespace around the colon). Exit codes of the suite:

| Scenario result | In baseline | Exit code |
|---|---|---|
| fail | yes | 0 |
| fail | no | 1 |
| pass | yes | 1 (stale entry, remove it) |
| pass | no | 0 |

The baseline may only shrink. Version 1.0.0 requires empty lists for both requirement sets.

## Wire-schema checks

Every message the suite observes is validated against the revision's `schema.json` (`wire-schema-valid`).
The vendored copies under `tests/Spec/` are the same schemas; the SDK's serializer omits absent optional
fields (never `null`) and preserves JSON-RPC `id` types so that these checks pass independently of the
scenario logic.
