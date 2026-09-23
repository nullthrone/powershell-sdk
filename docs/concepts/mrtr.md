# Multi-round-trip requests (MRTR)

Revision 2026-07-28 removes server-initiated requests. A server that needs input from the client (a form
the user fills in, a URL the user opens, a completion sampled by the client's model, the client's roots)
answers the original request with an `InputRequiredResult`:

```json
{ "resultType": "input_required",
  "inputRequests": { "confirm": { "method": "elicitation/create", "params": { "mode": "form", "message": "Delete 3 files?", "requestedSchema": { ... } } } },
  "requestState": "eyJ2Ijox...Q.kC7x..." }
```

The client obtains the answers and sends the original request again, with a new JSON-RPC id, the answers in
`inputResponses` (keyed like `inputRequests`) and the `requestState` echoed verbatim. Only `tools/call`,
`prompts/get` and `resources/read` can be answered this way. Sampling and roots are deprecated in 2026-07-28
but remain valid input requests.

## Handler API

A handler asks for input with one command per input type. Each takes the handler's `Context` parameter and
a `-Key` that identifies the request within the handler:

| Command | Input request | Returns |
|---|---|---|
| `Request-McpElicitation -Message -Schema [-Required]` | `elicitation/create`, form mode | `Mcp.ElicitResult` (`Action`, `Accepted`, `Content`) |
| `Request-McpElicitation -Message -Url` | `elicitation/create`, URL mode | `Mcp.ElicitResult` |
| `Request-McpSampling -Messages [-MaxTokens] [-SystemPrompt] [-Tools] ...` | `sampling/createMessage` | `Mcp.SamplingResult` (`Text`, `Content`, `Model`, `StopReason`) |
| `Request-McpRoot` | `roots/list` | `Mcp.Root` objects (`Uri`, `Name`) |

```powershell
Register-McpTool -Name 'delete-files' -ScriptBlock {
    param([Parameter(Mandatory)] [string] $Pattern, $Context)
    $answer = Request-McpElicitation -Context $Context -Key 'confirm' -Message "Delete '$Pattern'?" -Schema @{
        ok = @{ type = 'boolean'; title = 'Delete' }
    } -Required ok
    if ($answer.Action -ne 'accept' -or -not $answer.Content.ok) { return 'Cancelled.' }
    Remove-Item -Path $Pattern
    'Deleted.'
}
```

The first time the command runs, the answer is missing: it throws an internal control-flow exception
(`McpInputRequiredException`), and the worker answers the request with the `InputRequiredResult`. On the
retry the handler runs again **from the start**; this time the command finds the answer and returns it.

**Several requests in one round.** With `-Defer` a command records its request and returns nothing instead
of throwing; `Wait-McpInput -Context $Context` then throws once for all recorded requests. On the retry the
same commands return their answers and `Wait-McpInput` returns without output:

```powershell
$name = Request-McpElicitation -Context $Context -Key 'name' -Message 'Name?' -Schema @{ name = @{ type = 'string' } } -Defer
$roots = Request-McpRoot -Context $Context -Key 'roots' -Defer
Wait-McpInput -Context $Context
"Hello $($name.Content.name); roots: $(@($roots).Count)"
```

**Several rounds.** A handler may ask again after it got an answer (a second question that depends on the
first answer). The answers of earlier rounds are kept in the signed `requestState`, so the client only sends
the answers of the latest round.

**Idempotency.** Because every round re-executes the handler, everything before the last input request
must be free of side effects, or repeatable. Do the work after the last `Request-*` call.

**Handler state.** `$Context.State` is a hashtable that survives the rounds: whatever the handler stores
there before an input request is in the next round's `$Context.State`. It travels inside `requestState`
(signed, not encrypted; see below), so it must be small and must not hold secrets.

## Capability gating

An input request is only sent when the client declared the matching capability in
`_meta.clientCapabilities`: `elicitation` (an empty object means form mode) or `elicitation.form` for forms,
`elicitation.url` for URL mode, `sampling` (`sampling.tools` with `-Tools`, `sampling.context` with
`-IncludeContext` other than `none`) and `roots`. Otherwise the command fails the request with `-32021` and
`data.requiredCapabilities` naming what is missing. A handler that can do without the input checks first:

```powershell
if (-not (Test-McpClientCapability -Context $Context -Path 'elicitation')) { return 'Cannot confirm; nothing done.' }
```

## Validation

- **Requested schemas.** Form schemas are restricted to flat primitive properties: strings (formats `email`,
  `uri`, `date`, `date-time`), numbers, integers, booleans, single-select enums (`enum`, `oneOf` with
  `const`/`title`, the legacy `enumNames`) and multi-select enums (arrays with `enum` or `anyOf` items).
  `Request-McpElicitation` throws an `ArgumentException` for anything else; a table of properties or a full
  object schema are accepted.
- **Answers.** `inputResponses` must be an object whose values are objects; an elicitation answer needs an
  `action` of `accept`, `decline` or `cancel`, and accepted form content must match the requested schema; a
  sampling answer needs `role`, `content` and `model`; a roots answer needs `roots` with a `uri` each. A
  violation fails the request with `-32602`. Answers for keys the handler does not ask for are ignored.
- **Missing answers.** A retry that lacks an answer is not an error: the handler asks again and the request
  is answered with another `InputRequiredResult`.

## `requestState`

The state is a token of two base64url parts, `payload.signature`. The payload (JSON) holds a format
version, the method, the target (tool or prompt name, resource URI), a SHA-256 digest of the request's
salient parameters (the arguments, or the URI), an expiry, a nonce, the answers accepted so far, the keys
requested in this round and the handler state. The signature is HMAC-SHA256 over the payload part.

The server verifies the state before it looks at anything else in the request: format, signature (compared
in constant time), expiry, method, target and parameter digest. Any failure answers `-32602 Invalid
requestState`. A state therefore cannot be replayed against another tool, another resource or other
arguments, and it cannot be altered.

- **Key.** `New-McpServer -RequestStateKey` takes a string or `SecureString` of at least 16 characters
  (hashed with SHA-256) or a `byte[]` of at least 32 bytes. Without it the server uses a random key per
  process: a retry that reaches another process or a restarted server fails with `-32602` and the client has
  to start over. Behind a load balancer, give every instance the same key. An HTTP server without an explicit
  key logs a note to stderr at startup.
- **Lifetime.** `-RequestStateTtlSeconds` (default 600) bounds how long the user may take to answer.
- **Confidentiality.** The state is signed, not encrypted: the client can read it. It contains only what the
  client sent or received anyway, plus `$Context.State`. Encryption (AES-GCM) and binding the state to the
  authenticated principal follow with authorization in milestone M6.

## Client

`Connect-McpServer` takes one callback per input type. Each is invoked with an `Mcp.InputRequest` (`Key`,
`Method`, `Mode`, `Message`, `RequestedSchema`, `Url`, `Messages`, `MaxTokens`, `SystemPrompt`, `Params`,
and `RequestMethod`, the method being retried):

| Parameter | Returns |
|---|---|
| `-OnElicitation` | the form content as a hashtable (meaning accept), an ElicitResult (`@{ action = 'decline' }`), the action as a string, or nothing (cancel) |
| `-OnSampling` | the assistant's text as a string, or a CreateMessageResult (`role`, `content`, `model`, `stopReason`) |
| `-OnRoots` | paths or URIs, hashtables with `uri` and `name`, or a ListRootsResult |

A callback declares its capability unless `-Capabilities` says otherwise (elicitation in form and URL mode,
sampling, roots). `Invoke-McpTool`, `Invoke-McpPrompt` and `Read-McpResource` run the rounds transparently:
they call the callbacks, retry with a new id, the answers and the state exactly as received (and no state
when the server sent none), and stop with an error after `-MaxInputRounds` rounds (default 10). A server
asking for an input type without a callback fails the command with a message naming the missing parameter.
Results that needed input rounds are not cached.

```powershell
$session = Connect-McpServer -Command pwsh -Arguments '-File', './examples/elicitation-server.ps1' -OnElicitation {
    param($Request)
    Write-Host $Request.Message
    @{ confirm = (Read-Host 'yes/no') -eq 'yes' }
}
Invoke-McpTool -Name 'delete-files' -Arguments @{ Pattern = '*.tmp' }
```

`examples/elicitation-server.ps1` has a confirmation dialog and a two-round example.
