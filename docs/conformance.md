# Conformance

The SDK is measured with the official suite `@modelcontextprotocol/conformance`. The npm `latest` dist-tag
(0.1.x) does not know revision 2026-07-28; the version pinned in `requirements.psd1` (alpha channel) does.
The fixtures live in `tests/Conformance/` (`everything-server.ps1`, a Streamable HTTP server with every tool,
resource, prompt and completion the server scenarios call; `everything-client.ps1`, a client that discovers,
lists and calls tools, answers input requests with fixed callbacks, and reads resources and renders prompts
when the server declares them, as the client scenarios expect), the build task `Conformance` runs both legs, and `.github/workflows/conformance.yml`
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

## State after milestone M4

Requirement set `2026-07-28`, server leg: every scenario of the requirement set passes and the server
baseline is empty. That covers `server-stateless` (30 checks, among them the `subscriptions/listen` checks:
acknowledgement first, the subscription id on every notification, a strictly honoured filter, and tools and
prompts list changes triggered by the fixture tools `test_trigger_tool_change` and
`test_trigger_prompt_change`), the fourteen `input-required-result-*` scenarios (elicitation, sampling and
roots input requests, answers accumulated over several rounds in the signed `requestState`, a tampered
state rejected before any other validation, input requests gated by the client capabilities, prompts and
resources as well as tools), `tools-list`, the seven `tools-call-*` scenarios, the `resources-*`,
`prompts-*`, `completion-complete`, `caching`, `sep-2164-resource-not-found`, `dns-rebinding-protection`
and `server-sse-multiple-streams` scenarios, each including the `wire-schema-valid` check of every message
against the 2026-07-28 schema; the not-scored `json-schema-2020-12`, `http-header-validation` and
`http-custom-header-server-validation` pass too. The `tasks-*` scenarios are extensions (milestone M7) and
do not affect the score.

Client leg: `tools_call`, `request-metadata`, `sep-2322-client-request-state` (the state echoed verbatim,
a new request id per round, no state when the server sent none, no MRTR parameters on unrelated calls, a
missing `resultType` read as `complete`), `auth/resource-mismatch`, `http-standard-headers`,
`http-custom-headers`, `http-invalid-tool-headers`, `json-schema-ref-no-deref` and the not-scored
`json-schema-2020-12-preservation` pass. The remaining entries of `conformance-baseline.yml` are the
authorization scenarios of milestone M6.

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
