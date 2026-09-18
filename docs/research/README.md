# Research material for the implementation plan

Secondary material produced on 2026-09-16/17 while writing `docs/implementation-plan.md`.
The normative source remains the specification at https://modelcontextprotocol.io/specification/2026-07-28
(`schema.ts` in https://github.com/modelcontextprotocol/modelcontextprotocol, folder `schema/2026-07-28/`).
Nothing in this directory is authoritative; when it disagrees with the specification, the specification wins.

## spec-digest/

One JSON file per extraction section. Each was produced by an automated extraction agent that read the
listed local copies of the specification pages (downloaded as Markdown from modelcontextprotocol.io),
`schema.ts`/`schema.json`, the extension pages (`ext-tasks`, `ext-apps`, `ext-auth`, `ext-skills`),
the developer docs and the conformance framework README, plus five platform-research sections on
PowerShell 7.4-7.6 (concurrency/stdio, HTTP hosting and client, JSON and JSON Schema, module engineering,
competitive landscape). Common shape:

| Field | Meaning |
|---|---|
| `source` | pages/files that were read |
| `summary` | dense summary |
| `methods[]` | JSON-RPC methods/notifications with params, result, capability gate |
| `requirements[]` | MUST/SHOULD/MAY statements with actor and citation |
| `wire_details[]` | exact constants: headers, status codes, error codes, `_meta` keys, enums |
| `sdk_implications[]` | concrete consequences for the SDK design |
| `legacy_delta[]` | differences vs 2025-11-25 / 2025-06-18 (dual-era) |
| `open_questions[]` | items to verify by experiment during implementation |

Claims in the platform-research sections marked `[VERIFY]` rest on expert knowledge and must be
confirmed by the experiments listed in milestone M1 of the plan.

## conformance_alpha_scenarios.txt

Output of `npx @modelcontextprotocol/conformance@0.2.0-alpha.11 list` on 2026-09-16. The stable
release 0.1.16 does not know the 2026-07-28 revision; the alpha channel does (69 required scenarios:
37 server, 32 client) and is the version pinned by the plan.
