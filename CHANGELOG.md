# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Until 1.0.0 the public API is not stable; see
[ROADMAP.md](ROADMAP.md) for the milestone plan and [DEPENDENCY_POLICY.md](DEPENDENCY_POLICY.md) for the
support, dependency and breaking-change policy.

## [Unreleased]

### Added

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
