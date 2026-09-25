# Conformance

The SDK is measured with the official suite `@modelcontextprotocol/conformance`. The npm `latest` dist-tag
(0.1.x) does not know revision 2026-07-28; the version pinned in `requirements.psd1` (alpha channel) does.
The fixtures live in `tests/Conformance/` (`everything-server.ps1`, a dual-era Streamable HTTP server with
every tool, resource, prompt and completion the server scenarios of both requirement sets call;
`everything-client.ps1`, a client that detects the era of the scenario server, discovers or initializes,
lists and calls tools, answers input requests and the requests of legacy servers with fixed callbacks (form
content from the schema defaults), and reads resources and renders prompts when the server declares them, as
the client scenarios expect), the build task `Conformance` runs both legs of both requirement sets, and
`.github/workflows/conformance.yml` runs them on every push and pull request.

## Running the suite

```powershell
./build.ps1 -Task Conformance                                    # both legs, requirement sets 2026-07-28 and 2025-11-25
./build.ps1 -Task Conformance -ConformanceRequirements 2025-11-25 # one requirement set
./build.ps1 -Task Conformance -ConformanceLeg Server              # one leg
./build.ps1 -Task Conformance -ConformanceScenario tools-list     # one scenario (both legs try it)
```

Node.js 20 or later is required (`npx` runs the pinned package). The task builds the module, starts the
dual-era fixture server (`-Era Dual`) on a free loopback port with `MCP_MODULE_MANIFEST` pointing at the
build, waits for the port, runs the server leg, stops the fixture, then runs the client leg with the fixture
client; this for each requirement set. Results
(`checks.json` per scenario, the fixture server log) are written to `output/conformance/`. The task fails
when a leg exits with a non-zero code: an unexpected failure or a stale baseline entry.

## State after milestone M5

Requirement set `2026-07-28`, server leg, against the dual-era fixture: every scenario of the requirement set
passes and the server baseline is empty. That covers `server-stateless` (among its checks the
`subscriptions/listen` checks and `initialize` with the per-request `_meta` answered as a removed method,
404 and `-32601`), the fourteen `input-required-result-*` scenarios, `tools-list`, the seven `tools-call-*`
scenarios, the `resources-*`, `prompts-*`, `completion-complete`, `caching`, `sep-2164-resource-not-found`,
`dns-rebinding-protection` and `server-sse-multiple-streams` scenarios, each including the `wire-schema-valid`
check of every message against the 2026-07-28 schema; the not-scored `json-schema-2020-12`,
`http-header-validation` and `http-custom-header-server-validation` pass too. The `tasks-*` scenarios are
extensions (milestone M7) and do not affect the score.

Requirement set `2025-11-25`, server leg, against the same fixture: all 30 scored scenarios pass
(`server-initialize`, `logging-set-level`, `ping`, `tools-call-with-logging`, `tools-call-sampling`,
`tools-call-elicitation`, `elicitation-sep1034-defaults`, `elicitation-sep1330-enums`, `resources-subscribe`,
`resources-unsubscribe`, `server-sse-multiple-streams` and the scenarios shared with 2026-07-28 at the legacy
wire), and so does the not-scored `server-session-lifecycle` (DELETE ends the session, a later request gets
404). `server-sse-polling` is pending in the suite; it reports that the server answers `test_reconnection`
without closing the stream (the server does not implement SSE resumability).

Client leg, `2026-07-28`: `tools_call`, `request-metadata`, `sep-2322-client-request-state`,
`auth/resource-mismatch`, `http-standard-headers`, `http-custom-headers`, `http-invalid-tool-headers`,
`json-schema-ref-no-deref` and the not-scored `json-schema-2020-12-preservation` pass. Client leg,
`2025-11-25`: `initialize`, `tools_call`, `elicitation-sep1034-client-defaults` (the elicitation request
arrives on the GET stream) and `sse-retry` (GET with `Last-Event-ID` after the announced retry time) pass. The
remaining entries of `conformance-baseline.yml` are the authorization scenarios of milestone M6, which belong
to both requirement sets (14 of the 18 scored client scenarios of 2025-11-25).

The suite starts the client scenarios of a requirement set at the same time; `sse-retry` checks the
reconnection delay with a tolerance of +200 ms, so a heavily loaded machine can make it flaky. The client
reads the GET stream of a legacy session on the caller's thread (no background runspace) to keep its own
share of that load small.

## Requirement sets

| Requirement set | Server scenarios | Client scenarios | Wire |
|---|---|---|---|
| `2026-07-28` | 37 | 32 | stateless, per-request `_meta` |
| `2025-11-25` | 30 | 18 | stateful `initialize` handshake |

Each set is scored only at its own wire: the server leg runs both sets against the dual-era fixture (started
fresh for each set), and the client is invoked with `--requirements` for each set. Scenarios classified as
`extension`, `added-after-release` or `pending` run but never affect the score.

## Commands behind the task

```bash
npx --yes @modelcontextprotocol/conformance@<pinned> server --url http://127.0.0.1:3001/mcp --requirements 2026-07-28 --expected-failures conformance-baseline.yml
npx --yes @modelcontextprotocol/conformance@<pinned> server --url http://127.0.0.1:3001/mcp --requirements 2025-11-25 --expected-failures conformance-baseline.yml
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
