# Multi-round-trip requests (MRTR)

Implemented in milestone M4. Revision 2026-07-28 removes server-initiated requests; a server that needs
input from the client (elicitation, sampling, roots) answers with `resultType: input_required`, a list of
`inputRequests` and an opaque `requestState`, and the client retries the original request with
`inputResponses` and the echoed state.

- **Handler API.** `Request-McpElicitation -Key <k> -Message ... -Schema ...`, `Request-McpSampling`,
  `Request-McpRoots`, batched through `Request-McpInput -Batch`. Without a matching entry in
  `InputResponses` the cmdlet throws a control-flow exception; the dispatcher turns it into the
  `input_required` result. On the retry the handler runs again and the cmdlet returns the answer.
- **Idempotency contract.** Handlers must be idempotent up to their first input request, because the retry
  re-executes them.
- **`requestState`.** HMAC-SHA256 over principal hash, TTL, method, parameter digest and state payload
  (key configurable; random per process by default), optionally AES-GCM encrypted for confidential state.
  Verification failures answer `-32602`; missing responses yield another `input_required` result instead of
  an error.
- **Capability gating.** Only input modes the client declared in `_meta.clientCapabilities` are requested;
  otherwise the server answers `-32021` with `requiredCapabilities`.
- **Client.** `Connect-McpServer` accepts `-OnElicitation`, `-OnSampling` and `-OnRoots` callbacks; the retry
  loop is transparent to `Invoke-McpTool`, `Read-McpResource` and `Invoke-McpPrompt`.
