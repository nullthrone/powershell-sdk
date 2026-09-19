# Contributing

Thank you for helping to build the PowerShell SDK for the Model Context Protocol. This document explains how
the repository is organised, how to build and test it, and the conventions pull requests are expected to
follow. The design is described in [docs/implementation-plan.md](docs/implementation-plan.md).

## Prerequisites

- PowerShell 7.4 or later (7.4, 7.5 and 7.6 are tested in CI). Windows PowerShell 5.1 is not supported.
- Node.js 20 or later with `npx` for the conformance suite and the MCP Inspector (from milestone M2).
- Build and test dependencies are installed by `./build.ps1 -Bootstrap` (see `requirements.psd1`). In
  environments without access to the PowerShell Gallery, drop the `.nupkg` files into `tools/packages/` and
  run `./build.ps1 -Bootstrap -DependencySource Offline` (see `tools/README.md`).

## Repository layout

| Path | Content |
|---|---|
| `src/` | Module sources: `Enums/`, `Classes/` (numbered for deterministic order), `Private/`, `Public/` (one function per file, file name = function name), `Types/`, `Formats/`, `en-US/`, `Suffix.ps1`, `build.psd1` (ModuleBuilder settings) |
| `tests/` | Pester tests: `Unit/`, `Integration/`, `Spec/` (vendored schemas), `Compat/`, `Conformance/` (from M2), `Support/` |
| `tools/` | Custom PSScriptAnalyzer rules, maintenance scripts, offline package drop folder |
| `docs/` | Concept documentation, generated command help, the implementation plan and research material |
| `output/` | Build output (ignored by git) |

## Build, analyse, test

```powershell
./build.ps1 -Bootstrap                 # install build dependencies (once)
./build.ps1                            # Build: assemble output/ModelContextProtocol/<version>/
./build.ps1 -Task Analyze              # PSScriptAnalyzer with the repository settings and custom rules
./build.ps1 -Task Test                 # Build + Pester (unit, integration, spec, compat)
./build.ps1 -Task Test -CodeCoverage   # same, with JaCoCo coverage under output/coverage/
./build.ps1 -Task Package              # Build + .nupkg under output/packages/
./build.ps1 -Task CI                   # Analyze, Test, Package, PublishLocal: what CI runs
./build.ps1 -Task ?                    # list all tasks
```

Tests import the built module, never `src/` directly. Set `MCP_MODULE_MANIFEST` to test a specific build.

## Coding conventions

- Public functions use approved verbs (`Get-Verb`) with the noun prefix `Mcp`, `[CmdletBinding()]`,
  `[OutputType()]` and comment-based help, and never declare a `-ProgressAction` parameter (it is an
  automatic common parameter since 7.4).
- Nothing outside the transport writer writes to stdout or the host: no `Write-Host`, `Out-Host`,
  `Out-Default`, `Read-Host`, `[Console]::Write*`, `[Console]::Out`, `[Console]::OpenStandardOutput`,
  `$Host.UI`. The custom rule `Measure-McpStdoutPurity` enforces this for `src/`; diagnostics belong on
  stderr or in `notifications/message`.
- `Invoke-Expression`, `InvokeCommand.InvokeScript` and `InvokeCommand.ExpandString` are forbidden everywhere
  (`Measure-McpNoInvokeExpression`); `[scriptblock]::Create` is flagged and needs a justified suppression.
- Wire objects are ordered dictionaries that omit absent fields; optional fields are never sent as `null`.
- Engine classes carry `[NoRunspaceAffinity()]` and are exported through type accelerators in `Suffix.ps1`;
  nothing in the public API requires `using module`.
- Sources are UTF-8 without BOM, LF line endings, 4-space indentation, One True Brace Style (`.editorconfig`,
  enforced by the PSScriptAnalyzer formatting rules). `Invoke-Formatter -Settings ./PSScriptAnalyzerSettings.psd1`
  formats a file.
- Module import is side-effect free: no output on any stream, no console changes, no global variables.

## Tests

- Unit tests exercise the built module (`InModuleScope`, `Mock -ModuleName`) and never spawn processes.
- Integration tests spawn real `pwsh` processes and use loopback HTTP; files go to `$TestDrive`.
- Specification tests derive expectations from the vendored `schema.json`; every schema definition receives a
  constructor and a parser test as the type model grows (`tests/Spec/definitions-checklist.txt`).
- Conformance runs (from milestone M2) use the pinned `@modelcontextprotocol/conformance` version and
  `conformance-baseline.yml`; the baseline may only shrink.

## Pull requests

- Branch from `main`; keep pull requests focused on one milestone item.
- Run `./build.ps1 -Task CI` locally before pushing. CI runs the same tasks on ubuntu, windows and macOS with
  pinned PowerShell 7.4, 7.5 and 7.6.
- Add a changelog entry under `## [Unreleased]` in `CHANGELOG.md` for user-visible changes.
- Commit messages: imperative subject line; the body explains why.

## Issue triage and labels

Issues follow the label taxonomy of the MCP SDK tiering guidelines (`.github/labels.json`): one type label
(`bug`, `enhancement`, `question`), one status label (`needs confirmation`, `needs repro`, `ready for work`,
`good first issue`, `help wanted`) and, once actionable, a priority (`P0` to `P3`). `P0` means a security issue
with CVSS 7.0 or higher, or a failure of core MCP operations (connection, message exchange, tools, resources,
prompts). Targets: triage within 2 business days, `P0` fixed within 7 days.

## License

By contributing you agree that your contributions are licensed under the MIT License of this repository.
