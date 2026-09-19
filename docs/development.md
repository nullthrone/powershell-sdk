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
| Node.js 20+ | conformance suite (`Conformance` task) and Inspector | you |

`build.ps1` verifies the declared version ranges (`requirements.psd1`) on every run and installs missing
dependencies only with `-Bootstrap`. Sources are tried in the order PowerShell Gallery, `api.nuget.org`
(Pester and Invoke-Build are published there in Chocolatey layout, which the bootstrap unpacks), and the
offline folder `tools/packages/` (`-DependencySource Offline`).

## Tasks

| Task | Does |
|---|---|
| `Format` | `Invoke-Formatter` over `src`, `tests`, `tools`, `examples` and the build scripts with the repository settings, in place |
| `Clean` | removes `output/` |
| `Build` | ModuleBuilder: `src/{Enums,Classes,Private,Public}` in file-name order + `Suffix.ps1` → `output/ModelContextProtocol/<version>/ModelContextProtocol.psm1`; copies `en-US/`, `Types/`, `Formats/`, `LICENSE`; sets version and prerelease from `-SemVer` (default: manifest) |
| `Analyze` | PSScriptAnalyzer over `src`, `tests`, `tools`, `examples` and the build scripts with `PSScriptAnalyzerSettings.psd1` and the custom rules; any finding fails the task. Each path is analysed in a fresh `pwsh` process with a timeout (`tools/Invoke-ScriptAnalyzerWorker.ps1`), and files on which a rule failed (PSScriptAnalyzer 1.25 runs its rules in parallel and occasionally loses a command lookup or throws a NullReferenceException) are re-analysed in further fresh processes; retries appear as build warnings |
| `Test` | `Build`, then Pester over `tests/Unit`, `tests/Integration`, `tests/Spec`, `tests/Compat` against the built module; NUnit XML under `output/test-results/`; `-TestTag`/`-ExcludeTestTag` filter, `-CodeCoverage` adds JaCoCo under `output/coverage/` |
| `Coverage` | `Test` with coverage enabled |
| `Help` | PlatyPS markdown under `docs/help/` and MAML in the built module (no-op while the module exports nothing) |
| `Package` | `Build`, then `Compress-PSResource` → `output/packages/ModelContextProtocol.<version>.nupkg` |
| `PublishLocal` | `Build`, then `Publish-PSResource` to a file-share repository under `output/local-repository/`, `Find-PSResource`, `Save-PSResource` and an import in a fresh process: the release dry run |
| `Publish` | `Publish-PSResource` to the PowerShell Gallery with `PSGALLERY_API_KEY` |
| `Conformance` | `Build`, then the server and the client leg of `@modelcontextprotocol/conformance` (pinned in `requirements.psd1`) against `conformance-baseline.yml`; `-ConformanceRequirements`, `-ConformanceLeg`, `-ConformanceScenario`; results under `output/conformance/` (see [conformance.md](conformance.md)) |
| `CI` | `Analyze`, `Test`, `Package`, `PublishLocal` |

## Tests

Tests always run against the built module (`$env:MCP_MODULE_MANIFEST`, set by the `Test` task; otherwise
the newest build under `output/`). `tests/Support/McpTestSupport.psm1` provides the helpers (repository root,
built manifest, vendored schema access, a child-process runner with UTF-8 streams).

| Folder | Scope | Notes |
|---|---|---|
| `tests/Unit` | manifest, import behaviour, type accelerators, enums against the schema, custom analyzer rules, JSON codec, JSON-RPC model, `_meta` validation, JSON Schema generation and validation (both engines), tool registry and in-process invocation, `server/discover` and `tools/list` shapes against the vendored schema, header value encoding and `x-mcp-header` validation, HTTP status mapping, Origin checks, SSE parsing | in-process |
| `tests/Integration` | fresh `pwsh` processes: import must be silent on stdout and stderr, also under `-File`; the client against a server in a background runspace (in-memory transport); `examples/echo-server.ps1` over stdio (encoding, 1 MB payloads, progress, timeouts, stderr capture, BOM-free stdout, EOF shutdown); a Streamable HTTP server in a background runspace (client round trips, SSE progress, header mirroring, disconnect → cancel, and raw requests for every status and error code the specification assigns) | spawns processes, binds loopback ports |
| `tests/Conformance` | the fixtures of the conformance suite (not Pester; run by the `Conformance` task) | needs Node.js |
| `tests/Spec` | vendored schemas: hashes, definition counts, JSON-RPC envelope, checklist | data-driven |
| `tests/Compat` | Windows PowerShell 5.1 guard (skipped off Windows), pinned version matrix (`MCP_EXPECTED_PWSH_VERSION`) | tags `PS51Guard`, `VersionMatrix` |

## Manual verification with the Inspector

The Inspector CLI (`@modelcontextprotocol/inspector`) defaults to the legacy `initialize` handshake and parses
single-dash arguments such as `-File` as its own options, so describe the server in a config file:

```json
{
  "mcpServers": {
    "echo": {
      "command": "pwsh",
      "args": ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", "/abs/path/examples/echo-server.ps1"],
      "env": { "MCP_MODULE_MANIFEST": "/abs/path/output/ModelContextProtocol/0.1.0/ModelContextProtocol.psd1" },
      "protocolEra": "modern"
    }
  }
}
```

```bash
npx @modelcontextprotocol/inspector --cli --config inspector.json --server echo --method tools/list --format json
npx @modelcontextprotocol/inspector --cli --config inspector.json --server echo --method tools/call --tool-name add --tool-args-json '{"A":2,"B":40}'
```

`MCP_MODULE_MANIFEST` makes the example import the built module instead of an installed one.

## Performance (milestone M1, PowerShell 7.4 on Linux, 4 cores)

| Measurement | Value |
|---|---|
| `Connect-McpServer` to `examples/echo-server.ps1` (process start, module import, `server/discover`) | about 1 s |
| First `tools/call` after start (worker runspace warm-up) | about 200 ms |
| Sequential `tools/call` round trip, stdio or in-memory | 25 to 30 ms |
| Four parallel calls that each sleep 2 × 200 ms (`-MaxConcurrency 4`) | about 520 ms in total |
| Stopping a cancelled handler that sleeps with `Start-Sleep` | about 25 ms |
| `Connect-McpServer -Url` to a server in the same process (`server/discover`, `tools/list`) | about 400 ms (first request, includes the worker warm-up) |
| Sequential `tools/call` round trip over Streamable HTTP (loopback, JSON response) | 35 to 40 ms |
| Detecting a client that closed its response stream (keep-alive interval + TCP reset) | keep-alive interval + about 2 s |

A handler blocked in a .NET call that ignores the pipeline stop (for example `[Thread]::Sleep`) is only
stopped when the call returns; handlers should watch `$Context.CancellationToken` in long loops.

## CI

`.github/workflows/ci.yml` runs `lint` (ubuntu, PowerShell 7.4), the `test` matrix (ubuntu, windows, macOS ×
PowerShell 7.4.20, 7.5.11, 7.6.6), `ps51-guard` (windows) and `package` (ubuntu; `Package` + `PublishLocal`,
uploads the `.nupkg`). `.github/workflows/conformance.yml` runs the `Conformance` task on ubuntu with the
runner's Node.js and uploads `output/conformance/`. The composite action `.github/actions/install-pwsh` downloads the pinned PowerShell
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
