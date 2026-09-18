# Authorization

Implemented in milestone M6 (core) and M7 (extensions). Authorization applies to Streamable HTTP only;
stdio servers rely on the environment.

## Client

`McpOAuthProvider` implements the client side of the specification: protected-resource metadata discovery
from `WWW-Authenticate` or the well-known path, authorization-server metadata discovery in the specified
order with issuer equality checks, PKCE S256 (required; the metadata must advertise it), the `resource`
parameter, RFC 9207 `iss` validation, client registration in the order pre-registered, client ID metadata
document, dynamic client registration (deprecated), and a scope strategy with step-up and a retry limit.
Tokens live in a store abstraction (in-memory by default; `Microsoft.PowerShell.SecretManagement` as an
optional adapter) and are refreshed automatically. The loopback redirect listener uses fixed ports so that
registered redirect URIs stay valid.

Extensions: OAuth client credentials (`client_secret_basic`, `private_key_jwt` with RS256) and
enterprise-managed authorization (token exchange to an ID-JAG, then `jwt-bearer`).

## Server

`New-McpBearerAuthOptions` configures the bearer middleware: JWT validation through JWKS or an introspection
hook, audience binding to the canonical resource URI, scope hierarchy, `401`/`403` challenges with
`WWW-Authenticate` (`resource_metadata`, `scope`, `insufficient_scope`), and the protected-resource metadata
endpoint. Tokens are never passed through to upstream services.
