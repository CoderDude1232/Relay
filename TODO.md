# Relay — TODO

## Transport: move the live channel to QUIC (UDP)

**Problem:** The real-time channel — all live message delivery — runs over **TCP**.
It uses `URLSessionWebSocketTask` (`RelayKit/Sources/RelayKit/RelayWebSocket.swift`),
which Apple defines as WebSocket framing "over TCP and TLS" (RFC 6455). The
`request.assumesHTTP3Capable = true` on that WebSocket request
(`RelayWebSocket.swift:73`) is a **no-op** — the flag only affects HTTP requests,
not WebSocket tasks. Only the REST control-plane (`RelayAPIClient.swift:431`)
actually races QUIC/HTTP‑3.

**Goal:** Carry live messaging over QUIC/UDP, with a TCP-WebSocket fallback for
networks that block UDP/443.

**Work:**
- Client: replace `URLSessionWebSocketTask` with a raw QUIC connection via
  Network.framework `NWProtocolQUIC` (iOS 15+); run the existing protobuf frames
  over a QUIC stream. Keep the WebSocket path as automatic fallback.
- Server: add a listener that accepts a bare QUIC stream and speaks the same
  frame protocol (current quic-go serves HTTP/3, not a raw QUIC endpoint).
- ~~Remove `assumesHTTP3Capable` from the WebSocket path~~ **DONE** — it was NOT
  harmless: on a physical device it made iOS attempt the WebSocket over HTTP/3,
  which the server doesn't support for WebSockets, so the socket was RST ("Socket
  is not connected", POSIX 57). Removed in `RelayWebSocket.swift`.

Not WebTransport — iOS has no native client API for it.
