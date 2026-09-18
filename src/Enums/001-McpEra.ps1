# Protocol era of a peer, a session or a single message.
#   Modern: the stateless lifecycle of revision 2026-07-28 (per-request _meta, server/discover, MRTR).
#   Legacy: the initialize-handshake lifecycle of 2025-11-25 and 2025-06-18 (2025-03-26 is accepted as a
#           version string without additional features).
enum McpEra {
    Modern = 0
    Legacy = 1
}
