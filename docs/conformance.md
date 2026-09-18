# Conformance

The SDK is measured with the official suite `@modelcontextprotocol/conformance`. The npm `latest` dist-tag
(0.1.x) does not know revision 2026-07-28; the version pinned in `requirements.psd1` (alpha channel) does.
Conformance fixtures (`tests/Conformance/everything-server.ps1`, `everything-client.ps1`) and the CI workflow
`conformance.yml` arrive with milestone M2; this page documents the mechanics they will use.

## Requirement sets

| Requirement set | Server scenarios | Client scenarios | Wire |
|---|---|---|---|
| `2026-07-28` | 37 | 32 | stateless, per-request `_meta` |
| `2025-11-25` | 30 | 18 | stateful `initialize` handshake |

Each set is scored only at its own wire, so the server is run twice (a modern-only instance and a legacy or
dual-era instance) and the client is invoked with `--requirements` for each set. Scenarios classified as
`extension`, `added-after-release` or `pending` run but never affect the score.

## Commands (from M2)

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
