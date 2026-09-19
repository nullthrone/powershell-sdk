# Security Policy

## Supported versions

Security fixes are provided for the latest version released on the PowerShell Gallery and for the `main`
branch. Prerelease versions (`0.x-previewN`) receive fixes only in the next prerelease.

## Reporting a vulnerability

Please do not open a public issue for security problems. Use GitHub's private vulnerability reporting for
this repository: <https://github.com/nullthrone/powershell-sdk/security/advisories/new>. Include the module
version, the PowerShell version and operating system, a description of the problem and, if possible, a
minimal reproduction.

You will receive an acknowledgement within 2 business days. Vulnerabilities with a CVSS score of 7.0 or higher
(High or Critical) are handled as priority P0 with a target fix time of 7 days; lower severities are fixed in
the next regular release. Reporters are credited in the changelog unless they prefer otherwise.

## Scope

In scope: the module code under `src/`, the published package, and the build and release pipeline in this
repository. Out of scope: vulnerabilities in PowerShell itself, in MCP hosts and clients, or in servers that
third parties build with this SDK.

## Design notes relevant to security

- The stdio transport never writes anything but protocol messages to stdout; diagnostics go to stderr.
- The Streamable HTTP host binds to loopback by default and validates the `Origin` header.
- JSON Schema validation never fetches external `$ref` targets.
- MRTR `requestState` values are integrity-protected (HMAC) and optionally encrypted.
- The authorization client validates issuers, audiences and PKCE according to the specification; tokens are
  never passed through to upstream services.
