# Documentation

| Document | Content |
|---|---|
| [implementation-plan.md](implementation-plan.md) | The design: decisions, architecture, public API, protocol coverage matrix, milestones, test strategy (German) |
| [development.md](development.md) | Build, analysis, tests, packaging, CI and release mechanics |
| [conformance.md](conformance.md) | How the MCP conformance suite is run and how the baseline works |
| [concepts/transports.md](concepts/transports.md) | stdio and Streamable HTTP: framing, stdout hygiene, header validation |
| [concepts/server-primitives.md](concepts/server-primitives.md) | Tools, resources, templates, prompts and completion: handler contract, errors, caching, pagination |
| [concepts/dual-era.md](concepts/dual-era.md) | Serving 2026-07-28 and the legacy revisions side by side |
| [concepts/mrtr.md](concepts/mrtr.md) | Multi-round-trip requests: elicitation, sampling and roots as input requests |
| [concepts/authorization.md](concepts/authorization.md) | OAuth client flows and server-side bearer validation |
| `help/` | Generated command reference (PlatyPS markdown; produced by `./build.ps1 -Task Help` from milestone M1) |
| [research/](research/README.md) | Secondary material the plan was written from (specification extractions, platform research) |

The concept pages are written at the level of the design and are completed as the milestones land; each page
states the milestone that implements it.
