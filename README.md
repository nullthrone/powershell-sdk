# ModelContextProtocol (PowerShell SDK)

PowerShell SDK for building and consuming [Model Context Protocol](https://modelcontextprotocol.io) servers
and clients, targeting specification revision **2026-07-28** with dual-era support for 2025-11-25 and
2025-06-18.

> **Status: milestone M2 (Streamable HTTP).** Servers expose PowerShell functions, cmdlets, scripts and
> script blocks as tools over stdio and over Streamable HTTP with the stateless 2026-07-28 lifecycle
> (`server/discover`, per-request `_meta`, request metadata headers, progress, cancellation), and the client
> side connects to such servers over both transports. The official conformance suite runs in CI: every
> 2026-07-28 scenario of the tools, HTTP header validation and DNS rebinding groups passes on both legs;
> the remaining scenarios (resources, prompts, completion, input requests, subscriptions, authorization)
> are listed in [conformance-baseline.yml](conformance-baseline.yml) and follow in M3 to M7. The milestones
> are in [ROADMAP.md](ROADMAP.md); the design is in [docs/implementation-plan.md](docs/implementation-plan.md).

## Requirements

- PowerShell 7.4 or later on Windows, Linux or macOS (7.4 LTS, 7.5 and 7.6 LTS are tested in CI).
- `CompatiblePSEditions = Core`; Windows PowerShell 5.1 is not supported and refuses to import the module.
- No runtime dependencies: a pure script module that only uses assemblies shipped with PowerShell.

## Quick start

A server is a script that registers tools and serves stdio:

```powershell
#Requires -Version 7.4
Import-Module ModelContextProtocol

function Get-Weather {
    <#
    .SYNOPSIS
        Current weather for a location.
    .PARAMETER Location
        City or postal code.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Location,
        [ValidateSet('metric', 'imperial')] [string] $Units = 'metric'
    )
    [pscustomobject]@{ location = $Location; temperature = 21.5; units = $Units }
}

New-McpServer -Name weather -Version 1.0.0 -Instructions 'Weather lookups.' -SetDefault
Register-McpTool -Command (Get-Command Get-Weather)        # schema from the parameters and the help
Register-McpTool -Name echo -ScriptBlock { param([Parameter(Mandatory)][string] $Text) $Text }
Start-McpServer                                             # serves stdio until stdin closes
```

Hosts start it with `pwsh -NoLogo -NoProfile -NonInteractive -File ./weather-server.ps1`. Tool arguments are
validated against the generated JSON Schema and bound to the parameters; objects become
`structuredContent`, strings become text, `New-McpContent` builds image, audio and resource blocks, and
`Write-McpProgress`/`Write-McpLog` reach the client through a `Context` parameter. Handlers run in a worker
runspace pool, so nothing they write to the host can reach stdout.

The client side:

```powershell
$session = Connect-McpServer -Command pwsh -Arguments '-NoLogo', '-NoProfile', '-NonInteractive', '-File', './weather-server.ps1'
Get-McpServerInfo | Format-List
Get-McpTool | Select-Object Name, Description
$result = Invoke-McpTool -Name Get-Weather -Arguments @{ Location = 'Berlin' }
$result.StructuredContent.temperature
Disconnect-McpServer
```

Over Streamable HTTP the same server listens on a URL, and the same client commands connect to it:

```powershell
Start-McpServer -Transport Http -Url http://127.0.0.1:8080/mcp/      # POST-only endpoint, SSE for progress

$session = Connect-McpServer -Url http://127.0.0.1:8080/mcp/
Invoke-McpTool -Name Get-Weather -Arguments @{ Location = 'Berlin' }
```

The HTTP server validates the request metadata headers of revision 2026-07-28 (`MCP-Protocol-Version`,
`Mcp-Method`, `Mcp-Name`, `Mcp-Param-*`), the `Host` and `Origin` headers (DNS rebinding protection) and answers with the
HTTP statuses the specification assigns to the JSON-RPC error codes; the client sends those headers,
mirrors parameters registered with `Register-McpTool -Header` into `Mcp-Param-*` headers and reads JSON or
SSE responses. See [docs/concepts/transports.md](docs/concepts/transports.md).

`Connect-McpServer -Server $serverObject` runs a server in a background runspace over an in-memory transport,
which is how the tests exercise servers without child processes. `Invoke-McpToolHandler` calls a registered
tool directly for unit tests of the tool itself. See `examples/echo-server.ps1`, `examples/http-server.ps1`
and [docs/development.md](docs/development.md) for the Inspector command line.

## Building from source

```powershell
git clone https://github.com/nullthrone/powershell-sdk.git
cd powershell-sdk
./build.ps1 -Bootstrap        # installs Pester, PSScriptAnalyzer, ModuleBuilder (+ Configuration, Metadata), InvokeBuild, PlatyPS
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
- **Conformance first.** The official conformance suite runs in CI (`.github/workflows/conformance.yml`,
  `./build.ps1 -Task Conformance`) against a baseline that may only shrink; 1.0.0 requires an empty baseline
  for the 2026-07-28 and 2025-11-25 requirement sets.

## Repository

| Path | Purpose |
|---|---|
| `src/` | Module sources and manifest |
| `tests/` | Pester tests (unit, integration, spec, compat) and the conformance fixtures (`tests/Conformance`) |
| `tools/` | Custom PSScriptAnalyzer rules, maintenance scripts, offline package drop folder |
| `docs/` | Concept documentation, implementation plan, research material |
| `.github/` | CI matrix, release workflow, label sync, issue templates |

Governance: [ROADMAP.md](ROADMAP.md), [DEPENDENCY_POLICY.md](DEPENDENCY_POLICY.md),
[SECURITY.md](SECURITY.md), [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), [CHANGELOG.md](CHANGELOG.md).

License: MIT.
