# Dependency and Support Policy

This document is the dependency update policy required by the MCP SDK tiering guidelines. It covers the
runtime the module needs, the dependencies used to build and test it, and how both are kept current.

## Runtime

- **Runtime dependencies: none.** `ModelContextProtocol` is a pure PowerShell script module. `RequiredModules`
  and `RequiredAssemblies` in the manifest are empty and stay empty. The module only uses assemblies that ship
  with PowerShell itself (the .NET base class library, `System.Text.Json`, and the `JsonSchema.Net` assembly
  bundled in `$PSHOME`). No third-party DLL is bundled, and no code is compiled at import time.
- Optional integrations (for example a token store backed by `Microsoft.PowerShell.SecretManagement`) are
  adapters that load only when the user opts in; they never appear in `RequiredModules`.

## Supported PowerShell versions

| PowerShell | .NET | Microsoft support ends | Status in this module |
|---|---|---|---|
| 7.4 LTS | 8.0 | 2026-11-10 | Minimum version; tested in CI |
| 7.5 | 9.0 | 2026-11-10 | Tested in CI |
| 7.6 LTS | 10.0 | 2028-11-14 | Tested in CI; intended long-term floor |
| 7.7 preview | 11.0 | — | Best effort (allowed-failure lane once added) |
| Windows PowerShell 5.1 | .NET Framework | — | Not supported; import fails with a clear message |

`CompatiblePSEditions` is `Core` only. The minimum version is raised only when the dropped version is out of
Microsoft support (see the breaking-change policy below). The planned bump to 7.6 ships in the first release
after 2026-11-10 and is announced in the changelog one release in advance.

## Build and test dependencies

Build and test dependencies are declared with NuGet version ranges in [`requirements.psd1`](requirements.psd1)
and installed by `./build.ps1 -Bootstrap`. They are never needed to *use* the module.

| Dependency | Range | Purpose |
|---|---|---|
| Pester | `[6.2.0,7.0)` | Tests |
| PSScriptAnalyzer | `[1.25.0,2.0)` | Static analysis, formatting rules, custom rules |
| ModuleBuilder | `[3.1.0,4.0)` | Assembling `src/` into a single `.psm1` |
| InvokeBuild | `[5.12.0,6.0)` | Task runner |
| Microsoft.PowerShell.PlatyPS | `[1.0.0,2.0)` | Help generation (optional locally, required for releases) |
| `@modelcontextprotocol/conformance` (npm) | exact version | Conformance suite (from milestone M2) |
| `@modelcontextprotocol/inspector` (npm) | exact version | Manual verification (from milestone M1) |

Install sources, in order: the PowerShell Gallery; `api.nuget.org` for the packages that are also published
there (Pester, Invoke-Build); an offline folder `tools/packages/` with `.nupkg` files for restricted
environments. GitHub Actions are pinned to full commit SHAs.

## Update cadence

- **GitHub Actions**: Dependabot opens weekly pull requests (`.github/dependabot.yml`).
- **PowerShell build dependencies**: reviewed monthly and whenever a dependency publishes a security fix.
  Ranges are widened in a dedicated pull request that runs the full CI matrix. Dependabot does not track the
  PowerShell Gallery, so this review is a manual, calendar-driven task.
- **Conformance suite pin**: checked against the `latest` and `alpha` npm dist-tags at every milestone and at
  least monthly; a newer suite version is adopted together with any baseline changes it requires.
- **PowerShell versions in CI**: the pinned patch versions in `.github/workflows/ci.yml` are updated to the
  newest patch release of every supported minor version at least monthly.
- **Specification schemas**: `tests/Spec/` is refreshed with `tools/Update-SpecSchemas.ps1` when the
  specification repository changes a supported revision; the provenance manifest records the upstream commit.

## Security fixes in dependencies

A vulnerability in a build or test dependency is fixed within 7 days of publication. Because the module has
no runtime dependencies, such a vulnerability cannot reach users of the published module. The security policy
for the module itself is in [SECURITY.md](SECURITY.md).

## Versioning and breaking changes

- Releases follow [Semantic Versioning 2.0.0](https://semver.org/). Versions below 1.0.0 use the `0.x`
  series with `previewN` prerelease labels and may change the public API between minor versions.
- From 1.0.0 the public API consists of the exported functions and their parameter sets, the `PSTypeName`
  shapes of returned objects, and the documented wire behaviour. Engine classes exposed through type
  accelerators are internal and are not covered by the compatibility promise.
- Breaking changes to the public API require a new major version. Raising the minimum PowerShell version is a
  breaking change, except when the dropped version has reached end of support at Microsoft; in that case the
  bump may ship in a minor version.
- Published versions on the PowerShell Gallery are immutable. A broken release is followed by a fixed version
  and the broken one is unlisted; nothing is ever re-published under the same version.
