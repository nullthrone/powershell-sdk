# Development

## Toolchain

| Tool | Use | Installed by |
|---|---|---|
| PowerShell 7.4+ | runtime and build host | you (see [DEPENDENCY_POLICY.md](../DEPENDENCY_POLICY.md) for the version table) |
| InvokeBuild | task runner (`ModelContextProtocol.build.ps1`) | `./build.ps1 -Bootstrap` |
| ModuleBuilder (with Configuration and Metadata) | assembles `src/` into one `.psm1` | `./build.ps1 -Bootstrap` |
| PSScriptAnalyzer | static analysis, formatting, custom rules | `./build.ps1 -Bootstrap` |
| Pester 6 | tests | `./build.ps1 -Bootstrap` |
| Microsoft.PowerShell.PlatyPS | help generation (optional locally) | `./build.ps1 -Bootstrap` |
| Node.js 20+ | conformance suite and Inspector (from M2) | you |

`build.ps1` verifies the declared version ranges (`requirements.psd1`) on every run and installs missing
dependencies only with `-Bootstrap`. Sources are tried in the order PowerShell Gallery, `api.nuget.org`
(Pester and Invoke-Build are published there in Chocolatey layout, which the bootstrap unpacks), and the
offline folder `tools/packages/` (`-DependencySource Offline`).

## Tasks

| Task | Does |
|---|---|
| `Clean` | removes `output/` |
| `Build` | ModuleBuilder: `src/{Enums,Classes,Private,Public}` in file-name order + `Suffix.ps1` → `output/ModelContextProtocol/<version>/ModelContextProtocol.psm1`; copies `en-US/`, `Types/`, `Formats/`, `LICENSE`; sets version and prerelease from `-SemVer` (default: manifest) |
| `Analyze` | PSScriptAnalyzer over `src`, `tests`, `tools` and the build scripts with `PSScriptAnalyzerSettings.psd1` and the custom rules; any finding fails the task |
| `Test` | `Build`, then Pester over `tests/Unit`, `tests/Integration`, `tests/Spec`, `tests/Compat` against the built module; NUnit XML under `output/test-results/`; `-TestTag`/`-ExcludeTestTag` filter, `-CodeCoverage` adds JaCoCo under `output/coverage/` |
| `Coverage` | `Test` with coverage enabled |
| `Help` | PlatyPS markdown under `docs/help/` and MAML in the built module (no-op while the module exports nothing) |
| `Package` | `Build`, then `Compress-PSResource` → `output/packages/ModelContextProtocol.<version>.nupkg` |
| `PublishLocal` | `Build`, then `Publish-PSResource` to a file-share repository under `output/local-repository/`, `Find-PSResource`, `Save-PSResource` and an import in a fresh process: the release dry run |
| `Publish` | `Publish-PSResource` to the PowerShell Gallery with `PSGALLERY_API_KEY` |
| `Conformance` | conformance suite (from M2) |
| `CI` | `Analyze`, `Test`, `Package`, `PublishLocal` |

## Tests

Tests always run against the built module (`$env:MCP_MODULE_MANIFEST`, set by the `Test` task; otherwise
the newest build under `output/`). `tests/Support/McpTestSupport.psm1` provides the helpers (repository root,
built manifest, vendored schema access, a child-process runner with UTF-8 streams).

| Folder | Scope | Notes |
|---|---|---|
| `tests/Unit` | manifest, import behaviour, type accelerators, enums against the schema, custom analyzer rules | in-process |
| `tests/Integration` | fresh `pwsh` processes: import must be silent on stdout and stderr, also under `-File` | spawns processes |
| `tests/Spec` | vendored schemas: hashes, definition counts, JSON-RPC envelope, checklist | data-driven |
| `tests/Compat` | Windows PowerShell 5.1 guard (skipped off Windows), pinned version matrix (`MCP_EXPECTED_PWSH_VERSION`) | tags `PS51Guard`, `VersionMatrix` |

## CI

`.github/workflows/ci.yml` runs `lint` (ubuntu, PowerShell 7.4), the `test` matrix (ubuntu, windows, macOS ×
PowerShell 7.4.20, 7.5.11, 7.6.6), `ps51-guard` (windows) and `package` (ubuntu; `Package` + `PublishLocal`,
uploads the `.nupkg`). The composite action `.github/actions/install-pwsh` downloads the pinned PowerShell
release asset and prepends it to `PATH`, so every `shell: pwsh` step runs the pinned version; the
`VersionMatrix` test asserts it. All actions are pinned to commit SHAs (Dependabot keeps them current).

The `lint` job also queries the PowerShell Gallery for the module names `ModelContextProtocol` and
`ModelContextProtocol.Sdk` and writes the result to the job summary (the Gallery may be unreachable from
development sandboxes).

## Release

`.github/workflows/release.yml` runs on tags `v<semver>` and on manual dispatch: it reuses the CI workflow,
checks that the tag matches the manifest version, packages the module, performs the local-repository dry
run, uploads the `.nupkg`, drafts a GitHub release with the changelog section
(`tools/Get-ChangelogSection.ps1`), and publishes to the PowerShell Gallery only when the repository variable
`PSGALLERY_PUBLISH_ENABLED` is `true` and the `psgallery` environment holds `PSGALLERY_API_KEY`.

## Restricted environments

Without access to the PowerShell Gallery, `./build.ps1 -Bootstrap` falls back to `api.nuget.org` for Pester
and Invoke-Build. PSScriptAnalyzer, ModuleBuilder (with Configuration and Metadata) and PlatyPS are not
published there; put their `.nupkg` files into `tools/packages/` (see `tools/README.md`) or install them from
another source. The `Help` task skips itself when PlatyPS is missing.
