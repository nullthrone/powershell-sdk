# tools/

| Path | Purpose |
|---|---|
| `ScriptAnalyzerRules/McpAnalyzerRules.psm1` | Custom PSScriptAnalyzer rules (`Measure-McpStdoutPurity`, `Measure-McpNoInvokeExpression`), loaded by the `Analyze` task and tested in `tests/Unit/ScriptAnalyzerRules.Tests.ps1`. |
| `Update-SpecSchemas.ps1` | Refreshes the vendored specification schemas in `tests/Spec/` from a pinned commit of the specification repository and regenerates the provenance manifest and the definition checklist. |
| `Get-ChangelogSection.ps1` | Extracts the section of `CHANGELOG.md` for a version (used by the release workflow for the release notes). |
| `packages/` | Drop folder for offline dependency packages (`.nupkg`, ignored by git). |

## Offline dependency bootstrap

Environments without access to the PowerShell Gallery can still build and test:

1. On a machine with Gallery access, download the packages declared in `requirements.psd1`:

   ```powershell
   Save-PSResource -Name Pester, PSScriptAnalyzer, ModuleBuilder, InvokeBuild, Microsoft.PowerShell.PlatyPS -Repository PSGallery -AsNupkg -Path ./tools/packages -TrustRepository
   ```

2. Copy `tools/packages/*.nupkg` to the restricted machine and run

   ```powershell
   ./build.ps1 -Bootstrap -DependencySource Offline
   ```

`./build.ps1 -Bootstrap` (source `Auto`) tries the Gallery first, then `api.nuget.org` for Pester and
Invoke-Build (which are published there in Chocolatey layout and are unpacked accordingly), then this folder.
