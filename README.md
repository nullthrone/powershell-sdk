# ModelContextProtocol (PowerShell SDK)

PowerShell SDK for building and consuming [Model Context Protocol](https://modelcontextprotocol.io) servers
and clients, targeting specification revision **2026-07-28** with dual-era support for 2025-11-25 and
2025-06-18.

> **Status: milestone M0 (foundation).** The module is a buildable, analysed and tested skeleton without
> protocol functionality. The milestones are in [ROADMAP.md](ROADMAP.md); the design is in
> [docs/implementation-plan.md](docs/implementation-plan.md).

## Requirements

- PowerShell 7.4 or later on Windows, Linux or macOS (7.4 LTS, 7.5 and 7.6 LTS are tested in CI).
- `CompatiblePSEditions = Core`; Windows PowerShell 5.1 is not supported and refuses to import the module.
- No runtime dependencies: a pure script module that only uses assemblies shipped with PowerShell.

## Building from source

```powershell
git clone https://github.com/nullthrone/powershell-sdk.git
cd powershell-sdk
./build.ps1 -Bootstrap        # installs Pester, PSScriptAnalyzer, ModuleBuilder, InvokeBuild, PlatyPS
./build.ps1 -Task CI          # Analyze, Test, Package, PublishLocal
Import-Module ./output/ModelContextProtocol/0.1.0/ModelContextProtocol.psd1
```

[CONTRIBUTING.md](CONTRIBUTING.md) describes the development workflow, the repository layout and the coding
conventions; [docs/development.md](docs/development.md) has the details of the build and test tooling.

## Design in brief

- **Pure PowerShell.** One script module assembled from `src/` with ModuleBuilder; engine classes are internal
  and exported through type accelerators, the public API consists of functions with the noun prefix `Mcp`.
- **Stateless 2026-07-28 core, isolated legacy layer.** `server/discover`, per-request `_meta`, MRTR input
  requests and `subscriptions/listen` in the core; `initialize`-based sessions of 2025-11-25 / 2025-06-18 in a
  separate legacy component that shares the same endpoint and process.
- **Transports.** stdio (raw UTF-8 streams, nothing but protocol messages on stdout) and Streamable HTTP on
  `System.Net.HttpListener` with an SSE writer; an in-memory transport for tests.
- **Conformance first.** The official conformance suite runs in CI from milestone M2 against a baseline that
  may only shrink; 1.0.0 requires an empty baseline for the 2026-07-28 and 2025-11-25 requirement sets.

## Repository

| Path | Purpose |
|---|---|
| `src/` | Module sources and manifest |
| `tests/` | Pester tests (unit, integration, spec, compat; conformance from M2) |
| `tools/` | Custom PSScriptAnalyzer rules, maintenance scripts, offline package drop folder |
| `docs/` | Concept documentation, implementation plan, research material |
| `.github/` | CI matrix, release workflow, label sync, issue templates |

Governance: [ROADMAP.md](ROADMAP.md), [DEPENDENCY_POLICY.md](DEPENDENCY_POLICY.md),
[SECURITY.md](SECURITY.md), [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), [CHANGELOG.md](CHANGELOG.md).

License: MIT.
