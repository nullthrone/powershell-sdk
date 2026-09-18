# Implementierungsplan: PowerShell SDK für Model Context Protocol (Server und Client)

Repository: `nullthrone/powershell-sdk` (leer bis auf MIT-LICENSE). Branch: `claude/admiring-tesla-r738sg`.
Normative Quelle: modelcontextprotocol.io, Revision **2026-07-28** (final; `latest` zeigt darauf). Die strukturierten Extraktionen der Spec-Seiten, von `schema.ts`, der Extensions, der Docs, der Conformance-Suite und der PowerShell-Plattformrecherche (38 Sektionen) sowie die Szenarienliste der Conformance-Suite liegen unter `docs/research/` (Sekundärmaterial, siehe dortige README). Die Schemas (`schema.ts`/`schema.json` für 2026-07-28, 2025-11-25, 2025-06-18) werden in M0 aus dem Spec-Repository nach `tests/Spec/` übernommen.

---

## 1. Kontext und Ziel

**Warum.** Es gibt kein PowerShell-SDK für MCP, das die aktuelle Revision spricht. Die fünf existierenden Community-Projekte (pwsh.mcp.sdk, PSMCP, pwsh-mcp, PoshMCP, PowerShell.MCP) sind Server-only, Tools-only, sprechen die Legacy-Ära (`initialize`-Handshake, teils mit ungültigen Versionsstrings) und haben weder Client noch Conformance-Nachweis. Die Revision 2026-07-28 ist ein Bruch: zustandsloser Kern, `_meta`-Pflichtfelder pro Request, `server/discover`, MRTR statt server-initiierter Requests, `subscriptions/listen` statt GET-SSE und `resources/subscribe`, `resultType` und `CacheableResult` in Ergebnissen, Header-Validierung auf Streamable HTTP, keine Sessions, keine Resumability. Gleichzeitig sprechen die heute verbreiteten Hosts noch die Legacy-Revisionen; ein SDK ohne Dual-Era ist auf absehbare Zeit nur mit sich selbst kompatibel.

**Was.** Ein vollständiges SDK: (a) Server-Seite, um PowerShell-Funktionen, Skripte und Cmdlets als Tools, Resources und Prompts über stdio und Streamable HTTP anzubieten; (b) Client-Seite, um beliebige MCP-Server aus PowerShell zu konsumieren (Automation, Tests, Agenten). Vollständig heißt: jede Kernfunktion von 2026-07-28 (inklusive der deprecateten Roots/Sampling/Logging), die Dual-Era-Kompatibilität zu 2025-11-25 und 2025-06-18 auf beiden Seiten, Authorization (Client-OAuth-Flows und Server-Bearer-Validierung) sowie die offiziellen Extensions Tasks, Skills, Apps (serverseitig) und die Auth-Extensions. Nichts wird gestrichen, nur sequenziert.

**Explizit außerhalb des Scopes.** Windows PowerShell 5.1; ein Apps-Host (Iframe-Sandbox, postMessage-Bridge, WebView2); die 2024-11-05-Transportvariante HTTP+SSE als Server (als Client-Fallback erst in einem späten Meilenstein, optional); ein Authorization Server; das experimentelle Tasks-API von 2025-11-25 (`tasks/result`, `tasks/list`, `task`-Feld in Request-Params); Kestrel-, Pode- und PowerShell-Universal-Adapter im Kern (spätere optionale Module über die Host-Abstraktion).

**Entstehung dieses Plans.** Die Spec-Extraktion (38 Agenten, 2,1 Mio. Tokens) ist vollständig; das ursprünglich geplante Design-Panel mit Judges und adversarialen Critics wurde nach zwei Session-Limit-Abbrüchen aus Kostengründen gestrichen. Architektur, Abdeckungsmatrix und Meilensteine sind daher manuell erstellt und gegen die Methoden-/Definitionsliste der `schema.json` sowie die Conformance-Szenarienliste geprüft, nicht durch unabhängige Agenten gegengelesen.

---

## 2. Verbindliche Designentscheidungen

### 2.1 Vom Product Owner fixiert

| # | Entscheidung | Festlegung | Begründung |
|---|---|---|---|
| F1 | Implementierung | Reines PowerShell-Skriptmodul. Kein eigener kompilierter Code, kein dotnet-SDK, kein Build-Schritt außer Modul-Assembly per PowerShell. Nur .NET-Assemblies, die mit pwsh ausgeliefert werden (BCL sowie die in `$PSHOME` enthaltenen `JsonSchema.Net`, `Newtonsoft.Json`). Keine Drittanbieter-DLLs im Kern. | Contributor-Zugänglichkeit, PSGallery-Einfachheit, keine Assembly-Load-Konflikte über pwsh-Versionen. |
| F2 | PowerShell-Version | Minimum 7.4 LTS (.NET 8); 7.5 (.NET 9) und 7.6 LTS (.NET 10) getestet. `CompatiblePSEditions = Core`. 5.1 nicht unterstützt (Import schlägt mit klarer Meldung fehl). | 7.4/7.5 EOS 10.11.2026, 7.6 EOS 14.11.2028; Floor-Anhebung auf 7.6 nach dem EOS-Datum als dokumentierte Ausnahme der Breaking-Change-Policy. |
| F3 | Dual-Era | Server bedient 2026-07-28 und Legacy (2025-11-25, 2025-06-18) gleichzeitig auf demselben Endpoint/Prozess; Client erkennt die Server-Ära nach Spec (stdio: `server/discover`-Probe; HTTP: 400-Body-Inspektion), cached sie pro Server und spricht bei Bedarf den Legacy-Lifecycle. 2025-03-26 wird als Versionsstring akzeptiert, ohne eigene Features. | Kompatibilitätsmatrix in `basic/versioning`; alle heutigen Hosts sind Legacy. |
| F4 | Naming | Modul `ModelContextProtocol`, Nomen-Präfix `Mcp`, nur approved verbs. | Analog csharp-sdk; keine Kollision mit PSMCP/pwsh.mcp/PoshMCP. Gallery-Verfügbarkeit ist in M0 zu prüfen (Gallery war aus dem Container nicht erreichbar). |
| F5 | Scope | Vollständig, s. Abschnitt 1. | Auftrag. |
| F6 | Repo/CI/Publish | GitHub Actions (ubuntu, windows, macos × 7.4/7.5/7.6), PSGallery via `Publish-PSResource`. | Tier-Anforderungen (Conformance, Roadmap, Dependency Policy, Labels). |

### 2.2 Architekturentscheidungen (aus der Plattformrecherche abgeleitet)

| Entscheidung | Wahl | Begründung | Verworfene Alternative |
|---|---|---|---|
| Concurrency-Modell | Ein **Dispatcher** (der Runspace, der `Start-McpServer` aufruft) besitzt Transport-I/O, In-Flight-Tabelle, Subscription-Registry und Outbound-Queue. User-Handler laufen in einem **hostlosen `RunspacePool`** (`InitialSessionState.CreateDefault2`, `ThreadOptions = ReuseThread`, `MinRunspaces 1`, `MaxRunspaces = ProcessorCount`, konfigurierbar; `-MaxConcurrency 1` = serieller Modus). Handler werden als `SessionStateFunctionEntry` aus `$sb.Ast.GetScriptBlock()`/Funktionstext in den Pool eingebracht; Aufruf per `[powershell]::Create()` + `BeginInvoke`; Abbruch per `BeginStop` + `CancellationToken`. Kein PowerShell-Code läuft je auf Threadpool-Threads (keine `-Action`/`ContinueWith`/`Register`-Delegates mit Scriptblocks). | Runspace-Affinität von Scriptblocks und Klassen (Aufruf aus fremdem Thread blockiert, bis der Heimat-Runspace Events pumpt); `subscriptions/listen` ist langlebig und darf keinen Worker belegen; HTTP-Callbacks laufen auf Threads ohne Runspace. | Single-Thread-Loop (kann parallele Tool-Calls, SSE-Streams und Listen-Streams nicht bedienen); ThreadJob (Modul-Umbenennung in 7.6, weniger Kontrolle). |
| Handler-Vertrag | Handler erhalten alles über Parameter (`-Arguments`, `-Context`); Closures/Modul-Scope/`$script:` sind nicht verfügbar; `$using:`-Ausdrücke werden bei Registrierung einmal ausgewertet und als ISS-Variablen injiziert (Snapshot-Semantik wie `Start-ThreadJob`, dokumentiert). Handler müssen bis zum ersten Input-Request idempotent sein (MRTR-Retry führt den Handler erneut aus). | Folge des Pool-Modells. | — |
| stdout-Hygiene | Roh-Streams über `[Console]::OpenStandardInput/Output/Error()` mit `[System.Text.UTF8Encoding]::new($false)`, `NewLine = "`n"`, `AutoFlush`; eine einzige Writer-Instanz (Dispatcher) schreibt atomare Zeilen; Worker sind hostlos (Write-Host/Progress landen in `$ps.Streams.*` und werden nach stderr bzw. `notifications/message` geroutet); Preference-Variablen im Dispatcher und in der ISS auf `SilentlyContinue`; jede Loop-Anweisung verwirft Success-Output. Custom-PSSA-Regel verbietet `Write-Host`/`[Console]::Write*`/`Out-*` außerhalb des Transport-Writers. | ConsoleHost schreibt Warnings/Verbose/Information/Write-Host (und bei nicht umgeleitetem stderr sogar Errors) nach stdout. | `[Console]::OutputEncoding` setzen (OEM-Codepage-Probleme, wirft ohne Konsole), `Write-Output` als Transport. |
| JSON-Codec | Eigener Codec auf **System.Text.Json** (in-box 8/9/10): `JsonDocument`/`Utf8JsonReader` → insertion-ordered, case-sensitive `OrderedDictionary` (Ordinal), `object[]` für Arrays, `Int64`/`Double`/Rohtext für Zahlen, **keine** DateTime-Koerzierung; Writer als PowerShell-Walker über `Utf8JsonWriter` (`Indented=false`, `UnsafeRelaxedJsonEscaping`), PSObject-Unwrapping, `[switch]`→bool, `byte[]`→base64 nur an Blob-Feldern, DateTime→ISO-8601 `o`, harte Max-Tiefe (Fehler statt Trunkierung). JSON-RPC-`id` behält seinen JSON-Typ (string vs. number). Abwesend vs. `null` wird über `ContainsKey` unterschieden; optionale Felder werden weggelassen, nie als `null` gesendet. | `ConvertFrom-Json` konvertiert ISO-Strings zu DateTime (7.4 ohne `-DateKind`), entpackt Ein-Element-Arrays, `ConvertTo-Json` trunkiert bei `-Depth 2`, serialisiert `[switch]` als Objekt, emittiert mehrzeilig; die Conformance-Suite validiert jede Wire-Nachricht gegen `schema.json` (`wire-schema-valid`). | ConvertTo/From-Json (nur noch als opt-in Convenience für Nutzer-Objekte). |
| JSON-Schema-Validierung | Adapter über die **pwsh-gebündelte JsonSchema.Net** (API, nicht das Cmdlet `Test-Json`): `EvaluateAs = Draft202012` bei fehlendem `$schema`, werfender `SchemaRegistry.Fetch`, Pre-Scan, der externe `$ref`-URIs ablehnt, Bounds (Tiefe ≤ 32, Subschema-Cap, Zeitbudget). Versions-Probing, weil die API zwischen 5.2.6 (7.4.0), 7.0.4 (7.4.13), 7.2.3 (7.5) und 7.4.0 (7.6) driftet. **Fallback-Validator in reinem PowerShell** für das Elicitation-Primitiv-Subset und die gängigen Tool-Schema-Keywords (type, properties, required, additionalProperties, enum, const, min/max, minLength/maxLength, pattern, items, minItems/maxItems, oneOf/anyOf/allOf). Unterstützte Dialekte dokumentiert: 2020-12 (Default, erzwungen), 2019-09, draft-07, draft-06; draft-04 → klarer Fehler. | `Test-Json` setzt prozessglobal einen HTTP-Fetcher für `$ref` (Verstoß gegen MUST NOT), evaluiert `$schema`-lose Schemata nicht als 2020-12, ignoriert `format`, liefert nur non-terminating Errors. | Drittanbieter-Validator bündeln (Typ-Identitätskonflikt mit der geladenen JsonSchema.Net; verletzt F1). |
| Typmodell | Drei Schichten: (1) **Engine-Klassen** (intern, `[NoRunspaceAffinity()]`, deterministisch geordnete Dateien, per TypeAccelerator exportiert und in `OnRemove` entfernt) nur für zustandsbehaftete Komponenten (Server, Client, Transports, Router, SubscriptionRegistry, TaskStore, LegacySession); (2) **Wire-Objekte** als geordnete Dictionaries (wire-treu, era-bewusst serialisiert); (3) **öffentliche Rückgaben** als `PSCustomObject` mit `PSTypeName` (`Mcp.Tool`, `Mcp.ToolResult`, `Mcp.Resource`, …) plus `ps1xml`-Formate. Konstruktoren `New-McpContent`, `New-McpToolResult` etc. erzeugen valide Wire-Objekte für alle 155 Schema-Definitionen. | Klassen lassen sich nicht neu laden, kreuzen Modulgrenzen nur per `using module` und serialisieren `null` für optionale Felder. | Alles als Klassen (Reload-/Scoping-Probleme), alles als Hashtables (keine Typprüfung). |
| HTTP-Hosting | **System.Net.HttpListener** (in-box) hinter einer Host-Abstraktion (`McpHttpHost`: Request-Kontext, `WriteJson`, `BeginSse` → SSE-Writer mit Keep-alive und Disconnect→Cancel). Default-Bindung `http://127.0.0.1:<port>/mcp/`; Origin-Allowlist (403); TLS nur über Reverse Proxy (Linux/macOS-Listener kann kein HTTPS) oder http.sys-Zertifikatbindung auf Windows; `SendChunked` + `X-Accel-Buffering: no` + initiales `:`-Kommentar für SSE; JSON-only-Hostmodus als dokumentierter Fallback (keine Listen-Streams). | Einzige in-box, plattformübergreifende Option; Spec verlangt Loopback-Default und Origin-Check. | Kestrel (nicht in pwsh enthalten, ALC-Konflikte), Pode/PSU (optionale spätere Adapter). |
| HTTP-Client | `HttpClient` + `SocketsHttpHandler` (`AllowAutoRedirect=$false`, `Timeout = Infinite`, eigene CTS für Connect/Request/Idle), `SendAsync(ResponseHeadersRead)`, Branch auf Content-Type; eigener SSE-Parser (7.4) mit optionaler Nutzung von `System.Net.ServerSentEvents` ab 7.5; Proxy aus Umgebungsvariablen. `Invoke-WebRequest`/`Invoke-RestMethod` nur für One-Shot-OAuth-Metadaten. | Web-Cmdlets puffern Bodies, kein SSE; Redirect-Handler entfernt Authorization und macht aus POST GET. | — |
| MRTR-Handler-API | Ein Cmdlet-Satz (`Request-McpElicitation`, `Request-McpSampling`, `Request-McpRoots`) mit **zwei Ausführungsstrategien**: modern → wirft eine Control-Flow-Exception, der Dispatcher antwortet mit `InputRequiredResult` (`inputRequests`, HMAC-signierter `requestState`), Retry führt den Handler erneut aus und die Cmdlets liefern die Antwort aus `inputResponses`; legacy → blockierender server-initiierter Request über die Session mit Response-Korrelation. Handler bleiben era-agnostisch. `requestState`: HMAC-SHA256 (Schlüssel konfigurierbar, Default zufällig pro Prozess) über Principal-Hash, TTL, Methode, Param-Digest, State-Payload; optional AES-GCM bei vertraulichem State; Verifikationsfehler → `-32602`. | MRTR verbietet server-initiierte Requests in 2026-07-28; Legacy braucht sie. | Callback-/Await-Modell (entspricht dem entfernten 2025-11-25-Muster). |
| Legacy-Schichtung | `Legacy/`-Komponente mit `McpLegacySession` (pro stdio-Prozess bzw. pro `Mcp-Session-Id`): initialize/initialized, Capability-Negotiation, ping, logging/setLevel, resources/subscribe/unsubscribe, server-initiierte Requests mit Pending-Tabelle, GET-SSE-Stream, DELETE, 404 bei abgelaufener Session, era-spezifische Fehlercodes (`-32002`, `-32042`), era-spezifische Serialisierung (kein `resultType`/`ttlMs`/`cacheScope` in Legacy-Antworten). Router wählt die Ära pro Nachricht: `_meta`-Pflichtfelder vorhanden → modern; `initialize` → Legacy-Session; Folge-Requests per Session zugeordnet. Resumability (`Last-Event-ID`) wird nicht implementiert (MAY). | Kern bleibt zustandslos; Legacy ist isoliert testbar und später entfernbar. | Legacy-Semantik im Kern (verletzt Statelessness-MUSTs). |
| Deprecated Features | Roots, Sampling, Logging werden implementiert (als MRTR-Input-Requests und in Legacy als server-initiierte Requests), in Hilfe und Discover-Dokumentation als deprecated markiert; Standard-Logging geht nach stderr. `includeContext` `thisServer`/`allServers` werden akzeptiert, nicht erzeugt. | 12-Monats-Fenster, Legacy-Clients brauchen sie, Conformance-Szenarien (`input-required-result-basic-sampling/list-roots`) verlangen sie. | Weglassen (Scope-Verstoß). |
| Extensions | Formale Registry (`Register-McpExtension`): Identifier, Settings-Objekt, zusätzliche Request-Handler, Capability-Advertising in `server/discover`, Pflichtprüfung der Client-Capability pro Request. Tasks, Skills, Apps (Server), Auth-Extensions setzen darauf auf; Extensions sind default-deaktiviert (Spec-Vorgabe). | Extension-Negotiation ist generisch spezifiziert. | Ad-hoc-Implementierung je Extension. |
| Authorization | Client: `McpOAuthProvider` (PRM- und AS-Metadata-Discovery in Spec-Reihenfolge, Issuer-Gleichheit, PKCE S256 mit Pflichtprüfung von `code_challenge_methods_supported`, `resource`-Parameter, RFC-9207-`iss`-Tabelle, Registrierung pre-registered > CIMD > DCR (deprecated, `application_type=native`) > Prompt, Scope-Strategie mit Step-up und Retry-Limit, Loopback-Listener mit festen Ports, Token-Store-Abstraktion mit In-Memory-Default und optionalem `Microsoft.PowerShell.SecretManagement`-Adapter, Refresh). Server: Bearer-Middleware (JWT via JWKS oder Introspection-Hook, Audience-Bindung an kanonische URI, 401/403 mit `WWW-Authenticate`, PRM-Endpoint). stdio: Auth deaktiviert (Spec). | Spec-MUSTs; 32 Client-Auth-Szenarien in der Conformance-Suite. | — |
| Versionierung/Release | SemVer 2; `0.x-previewN` bis Conformance grün; **1.0.0** = 100 % der erforderlichen Szenarien für `--requirements 2026-07-28` (37 Server + 32 Client) und `2025-11-25` (30 + 18) mit leerer Baseline; Breaking-Change-Policy: öffentliche Funktionssignaturen und `PSTypeName`-Shapes sind API, Engine-Klassen nicht; Floor-Bump = Major, außer die Version ist bei Microsoft out of support. | Tier-Regeln (stabile Version ohne Prerelease, Roadmap, Dependency Policy). | — |

---

## 3. Architektur

### 3.1 Schichten

```
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │ Public API (Functions, approved verbs, Präfix Mcp)                            │
 │  Server: New-/Register-*/Start-/Stop-/Send-*   Client: Connect-/Get-/Invoke-…  │
 │  Tooling: Get-McpLauncherCommand, Register-McpClientConfig, New-McpServerProject│
 ├──────────────────────────────────────────────────────────────────────────────┤
 │ Feature-Module                                                                │
 │  Tools │ Resources │ Prompts │ Completion │ Subscriptions │ MRTR │ Tasks(ext)   │
 │  Skills(ext) │ Apps-Server(ext) │ Auth(client+server) │ Auth-Extensions        │
 ├──────────────────────────────────────────────────────────────────────────────┤
 │ Protocol Core                                                                 │
 │  JsonRpc-Codec (STJ) │ Meta-Validation │ Router (era-aware) │ Capabilities     │
 │  Discover │ Errors (-32020/21/22, -32600..) │ Schema-Validator (JsonSchema.Net)│
 │  Cacheable/Paginated │ Progress/Cancel │ Extension-Registry │ Legacy-Session   │
 ├──────────────────────────────────────────────────────────────────────────────┤
 │ Execution                                                                     │
 │  Dispatcher (Owner-Runspace) │ RunspacePool-Worker │ Outbound-Queue/Sinks     │
 │  In-Flight-Table │ Subscription-Registry │ Timers (Keep-alive, Timeouts)       │
 ├──────────────────────────────────────────────────────────────────────────────┤
 │ Transports (Bindings)                                                         │
 │  Stdio (Server/Client) │ Streamable HTTP (HttpListener-Host / HttpClient)      │
 │  InMemory (Tests) │ Legacy: HTTP-Sessions, GET-SSE, DELETE                     │
 └──────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Kernobjekte (Engine-Klassen, intern)

- `McpServer`: Registrierungen (Tools/Resources/Templates/Prompts/Completions/Extensions), Capabilities, `serverInfo`, `instructions`, `supportedVersions`, Optionen (Concurrency, Timeouts, requestState-Schlüssel, Origin-Allowlist, Auth).
- `McpRouter`: nimmt eine dekodierte Nachricht plus Transport-Kontext, prüft JSON-RPC-Form (id ≠ null, Eindeutigkeit in-flight), bestimmt die Ära, validiert `_meta` (Pflichtfelder → `-32602`, Version → `-32022` mit `supported`/`requested`, Capability-Gates → `-32021` mit `requiredCapabilities`), dispatcht an Method-Handler oder Legacy-Session.
- `McpDispatcher`: Event-Loop mit `Task.WaitAny` über Transport-Read-Task, Outbound-Signal und Tick (250 ms): Housekeeping (abgeschlossene `[powershell]`-Instanzen einsammeln, Timeouts, Keep-alives auf SSE-Streams, optional Engine-Event-Pumpen), Shutdown-Sequenz (stdin-EOF, IOException, Stop-McpServer, PipelineStopped).
- `McpRequestContext` (an Handler übergeben): `RequestId`, `Method`, `ProtocolVersion`, `Era`, `ClientInfo`, `ClientCapabilities`, `LogLevel`, `ProgressToken`, `CancellationToken`, `InputResponses`, `State`, `Sink`, Principal (bei Auth).
- `McpResponseSink`: stdio → enqueue in Dispatcher-Queue; HTTP → request-eigener JSON- oder SSE-Writer; InMemory → Kanal. Worker senden nur über den Sink.
- `McpSubscriptionRegistry`: `{id, filter, sink, era}`; Ack-first unter Lock; Fan-out für `tools/prompts/resources list_changed`, `resources/updated`, `notifications/tasks` (taskIds-Filter der Tasks-Extension); Graceful-Close (Response mit `resultType: complete` und `_meta.subscriptionId`) und stdio-`notifications/cancelled` beim Server-Teardown.
- `McpTaskStore` (Extension): Zustandsautomat `working|input_required|completed|failed|cancelled`, terminal immutable, TTL/Pollintervall, durable-before-respond (Datei- oder In-Memory-Backend hinter Interface).
- `McpLegacySession`: siehe 2.2; Pending-Request-Tabelle für server-initiierte Requests (Worker wartet auf `ManualResetEventSlim`, Dispatcher korreliert Response).
- `McpClient`: Transport, `clientInfo`, `clientCapabilities` (inkl. `extensions`), Era-Cache, Discover-Cache (ttlMs), Tool-/Prompt-/Resource-Caches mit TTL und Invalidation durch Notifications, MRTR-Retry-Loop mit Callbacks (`OnElicitation`, `OnSampling`, `OnRoots`), Auth-Provider, Subscriptions (Hintergrund-Reader-Task, Demultiplex per `subscriptionId`), Tasks-Polling.

### 3.3 Request-Fluss

**stdio (modern).** Dispatcher liest eine Zeile → Codec → Router → `_meta`-Validierung → bei `server/discover`, `*/list`, `completion/complete` Antwort direkt aus dem Dispatcher (vorserialisierte, gecachte Ergebnisse mit `ttlMs`/`cacheScope`); bei `tools/call`, `resources/read`, `prompts/get` Worker-Dispatch mit `CancellationToken` und Timeout; Worker validiert Argumente gegen `inputSchema` (Verstoß → `isError: true` mit Validator-Meldungen; unbekanntes Tool/malformed → `-32602`), bindet die Argumente typisiert (`LanguagePrimitives.ConvertTo`), ruft die Handler-Funktion per Splat auf, sammelt Ausgabe und Streams, baut `CallToolResult` (Content-Blöcke, `structuredContent` gegen `outputSchema` validiert, Text-Block mit demselben JSON per SHOULD), enqueued Response und request-scoped Notifications (`progress`, `message` nur bei `logLevel`) im Sink. `notifications/cancelled` → In-Flight-Eintrag markieren, `BeginStop`, nachfolgende Nachrichten dieser Request-ID verwerfen.

**Streamable HTTP (modern).** Dispatcher nimmt `HttpListenerContext` an → Origin-Check (403) → Methode POST (GET/DELETE → 405 im modern-only-Modus, sonst Legacy-Pfad) → Body-Limit und Content-Type → Header-Validierung (`MCP-Protocol-Version` gegen `_meta`, `Mcp-Method`, `Mcp-Name` für tools/call, resources/read, prompts/get, `Mcp-Param-*` gegen `x-mcp-header`-Pfade, Base64-Sentinel-Decoding, numerischer Vergleich für Integer) → Verstoß: 400 + `-32020`; unbekannte Methode: 404 + `-32601`; Version: 400 + `-32022`; Capability: 400 + `-32021` → Notification: 202 ohne Body → Request: Router wie oben; Antwortwahl JSON (kein `progressToken`, kein `logLevel`, kein Listen) oder SSE (`data: <json>\n\n`, initiales `:`), Response schließt nach der finalen JSON-RPC-Antwort; `subscriptions/listen` bleibt offen mit Keep-alive; Write-Fehler → Cancel des Handlers.

**MRTR.** Handler ruft `Request-McpElicitation -Key 'login' -Message … -Schema …`; ohne `InputResponses['login']` wirft es `McpInputRequiredException` (mehrere Requests sammelbar per `Request-McpInput -Batch`); Dispatcher antwortet `resultType: input_required` mit `inputRequests` (nur Modi/Capabilities, die der Client deklariert hat; sonst `-32021`) und `requestState`; Client-SDK ruft Callbacks, retried mit neuer `id`, `inputResponses` und exakt echo-tem `requestState`; Server verifiziert HMAC/TTL/Principal/Param-Digest, führt den Handler erneut aus. Fehlende Antworten → erneutes `input_required` statt Fehler.

**Subscriptions.** `subscriptions/listen` wird nie an den Pool gegeben: Filter validieren, honorierte Teilmenge aus Server-Capabilities bestimmen, unter Lock registrieren und Ack enqueuen; Fan-out-Cmdlets (`Send-McpToolListChanged` …) sind aus jedem Runspace aufrufbar und taggen jede Notification mit `io.modelcontextprotocol/subscriptionId`. Request-scoped Notifications gehen nie auf Listen-Streams.

**Dual-Era-Auswahl.** Erste Nachricht mit `initialize` → Legacy-Session (stdio: prozessweit; HTTP: `Mcp-Session-Id` minten, GET-SSE-Stream erlauben, DELETE beenden); Nachricht mit `_meta`-Pflichtfeldern → zustandslos. Beide Ären parallel auf demselben Endpoint erlaubt. Client: stdio-Probe `server/discover` (DiscoverResult → modern; erkannter moderner Fehler → modern mit Versionswahl; anderer Fehler/Timeout → Legacy); HTTP: moderner POST, bei 400 Body auf `-32020/-32021/-32022` prüfen, sonst Legacy `initialize`; Ära pro Origin/Prozess cachen.

### 3.4 Datenübergabe zwischen Runspaces

Nur unveränderliche Strings/JSON, frisch gebaute Hashtables/Arrays mit Ownership-Transfer oder `Concurrent*`-Typen; PSObject-Wrapper vor dem Enqueue entpacken; Engine-Klassen mit `[NoRunspaceAffinity()]`.

---

## 4. Repository-Layout

```
/
├── LICENSE, README.md, CHANGELOG.md (Keep a Changelog), ROADMAP.md, DEPENDENCY_POLICY.md,
│   SECURITY.md, CONTRIBUTING.md, CODE_OF_CONDUCT.md
├── build.ps1                       # Bootstrap (Install-PSResource, pinned ranges) + Invoke-Build-Einstieg
├── ModelContextProtocol.build.ps1  # Tasks: Clean, Build, Analyze, Test, Coverage, Help, Conformance, Package, Publish
├── requirements.psd1               # Build-/Test-Abhängigkeiten (Pester [6.2,7), PSScriptAnalyzer [1.25,2), ModuleBuilder, Microsoft.PowerShell.PlatyPS, InvokeBuild)
├── PSScriptAnalyzerSettings.psd1   # Formatierung + CustomRulePath (Measure-McpStdoutPurity, Measure-McpNoInvokeExpression)
├── conformance-baseline.yml        # server:/client: erwartete Fehlschläge (schrumpft auf leer bis 1.0)
├── .editorconfig, .gitattributes (eol=lf), .github/{workflows/ci.yml,release.yml,conformance.yml, ISSUE_TEMPLATE/, CODEOWNERS, dependabot.yml (Actions)}
├── src/
│   ├── ModelContextProtocol.psd1   # PowerShellVersion 7.4, CompatiblePSEditions Core, explizite Exporte, PSData
│   ├── build.psd1                  # ModuleBuilder-Konfiguration (SourceDirectories, CopyPaths)
│   ├── Enums/  001-Era.ps1, 002-TaskStatus.ps1, 003-LoggingLevel.ps1 …
│   ├── Classes/ 010-Json.ps1 (Codec), 020-JsonRpc.ps1, 030-Schema.ps1 (Validator-Adapter), 040-Context.ps1,
│   │            050-Sink.ps1, 060-Subscriptions.ps1, 070-Router.ps1, 080-Dispatcher.ps1, 090-Transport.ps1,
│   │            100-Stdio.ps1, 110-Http.ps1, 120-LegacySession.ps1, 130-Server.ps1, 140-Client.ps1,
│   │            150-Auth.ps1, 160-Extensions.ps1, 170-Tasks.ps1
│   ├── Private/  Json*.ps1, Schema*.ps1 (Generator aus ParameterMetadata/AST-Hilfe), Header*.ps1, Sse*.ps1,
│   │             Era*.ps1, Legacy*.ps1, Auth*.ps1 (WWW-Authenticate-Parser, PKCE, Discovery, Loopback), Elicitation*.ps1 …
│   ├── Public/   eine Funktion je Datei (siehe Abschnitt 5)
│   ├── Types/ModelContextProtocol.Types.ps1xml, Formats/ModelContextProtocol.Format.ps1xml
│   ├── en-US/ (MAML aus PlatyPS, about_ModelContextProtocol*.help.txt)
│   └── Suffix.ps1                  # TypeAccelerator-Export + OnRemove
├── tests/
│   ├── Unit/          Codec, Schema, Router, Meta-Validation, Header-Validation, SSE-Parser, Era-Detection, Legacy-Session, Auth-Parser …
│   ├── Integration/   InMemory-Roundtrips, stdio-Subprozess (pwsh -NoProfile -NonInteractive -File), HTTP auf 127.0.0.1, Encoding/Emoji/1-MB-Nachrichten, EOF-Shutdown, Kill-Tree
│   ├── Conformance/   everything-server.ps1 (Modi: -Era Modern|Legacy|Dual), everything-client.ps1 (liest MCP_CONFORMANCE_*), Invoke-Conformance.ps1
│   ├── Spec/          2026-07-28_schema.json, 2025-11-25_schema.json, definitions-checklist.txt (Pester: jede Definition hat Konstruktor- und Parser-Test)
│   └── Compat/        ps51-guard.Tests.ps1 (Import muss scheitern), version-matrix.Tests.ps1
├── examples/  echo-server.ps1, weather-server.ps1 (Tools/Resources/Prompts), elicitation-server.ps1, http-server.ps1, client-chat-loop.ps1, tasks-server.ps1, skills-server.ps1, apps-server.ps1
├── docs/      Markdown-Hilfe (PlatyPS), Konzepte (Transports, Dual-Era, MRTR, Auth), Conformance-Anleitung
└── output/    (gitignored) gebautes Modul output/ModelContextProtocol/<ver>/
```

---

## 5. Öffentliche API

Alle Funktionen: `[CmdletBinding()]`, `[OutputType()]`, kommentarbasierte Hilfe, keine `-ProgressAction`-Kollision (automatischer Common Parameter seit 7.4), `-Session`/`-Server` mit modulweitem Default.

### 5.1 Server

| Funktion | Zweck | Signatur-Skizze |
|---|---|---|
| `New-McpServer` | Server-Objekt anlegen | `-Name -Version [-Title] [-Description] [-Instructions] [-Icons] [-SupportedVersions @('2026-07-28','2025-11-25','2025-06-18')] [-Era Dual\|Modern\|Legacy] [-MaxConcurrency] [-RequestTimeout] [-RequestStateKey <SecureString>] [-DefaultTtlMs] [-PassThru] [-SetDefault]` |
| `Register-McpTool` | Tool aus Funktion/Cmdlet/Scriptblock | `-Name [-Command <CommandInfo>\|-ScriptBlock\|-FunctionName] [-Title] [-Description] [-InputSchema <hashtable\|json>] [-OutputSchema] [-Annotations @{ReadOnlyHint;DestructiveHint;IdempotentHint;OpenWorldHint}] [-Icons] [-Header @{Region='Region'}] [-ParameterSet] [-AdditionalProperties] [-TtlMs] [-CacheScope Public\|Private] [-Meta] [-Server]`; Schema-Generierung aus `ParameterMetadata` + AST-Hilfe (Mandatory→required, ValidateSet→enum, ValidateRange→min/max, ValidateLength/Count/Pattern, Defaults, `[switch]`→boolean, int→integer, DateTime→date-time, enum→enum, Arrays mit `items`, Common Parameters ausgeschlossen, SecureString/PSCredential/ScriptBlock abgelehnt) |
| `Register-McpResource` | Statische Resource oder Template | `-Uri\|-UriTemplate -Name [-Title] [-Description] [-MimeType] [-Size] [-Annotations] [-Icons] [-ScriptBlock {param($Uri,$Context)}\|-Path\|-Content] [-Subscribable] [-TtlMs] [-CacheScope] [-Completion {param($Argument,$Context)}]` |
| `Register-McpPrompt` | Prompt-Template | `-Name [-Title] [-Description] -Arguments @(@{Name;Description;Required}) -ScriptBlock {param($Arguments,$Context)} [-Icons] [-Completion {…}]` |
| `Register-McpExtension` | Extension aktivieren | `-Id 'io.modelcontextprotocol/tasks' [-Settings @{}] [-RequestHandlers @{'tasks/get'={…}}] [-NotificationTypes]` |
| `Register-McpAppTool` / `Register-McpAppResource` | MCP-Apps-Serverseite | wie Tool/Resource plus `-ResourceUri ui://…`, `-Visibility Model,App`, `-Csp`, `-Permissions`, `-PrefersBorder`; erzwingt `text/html;profile=mcp-app` |
| `Register-McpSkill` | Skills-Extension | `-Path <Ordner mit SKILL.md> [-UriPrefix skill://] [-DirectoryRead]`; berechnet Manifest (sha256, size), bedient `skills/list`, `skills/get`, `resources/read`, `resources/directory/read` |
| `Import-McpToolsFromModule` / `Import-McpToolsFromPath` | Discovery-Stile | Attribut `[McpTool()]` (PowerShell-Klassenattribut, kein Add-Type), Ordnerkonvention `tools/ prompts/ resources/ instructions.md`, Allowlist-`psd1` |
| `Start-McpServer` | Transport starten (blockierend) | `-Transport Stdio\|Http [-Url 'http://127.0.0.1:8080/mcp/'] [-AllowedOrigins] [-Authentication <McpBearerOptions>] [-MaxBodyBytes] [-KeepAliveSeconds] [-JsonOnly] [-AsJob]` |
| `Stop-McpServer` | Graceful Shutdown | `[-Server] [-GraceSeconds]` |
| `Send-McpToolListChanged`, `Send-McpPromptListChanged`, `Send-McpResourceListChanged`, `Send-McpResourceUpdated -Uri`, `Send-McpTaskNotification` | Fan-out | aus jedem Runspace aufrufbar |
| Handler-Cmdlets: `Write-McpProgress -Progress [-Total] [-Message]`, `Write-McpLog -Level -Message [-Logger] [-Data]`, `Request-McpElicitation -Key -Message [-Schema\|-Url]`, `Request-McpSampling -Key -Messages [-MaxTokens] […]`, `Request-McpRoots -Key`, `Request-McpInput -Batch @{…}`, `New-McpContent -Text\|-Image\|-Audio\|-ResourceLink\|-EmbeddedResource`, `New-McpToolResult [-Content] [-StructuredContent] [-IsError]`, `Start-McpTask -ScriptBlock [-TtlMs] [-PollIntervalMs]` (Tasks), `Test-McpClientCapability -Path elicitation.form` | | `$McpContext` als Parameter `-Context` |
| `New-McpBearerAuthOptions` | Server-Auth | `-Resource <kanonische URI> -AuthorizationServers @(…) [-JwksUri] [-Issuer] [-Audience] [-RequiredScopes] [-ScopesSupported] [-IntrospectionScript {…}] [-ScopeHierarchy]` |
| `Get-McpLauncherCommand` | Client-Konfig-Snippet | `-ScriptPath [-Client ClaudeDesktop\|ClaudeCode\|VSCode\|Cursor\|Json] [-AsJson]` → `pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <abs>` |
| `Register-McpClientConfig` | Server in Host-Konfiguration eintragen | `-Name -ScriptPath -Client …` |
| `New-McpServerProject` | Scaffolder | `-Path -Name [-Template Echo\|Weather\|Http]` |

**Server-Beispiel (vollständig):**

```powershell
#Requires -Version 7.4
#Requires -Modules ModelContextProtocol
[CmdletBinding()] param()
Import-Module ModelContextProtocol

function Get-Weather {
    <# .SYNOPSIS Liefert das aktuelle Wetter. .PARAMETER Location Stadt oder PLZ. .PARAMETER Units Einheitensystem. #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)] [string] $Location,
        [ValidateSet('metric','imperial')] [string] $Units = 'metric',
        [Parameter()] $Context
    )
    $who = Request-McpElicitation -Context $Context -Key 'consent' -Message "Standort $Location abfragen?" -Schema @{ ok = @{ type = 'boolean'; default = $true } }
    if ($who.action -ne 'accept' -or -not $who.content.ok) { return New-McpToolResult -IsError -Content (New-McpContent -Text 'Abgelehnt') }
    Write-McpProgress -Context $Context -Progress 1 -Total 2 -Message 'Abfrage'
    [pscustomobject]@{ temperature = 21.5; conditions = 'clear'; humidity = 40 }   # wird structuredContent + Text
}

$server = New-McpServer -Name 'weather' -Version '1.0.0' -Instructions 'Wetterauskunft' -SetDefault
Register-McpTool -Command (Get-Command Get-Weather) -OutputSchema @{ type='object'; properties=@{ temperature=@{type='number'}; conditions=@{type='string'}; humidity=@{type='number'} }; required=@('temperature','conditions','humidity') } -TtlMs 300000
Register-McpResource -Uri 'weather://config' -Name 'config' -MimeType 'application/json' -ScriptBlock { param($Uri,$Context) '{ "provider": "nws" }' } -TtlMs 60000 -CacheScope Private
Register-McpPrompt -Name 'summarize' -Arguments @(@{ Name='city'; Required=$true }) -ScriptBlock { param($Arguments,$Context) New-McpPromptMessage -Role user -Text "Fasse das Wetter in $($Arguments.city) zusammen" }
Start-McpServer -Transport Stdio
```

### 5.2 Client

| Funktion | Zweck | Signatur-Skizze |
|---|---|---|
| `Connect-McpServer` | Verbindung/Session | `-Command pwsh -Arguments @(…) [-WorkingDirectory] [-Environment]` oder `-Uri https://host/mcp [-Headers] [-Authentication <McpOAuthOptions\|McpClientCredentialsOptions\|McpEnterpriseAuthOptions>] [-Proxy]`; `[-ClientInfo @{name;version}] [-Capabilities @{elicitation=@{form=@{};url=@{}}; sampling=@{}; roots=@{}}] [-Extensions 'io.modelcontextprotocol/tasks',…] [-ProtocolVersion] [-Era Auto\|Modern\|Legacy] [-OnElicitation {param($Request)}] [-OnSampling {…}] [-OnRoots {…}] [-OnLog {…}] [-RequestTimeout] [-ConnectTimeout] [-SetDefault]` → `Mcp.Session` |
| `Disconnect-McpServer` | stdin schließen, WaitForExit, Kill-Tree; HTTP: Streams schließen (Legacy: DELETE) | `[-Session]` |
| `Get-McpServerInfo` | `server/discover` (gecacht per ttlMs) | `[-Session] [-Refresh]` |
| `Get-McpTool`, `Invoke-McpTool` | tools/list (Pagination, Cache, x-mcp-header-Validierung mit Warnung/Ausschluss), tools/call | `Invoke-McpTool -Name -Arguments @{} [-OnProgress {…}] [-LogLevel] [-Timeout] [-AllowTask]` → `Mcp.ToolResult` (`Content`, `StructuredContent`, `IsError`) oder `Mcp.Task` |
| `Get-McpResource [-Template]`, `Read-McpResource -Uri`, `Get-McpPrompt`, `Invoke-McpPrompt -Name -Arguments`, `Get-McpCompletion -PromptName\|-ResourceUri -Argument -Value [-Context]` | Server-Primitive | Ergebnisse als `PSCustomObject`; MRTR-Retry-Loop transparent; `-32002` von Legacy-Servern als Not-Found akzeptiert |
| `Register-McpSubscription` / `Unregister-McpSubscription` / `Receive-McpNotification` | `subscriptions/listen` | `-ToolsListChanged -PromptsListChanged -ResourcesListChanged -ResourceUri @(…) [-TaskId @(…)] [-Action {param($Notification)}]`; Legacy: `resources/subscribe`; Reconnect-Pflicht nach Prozessneustart |
| `Get-McpTask`, `Wait-McpTask`, `Update-McpTask -InputResponses`, `Stop-McpTask` | Tasks-Extension | Polling mit `pollIntervalMs` (Default 1000 ms), Persistenz der Task-IDs über `-Store` |
| `Get-McpSkill`, `Get-McpSkillContent` | Skills-Extension | Manifest-Verifikation (sha256, Größe, Frontmatter) |
| `New-McpOAuthOptions`, `New-McpClientCredentialsOptions`, `New-McpEnterpriseAuthOptions` | Auth-Provider | `-ClientId\|-ClientIdMetadataUrl\|-PreRegistered -RedirectPorts @(…) [-Scopes] [-TokenStore InMemory\|SecretManagement] [-BrowserLaunch {…}\|-Headless]`; Client Credentials: `-ClientSecret\|-PrivateKey (RSA, RS256)`; Enterprise: `-IdentityProvider -TokenExchangeEndpoint -IdentityAssertion` |
| `Test-McpServer` | Wrapper für Inspector-CLI und Conformance | `-ScriptPath\|-Url [-Scenario] [-Requirements 2026-07-28]` |

**Client-Beispiel:**

```powershell
$s = Connect-McpServer -Command pwsh -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-File','./examples/weather-server.ps1') `
        -Capabilities @{ elicitation = @{ form = @{} } } -OnElicitation { param($r) @{ action='accept'; content=@{ ok=$true } } } -SetDefault
Get-McpServerInfo | Format-List Name, Version, SupportedVersions, Capabilities
Get-McpTool | Select-Object Name, Description
$r = Invoke-McpTool -Name Get-Weather -Arguments @{ Location = 'Berlin' } -OnProgress { param($p) Write-Verbose "$($p.Progress)/$($p.Total)" }
$r.StructuredContent.temperature
Register-McpSubscription -ToolsListChanged -Action { Get-McpTool -Refresh | Out-Null }
Disconnect-McpServer
```

---

## 6. Protokoll-Abdeckungsmatrix

Legende: S = Server, C = Client, M = Meilenstein, Szenario = Conformance-Szenario (Alpha 0.2.0; `--requirements 2026-07-28` bzw. `2025-11-25`).

### 6.1 Kern 2026-07-28 (alle 21 Methoden/Notifications der `schema.json`)

| Methode | S | C | M | Szenarien / Tests |
|---|---|---|---|---|
| `server/discover` (supportedVersions, capabilities inkl. `extensions`, instructions, `_meta.serverInfo`, ttlMs/cacheScope) | ✓ | ✓ (Probe, Cache) | M1 | `server-stateless`, `request-metadata`, Pester Unit |
| `tools/list` (Pagination, deterministische Ordnung, Cacheable) | ✓ | ✓ | M1 | `tools-list` |
| `tools/call` (Content-Typen text/image/audio/resource_link/resource, structuredContent + outputSchema, isError, MRTR-Params `inputResponses`/`requestState`) | ✓ | ✓ | M1 (Text), M3 (alle Typen, Structured) | `tools-call-simple-text/-image/-audio/-embedded-resource/-mixed-content/-error/-with-progress`, `tools_call`, `json-schema-2020-12`, `json-schema-2020-12-preservation`, `json-schema-ref-no-deref` |
| `resources/list`, `resources/templates/list`, `resources/read` (text/blob, RFC 6570, Cacheable, MRTR, `-32602` not found) | ✓ | ✓ | M3 | `resources-list`, `resources-read-text`, `resources-read-binary`, `resources-templates-read`, `sep-2164-resource-not-found`, `caching` |
| `prompts/list`, `prompts/get` (Arguments, alle Content-Typen, MRTR) | ✓ | ✓ | M3 | `prompts-list`, `prompts-get-simple/-with-args/-embedded-resource/-with-image` |
| `completion/complete` (ref/prompt, ref/resource, context.arguments, max 100) | ✓ | ✓ | M3 | `completion-complete` |
| `subscriptions/listen` + `notifications/subscriptions/acknowledged` + `notifications/tools/list_changed`, `notifications/prompts/list_changed`, `notifications/resources/list_changed`, `notifications/resources/updated` (Ack-first, subscriptionId, Graceful-Close, stdio-Cancel) | ✓ | ✓ | M4 | `server-sse-multiple-streams`, Pester Integration (stdio+HTTP) |
| `notifications/progress` (progressToken, monoton, request-scoped) | ✓ | ✓ | M3 | `tools-call-with-progress` |
| `notifications/cancelled` (Client→Server auf stdio; Server→Client nur für Listen-Teardown) | ✓ | ✓ | M1/M4 | Pester Integration |
| `notifications/message` (nur bei `_meta.logLevel`, deprecated) | ✓ | ✓ | M3 | Pester; Legacy: `tools-call-with-logging` |
| `elicitation/create` (Form: alle 8 Primitiv-Schemata inkl. LegacyTitledEnum; URL-Modus) als MRTR-InputRequest | ✓ | ✓ (Callback, Validator) | M4 | `input-required-result-basic-elicitation`, `-multiple-input-requests`, `-multi-round`, `-missing-input-response`, `-non-tool-request`, `-result-type`, `-unsupported-methods`, `-tampered-state`, `-capability-check`, `-ignore-extra-params`, `-validate-input`, `-request-state`; Client: `sep-2322-client-request-state` |
| `sampling/createMessage` (deprecated; inkl. `tools`/`toolChoice`, `tool_use`/`tool_result`-Blöcke, ModelPreferences) als MRTR-InputRequest | ✓ | ✓ | M4 | `input-required-result-basic-sampling` |
| `roots/list` (deprecated) als MRTR-InputRequest | ✓ | ✓ | M4 | `input-required-result-basic-list-roots` |
| Fehlercodes `-32700/-32600/-32601/-32602/-32603`, `-32020` HeaderMismatch, `-32021` MissingRequiredClientCapability (`data.requiredCapabilities`), `-32022` UnsupportedProtocolVersion (`data.supported/requested`) | ✓ | ✓ | M1/M2 | `server-stateless`, `http-header-validation` |
| `_meta`: `protocolVersion`, `clientInfo`, `clientCapabilities`, `logLevel`, `subscriptionId`, `serverInfo`, `progressToken`, `traceparent/tracestate/baggage` (Durchreichung, Logging) | ✓ | ✓ | M1 | `request-metadata` |
| Streamable HTTP: POST-only, Accept beide Typen, `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, `Mcp-Param-*`/`x-mcp-header`, Base64-Sentinel, Origin/403, 202, 404+`-32601`, 405 für GET/DELETE (modern-only), SSE-Keep-alive, `X-Accel-Buffering`, Disconnect=Cancel | ✓ | ✓ | M2 | `dns-rebinding-protection`, `http-header-validation`, `http-custom-header-server-validation`, `http-standard-headers`, `http-custom-headers`, `http-invalid-tool-headers` |
| stdio: Framing, UTF-8 ohne BOM, EOF-Shutdown, stderr-Logging, Kill-Tree im Client | ✓ | ✓ | M1 | Pester Integration; Inspector-CLI |
| JSON Schema 2020-12 (Default-Dialekt, `$ref`-Policy, Bounds), Icons, Annotations, BaseMetadata (`name`/`title`) | ✓ | ✓ | M1/M3 | `json-schema-*` |
| Caching (`ttlMs`, `cacheScope`, Invalidation durch Notifications, Pagination je Seite) | ✓ | ✓ (Cache-Layer) | M3 | `caching` |

### 6.2 Legacy 2025-11-25 / 2025-06-18 (Dual-Era)

| Element | S | C | M | Szenarien |
|---|---|---|---|---|
| `initialize` / `notifications/initialized`, Capability-Negotiation, `protocolVersion`-Fallback | ✓ | ✓ | M5 | `server-initialize`, `initialize` |
| `ping` | ✓ | ✓ | M5 | `ping` |
| `logging/setLevel` + `notifications/message` sessionweit | ✓ | ✓ | M5 | `logging-set-level`, `tools-call-with-logging` |
| `resources/subscribe` / `resources/unsubscribe` / `notifications/resources/updated` | ✓ | ✓ | M5 | `resources-subscribe`, `resources-unsubscribe` |
| Server-initiierte `elicitation/create`, `sampling/createMessage`, `roots/list` (Pending-Tabelle), `notifications/roots/list_changed`, `notifications/elicitation/complete`, `elicitationId`, `-32042` | ✓ | ✓ | M5 | `tools-call-sampling`, `tools-call-elicitation`, `elicitation-sep1034-defaults`, `elicitation-sep1330-enums`, `elicitation-sep1034-client-defaults` |
| HTTP: `Mcp-Session-Id`, GET-SSE-Stream, DELETE, 404 bei abgelaufener Session, Server-Requests auf SSE, Polling | ✓ | ✓ | M5 | `server-session-lifecycle`, `server-sse-polling`, `sse-retry` |
| Era-Serialisierung (kein `resultType`/`ttlMs`/`cacheScope`; `-32002` für Not-Found; Legacy-Elicitation-Shapes) | ✓ | ✓ (Absenz = complete) | M5 | Wire-Schema-Checks gegen `2025-11-25_schema.json` |
| Alle geteilten Szenarien erneut am Legacy-Wire (tools-*, resources-*, prompts-*, completion, dns-rebinding) | ✓ | ✓ | M5 | `--requirements 2025-11-25` (30 S / 18 C) |
| 2025-03-26: Header `MCP-Protocol-Version` optional (Server MAY als 2025-03-26 behandeln) | ✓ (Option) | ✓ | M5 | Pester |
| HTTP+SSE 2024-11-05 | ✗ (out of scope) | optionaler Fallback (GET `endpoint`-Event) | M8 (optional) | — |

### 6.3 Authorization

| Element | S | C | M | Szenarien |
|---|---|---|---|---|
| PRM (`/.well-known/oauth-protected-resource[/path]`), `WWW-Authenticate` 401/403 (`resource_metadata`, `scope`, `insufficient_scope`), Bearer-Validierung mit Audience, Scope-Hierarchie, kein Token-Passthrough | ✓ | ✓ (Parser, Discovery) | M6 | `auth/metadata-default`, `auth/metadata-var1..3`, `auth/scope-from-www-authenticate`, `auth/scope-from-scopes-supported`, `auth/scope-omitted-when-undefined`, `auth/scope-step-up`, `auth/scope-retry-limit` |
| AS-Metadata-Discovery (RFC 8414/OIDC, Reihenfolge, Issuer-Gleichheit), PKCE S256, `resource`, `iss`-Validierung, Credential-Bindung an Issuer | — | ✓ | M6 | `auth/iss-*` (6), `auth/metadata-issuer-mismatch`, `auth/resource-mismatch`, `auth/authorization-server-migration`, `auth/offline-access-*` |
| Registrierung: pre-registered, CIMD, DCR (`application_type`) | — | ✓ | M6 | `auth/basic-cimd`, `auth/pre-registration`, `auth/token-endpoint-auth-basic/-post/-none` |
| Extension `oauth-client-credentials` (client_secret_basic, private_key_jwt RS256) | Advertise | ✓ | M7 | `auth/client-credentials-jwt`, `auth/client-credentials-basic` |
| Extension `enterprise-managed-authorization` (Token Exchange → ID-JAG → jwt-bearer) | Advertise | ✓ | M7 | `auth/enterprise-managed-authorization` |
| DPoP, WIF-JWT-Bearer | — | ✗ (nicht spezifiziert in den gelesenen Extensions; Baseline) | — | `auth/dpop*`, `auth/wif-jwt-bearer` (extension, not scored) |

### 6.4 Extensions

| Extension | S | C | M | Szenarien |
|---|---|---|---|---|
| Registry, `capabilities.extensions`, Graceful Degradation | ✓ | ✓ | M4 (Grundlage), M7 | — |
| Tasks: `CreateTaskResult` (resultType `task`), `tasks/get` (DetailedTask-Union), `tasks/update`, `tasks/cancel`, `notifications/tasks`, `taskIds`-Filter | ✓ | ✓ | M7 | `tasks-lifecycle`, `tasks-capability-negotiation`, `tasks-wire-fields`, `tasks-request-state-removal`, `tasks-mrtr-input`, `tasks-request-headers`, `tasks-dispatch-and-envelope`, `tasks-status-notifications`, `tasks-required-task-error`, `tasks-mrtr-composition` |
| Skills: `skills/list`, `skills/get`, `resources/directory/read`, Manifeste, Limits (512 Dateien/16 MiB) | ✓ | ✓ | M7 | Pester (kein Conformance-Szenario) |
| Apps (Server): `ui://`-Resources, `text/html;profile=mcp-app`, `_meta.ui.resourceUri/visibility/csp/permissions`, Sichtbarkeitsfilterung in `tools/list`, Fallback-Tool ohne UI | ✓ | ✗ (Host out of scope) | M7 | Pester |

### 6.5 Typmodell-Vollständigkeit

Alle 155 Definitionen der `2026-07-28_schema.json` sind auf die Familien JSON-RPC-Envelope, Meta-Objekte, Capabilities/Implementation/Icons/Annotations, Paginated/Cacheable/Result/ResultType, Content-Blöcke (5), Resources (7), Prompts (4), Tools (4 + Annotations), Completion (4), Subscriptions (7), Discover (3), MRTR (5), Elicitation (11 inkl. 8 Primitiv-Schemata), Sampling (8 inkl. `ToolUseContent`/`ToolResultContent`/`ToolChoice`), Roots (3), Logging (3), Progress/Cancel (4), Fehler (8), JSON-Primitive (3) abgebildet. `tests/Spec/definitions-checklist.txt` enthält die Liste; ein Pester-Test erzwingt für jede Definition einen Konstruktor- und einen Parser-Testfall gegen das gebündelte Schema.

---

## 7. Meilensteine

Jeder Meilenstein liefert einen nutzbaren, getesteten Zwischenstand; die Conformance-Baseline schrumpft monoton.

### M0 Fundament (Toolchain, Skelett, CI)
- Toolchain im Container: `pwsh` installieren (Abschnitt 8.1), `node`/`npx` vorhanden; `build.ps1 -Bootstrap` installiert Pester, PSScriptAnalyzer, ModuleBuilder, PlatyPS, InvokeBuild aus PSGallery (Erreichbarkeit von powershellgallery.com aus dem Container prüfen; Fallback: Offline-Nupkgs in `tools/`).
- Repo-Layout, Manifest (7.4/Core, explizite Exporte, PSData), ModuleBuilder-Build, PSSA-Settings mit Custom-Regeln (stdout-Reinheit, kein `Invoke-Expression`), Pester-Skelett, `tests/Spec` mit vendored `schema.json` beider Revisionen, CI-Matrix (3 OS × 7.4/7.5/7.6, gepinnte pwsh-Installation), `ps51-guard`, Release-Workflow (Dry-Run), Docs-Skelett, ROADMAP/DEPENDENCY_POLICY/SECURITY, Issue-Labels nach Tier-Vorgabe, Gallery-Namensprüfung (`Find-PSResource -Name ModelContextProtocol`; Fallback `ModelContextProtocol.Sdk`).
- **Exit:** CI grün auf allen Matrixzellen mit leerem Modul; `Import-Module` ohne Nebenwirkungen; `Publish-PSResource` gegen ein lokales Repository funktioniert.

### M1 Protokollkern, stdio, Tools (modern)
- JSON-Codec (STJ), JSON-RPC-Modell, `_meta`-Validierung, Fehlercodes, Router, `server/discover`, Capabilities, Extension-Registry-Grundgerüst, InMemory-Transport, Dispatcher + RunspacePool, stdio-Server-Transport, `tools/list`/`tools/call` (Text), Schema-Generator, Validator-Adapter + Fallback, Progress-Token-Durchreichung, `notifications/cancelled`, stderr-Logging, Shutdown-Sequenz.
- Client: `McpClient`, stdio-Client-Transport (Prozess-Spawn, UTF-8, Kill-Tree), `Get-McpServerInfo`, `Get-McpTool`, `Invoke-McpTool`, Timeouts/Cancellation, Era-Probe (nur modern-Erkennung; Legacy-Fallback in M5).
- Plattform-Experimente als Pester-Tests fixiert: BOM-Freiheit auf allen OS, ConsoleHost liest stdin unter `-File` nicht vor, hostloser Pool hält Write-Host/Progress von stdout fern, `BeginStop`-Latenz, `Ast.GetScriptBlock()` erhält `param()`/Attribute/Defaults, `CommentHelpInfo`-Key-Casing, JsonSchema.Net-API je pwsh-Version.
- **Exit:** Unit- und Integrationstests grün (InMemory, stdio-Subprozess, Encoding/Emoji/1 MB); `npx @modelcontextprotocol/inspector --cli … --method tools/list` gegen `examples/echo-server.ps1`; Startzeit und Per-Request-Overhead gemessen und dokumentiert.

### M2 Streamable HTTP (modern)
- HttpListener-Host, Header-Validierung, Origin, Body-Limits, JSON/SSE-Auswahl, Keep-alive, Disconnect→Cancel, 202/400/403/404/405; Client-HTTP-Transport mit SSE-Parser, Header-Mirroring, `x-mcp-header`-Validierung (Ausschluss ungültiger Tools mit Warnung), 400-Body-Inspektion, Retry nach `tools/list`-Refresh bei `-32020`.
- `tests/Conformance/everything-server.ps1` (Modern-Modus) und `everything-client.ps1`; `conformance.yml` mit Alpha-Pin.
- **Exit (Conformance 2026-07-28):** `server-stateless`, `tools-list`, `tools-call-simple-text/-error/-with-progress`, `dns-rebinding-protection`, `http-header-validation`, `http-custom-header-server-validation`; Client: `tools_call`, `request-metadata`, `http-standard-headers`, `http-custom-headers`, `http-invalid-tool-headers`, `json-schema-ref-no-deref`. Erstes Preview `0.1.0-preview1` auf PSGallery.

### M3 Server-Primitive vollständig
- Resources (statisch, Datei-backed, Templates mit RFC-6570-Matching, Blob), Prompts, Completion, Pagination-Cursor, Caching-Felder je Registrierung, alle Content-Typen, `structuredContent`/`outputSchema`, deterministische Ordnung, Icons/Annotations, `notifications/message` per `logLevel`; Client-Gegenstücke mit TTL-Cache.
- **Exit:** `tools-call-image/-audio/-embedded-resource/-mixed-content`, `json-schema-2020-12`, `resources-*` (4), `sep-2164-resource-not-found`, `prompts-*` (5), `completion-complete`, `caching`; Client `json-schema-2020-12-preservation`.

### M4 MRTR und Subscriptions
- InputRequired-Maschinerie, `requestState`-HMAC/AES-GCM, Capability-Gating, Elicitation-Validator (Primitiv-Subset, LegacyTitledEnum akzeptieren), Sampling- und Roots-Requests, Client-Retry-Loop mit Callbacks; `subscriptions/listen` Server (Registry, Ack-first, Fan-out, stdio-Cancel, Graceful-Close) und Client (Hintergrund-Reader, Demux, Reconnect nach Neustart); `server-sse-multiple-streams`.
- **Exit:** alle 14 `input-required-result-*`, `server-sse-multiple-streams`; Client `sep-2322-client-request-state`; Pester für Listen auf stdio und HTTP inkl. Interleaving.

### M5 Dual-Era
- `McpLegacySession` (Server), Router-Ära-Auswahl, era-bewusste Serialisierung, HTTP-Sessions/GET/DELETE, server-initiierte Requests, Legacy-Elicitation, `ping`, `logging/setLevel`, `resources/subscribe`; Client-Legacy-Lifecycle mit Probe-/400-Erkennung, Session-Header, GET-Stream-Handling, Beantwortung server-initiierter Requests, `-32002`-Akzeptanz, `resultType`-Absenz.
- `everything-server.ps1 -Era Legacy|Dual`, zweite Conformance-Instanz am Legacy-Wire.
- **Exit:** `--requirements 2025-11-25` Server 30/30 und Client 18/18; `2026-07-28` weiterhin grün auf der Dual-Instanz; Kompatibilitätsmatrix aus `basic/versioning` als Pester-Tabelle (alle acht Kombinationen).

### M6 Authorization
- Client-OAuth-Provider (siehe 2.2), Loopback-Listener, Token-Store, Refresh, Step-up; Server-Bearer-Middleware, PRM-Endpoint, JWT-Validierung (JWKS-Cache, RS256/ES256 via .NET, `aud`/`iss`/`exp`), Introspection-Hook, Scope-Hierarchie.
- **Exit:** alle 25 Client-`auth/*`-Szenarien der 2026-07-28-Anforderungsliste; Pester für 401/403-Challenges und Audience-Bindung; Security-Review der Redirect-/State-/`iss`-Pfade.

### M7 Extensions
- Tasks (Server-Store, Gating, drei Methoden, Notifications; Client-Polling/Persistenz), Skills (Manifeste, Directory-Read), Apps-Serverseite, Auth-Extensions (Client Credentials mit RS256-JWT-Signierung über `System.Security.Cryptography.RSA`; Enterprise-Managed Authorization).
- **Exit:** `tasks-*` (10) grün; `auth/client-credentials-jwt/-basic`, `auth/enterprise-managed-authorization`; Pester für Skills und Apps; Extensions in Dokumentation als opt-in gelistet.

### M8 DX, Dokumentation, 1.0
- Discovery-Stile (Attribut, Ordner, Allowlist), `Register-McpClientConfig`, `Get-McpLauncherCommand`, `New-McpServerProject`, `Test-McpServer`, Beispiele, PlatyPS-Hilfe und about-Topics, Konzept-Docs, Performance-Pass (vorserialisierte Listen, Schema-Cache, Lazy-JsonNode-Passthrough), Floor-Bump-Plan, Release 1.0.0.
- **Exit:** Baseline leer für beide Anforderungslisten; `tier-check --requirements 2025-11-25,2026-07-28` ohne Blocker außer Governance-Historie; Gallery-Release 1.0.0; Roadmap für Tier-Antrag.

---

## 8. Teststrategie und Verifikation

### 8.1 Toolchain-Bootstrap im Linux-Container (kein pwsh vorhanden)

```bash
# Variante A: apt aus packages.microsoft.com (Ubuntu 24.04 'noble', erreichbar; enthält powershell 7.6.x, powershell-lts 7.4.x)
curl -sSL -o /tmp/pmp.deb https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb
dpkg -i /tmp/pmp.deb && apt-get update && apt-get install -y powershell-lts    # oder: powershell (7.6)
# Variante B: Release-Tarball (Redirect auf release-assets.githubusercontent.com ist erreichbar)
curl -sSL -o /tmp/pwsh.tgz https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-linux-x64.tar.gz
mkdir -p /opt/pwsh && tar -xzf /tmp/pwsh.tgz -C /opt/pwsh && chmod +x /opt/pwsh/pwsh && ln -sf /opt/pwsh/pwsh /usr/local/bin/pwsh
pwsh -NoProfile -Command '$PSVersionTable.PSVersion'
```
`builds.dotnet.microsoft.com` ist gesperrt (irrelevant, kein dotnet nötig). PSGallery-Erreichbarkeit für `Install-PSResource` ist in M0 zu prüfen; Fallback: Nupkgs über `registry.npmjs.org`-analoge Spiegel sind nicht verfügbar, daher notfalls `tools/*.nupkg` einchecken.

### 8.2 Lokale Läufe

```powershell
./build.ps1 -Bootstrap                     # Abhängigkeiten
./build.ps1 -Task Analyze                  # PSScriptAnalyzer inkl. Custom-Regeln, -EnableExit
./build.ps1 -Task Test                     # Pester 6: Unit + Integration, NUnit-XML, JaCoCo (Convert-CodeCoverage auf src/)
./build.ps1 -Task Conformance              # startet everything-server (Modern :3001, Legacy :3002) und ruft npx auf
```

```bash
npx --yes @modelcontextprotocol/conformance@0.2.0-alpha.11 server --url http://127.0.0.1:3001/mcp --requirements 2026-07-28 --expected-failures conformance-baseline.yml
npx --yes @modelcontextprotocol/conformance@0.2.0-alpha.11 server --url http://127.0.0.1:3002/mcp --requirements 2025-11-25 --expected-failures conformance-baseline.yml
npx --yes @modelcontextprotocol/conformance@0.2.0-alpha.11 client --command "pwsh -NoProfile -NonInteractive -File tests/conformance/everything-client.ps1" --requirements 2026-07-28 --expected-failures conformance-baseline.yml
npx --yes @modelcontextprotocol/conformance@0.2.0-alpha.11 client --command "pwsh -NoProfile -NonInteractive -File tests/conformance/everything-client.ps1" --requirements 2025-11-25 --expected-failures conformance-baseline.yml
npx --yes @modelcontextprotocol/inspector --cli pwsh -NoProfile -NonInteractive -File examples/echo-server.ps1 --method tools/list
```
Die Stable-Version 0.1.16 der Conformance-Suite kennt 2026-07-28 nicht; der Alpha-Pin wird in `requirements.psd1` geführt und periodisch gegen `latest` geprüft. Baseline-Syntax: `scenario` oder `scenario:check-id` (ohne Leerzeichen).

### 8.3 Testtaxonomie
- **Unit:** Codec-Roundtrips (id-Typ, Zahlen, leere Arrays, `null` vs. abwesend, Tiefe, Unicode), Schema-Generator (Typmatrix, Attribute, Hilfe), Validator-Adapter (2020-12, `$ref`-Ablehnung, Bounds, Fallback-Parität), Router/Meta/Fehlercodes, Header-Validierung (Sentinel, Numerik, Case), SSE-Parser, Era-Detection-Tabellen, Legacy-Session-Automat, WWW-Authenticate-Parser, PKCE/`iss`-Tabellen, requestState-HMAC.
- **Integration:** InMemory-Client↔Server, stdio-Subprozess (Framing, EOF, stderr-Trennung, Exit-Codes, Kill-Tree, Non-ASCII), HTTP auf 127.0.0.1 (JSON/SSE, Listen-Streams parallel zu Tool-Calls, Disconnect→Cancel, Origin 403), Dual-Era auf demselben Endpoint, Concurrency (N parallele Calls, Timeouts, `BeginStop`), Windows-Encoding-Harness (Node/Python-Client mit Non-ASCII-Argumenten).
- **Spec:** jede `schema.json`-Definition mit Konstruktor-/Parser-Test; Wire-Nachrichten beider Ären gegen das jeweilige Schema validiert.
- **Conformance:** wie 8.2, in CI mit Baseline; `tier-check` als nightly.
- **Compat:** 5.1-Guard, 7.4/7.5/7.6-Matrix, 7.7-Preview als allowed-failure-Lane.

### 8.4 CI-Pipeline
`ci.yml`: lint (ubuntu) → test (Matrix, gepinnte pwsh-Installation per Tarball/Zip in `$GITHUB_PATH`, `shell: pwsh`) → ps51-guard (windows) → conformance (ubuntu, node 20, Alpha-Pin, Baseline) → package. `release.yml` bei Tags `v*`: CI wiederverwenden, `Publish-PSResource` in geschütztem Environment mit `PSGALLERY_API_KEY`, GitHub-Release mit Nupkg und CHANGELOG-Abschnitt. Actions per SHA gepinnt.

---

## 9. Risiken und Gegenmaßnahmen

| Risiko | Gegenmaßnahme |
|---|---|
| Runspace-Affinität/Handler-Vertrag überrascht Nutzer (Closures, Modul-Variablen) | Klarer Vertrag in Hilfe und Fehlermeldung bei Registrierung (Erkennung von `$using:`/freien Variablen per AST), serieller Modus `-MaxConcurrency 1` als Notausgang. |
| stdout-Verschmutzung (ConsoleHost-Routing, Write-Host in Handlern, native Kindprozesse) | Hostloser Pool, Custom-PSSA-Regel, Dokumentation für `Start-Process`-Redirects, Integrationstest mit absichtlicher Verschmutzung. |
| HttpListener-SSE-Verhalten auf Linux/macOS (Chunk-Flush, Disconnect-Erkennung, Backlog) | M2-Experimente als Tests; Keep-alive als Disconnect-Probe; JSON-only-Modus als Fallback; Host-Abstraktion für spätere Adapter. |
| JsonSchema.Net-API-Drift zwischen pwsh-Versionen | Adapter mit Versions-Probing, Fallback-Validator, Matrix-Tests auf 7.4.0/7.4.x/7.5/7.6. |
| ConsoleHost-Stdin-Vorlesen unter `-File`, Windows-Konsolencodierungen | Roh-Streams, Windows-Harness in M1, notfalls Launcher-Wrapper. |
| Conformance-Alpha instabil, `pending`-Szenarien | Versions-Pin, Baseline, Szenarien trotzdem ausführen. |
| Legacy-Komplexität wächst in den Kern | Strikte Trennung `Legacy/`, era-bewusste Serialisierung an genau einer Stelle, Kompatibilitätsmatrix als Test. |
| OAuth-Flows (Loopback-Ports, Browser, Token-Store) | Feste Ports in CIMD/DCR, Headless-Fallback, Token-Store-Interface mit In-Memory-Default. |
| Performance des PowerShell-JSON-Walkers bei großen Payloads | Lazy-Passthrough von `JsonNode`, vorserialisierte Listen, Schema-Cache, Benchmarks in M1/M8. |
| Gallery-Name nicht verfügbar | Prüfung in M0, Fallback `ModelContextProtocol.Sdk`; Präfix `Mcp` bleibt. |
| 7.4/7.5 EOS im November 2026 | Floor-Bump auf 7.6 im ersten Release danach; 7.5 nur bis EOS in der Matrix. |

---

## 10. Offene Fragen an den Product Owner (mit Empfehlung)

1. **Gallery-Name bei Kollision:** Falls `ModelContextProtocol` belegt ist: `ModelContextProtocol.Sdk`? Empfehlung: ja, Präfix unverändert.
2. **`requestState`-Schlüssel:** Default zufällig pro Prozess (Retry nach Server-Neustart verlangt erneute Eingabe) oder Pflicht zur Konfiguration bei HTTP? Empfehlung: zufälliger Default mit Warnung auf stderr; bei `-Transport Http` Pflichtparameter, sobald `-MaxConcurrency > 1` über mehrere Prozesse skaliert wird (dokumentiert).
3. **Frühe Previews auf PSGallery:** `0.1.0-preview1` nach M2 veröffentlichen? Empfehlung: ja (Namensreservierung, Feedback), mit klarem Prerelease-Tag.
4. **HTTP+SSE-2024-11-05-Client-Fallback:** in M8 optional umsetzen oder streichen? Empfehlung: streichen, sofern kein konkreter Zielserver es braucht.
5. **Token-Store-Adapter:** `Microsoft.PowerShell.SecretManagement` als optionale (nicht required) Abhängigkeit akzeptabel? Empfehlung: ja, als Adapter ohne `RequiredModules`-Eintrag.
