# tests/Spec

Vendored copies of the Model Context Protocol schemas (`schema.json` and `schema.ts`) for the revisions the
SDK supports, taken from <https://github.com/modelcontextprotocol/modelcontextprotocol> at the commit recorded
in `manifest.json`. The specification is the normative source; these copies exist so that tests can validate
wire objects and derive expectations (enum members, definition lists) offline and reproducibly.

| File | Content |
|---|---|
| `<revision>_schema.json` | JSON Schema of the revision (2020-12 for 2026-07-28 and 2025-11-25, draft-07 for 2025-06-18) |
| `<revision>_schema.ts` | TypeScript source the JSON Schema is generated from (for reference and doc comments) |
| `manifest.json` | Provenance: upstream commit, retrieval date, SHA-256 and definition count per file |
| `definitions-checklist.txt` | Every definition of the primary revision (2026-07-28), one per line, ordinally sorted; the type-model tests require a constructor and a parser test per entry |
| `Schema.Tests.ps1` | Verifies hashes, definition counts, dialects, the JSON-RPC envelope and the checklist |

Refresh with a pinned commit:

```powershell
./tools/Update-SpecSchemas.ps1 -Commit <40-character SHA>
```
