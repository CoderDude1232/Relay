# Relay — TODO

## NEXT: deploy + device-test the built batch

A batch of changes is coded/committed but not live or not device-tested. Verify
before building on top. Full checklist in [`TESTING.md`](TESTING.md).
- [ ] Redeploy server (contentless push, email-at-rest, encrypted groups, sealed
      sender, blinded discovery). Verify email backfill + no plaintext `email` column.
- [ ] Two-physical-device pass: push (default + opt-in), multi-device sync, iCloud
      backup/restore, groups, sealed sender. (Simulators can't do APNs/CloudKit.)
- [ ] Deploy the CloudKit **production** schema (dev schema won't work for release).

## Website copy (non-app, keeps marketing claims honest)
- [ ] Contacts claim → "hashed & blinded on-device; server never learns contacts"
      (don't say "never reads your contacts" — the app reads the address book locally).
- [ ] Location claim → "only if you share live location; off by default; E2E" (drop
      "no location permission of any kind").
- [ ] Push claim → the strong "content-free wake" wording is now TRUE by default; keep
      it, optionally note the opt-in "Include Message in Push" toggle.

## Security: replace reusable Basic-auth device passwords with request signatures

**Why:** REST + WS auth is HTTP Basic `"<accountId>.<deviceId>":devicePassword` — a
**reusable secret** that crosses the wire on every request. Any TLS-terminating hop
(a future proxy/edge), a leaked log, or a captured request exposes a credential that
can be replayed indefinitely. Signatures fix this: nothing replayable ever transits.

**Design (reuse existing infra):** every device already has a **P256 auth keypair**
whose private key stays on-device (today it signs nuke commands; server stores only
`devices.auth_public_key` and verifies via `verifyNukeSignature`). Reuse it to sign
each request. The server already has the verify primitive.

**Wire format (proposed):**
- Header `Authorization: Relay-Sig <accountId>.<deviceId>:<base64 ECDSA-P256 sig>`
- Headers `X-Relay-Timestamp` (unix ms) and `X-Relay-Nonce` (random, base64).
- Canonical signed string: `METHOD "\n" PATH "\n" TIMESTAMP "\n" NONCE`.
  **Body is intentionally NOT signed** — hashing 26 MB attachment uploads on-device is
  wasteful, and body integrity is already covered by TLS. The goal is "credential not
  replayable if observed," not defending an active MITM at a terminating hop (that's
  game-over regardless).
- Server accepts the signature IFF: signature valid against `dev.AuthPublicKey`,
  timestamp within ±5 min, and nonce unseen recently (small in-memory LRU per device to
  block same-request replay inside the window).

**Transition (non-breaking):**
1. ✅ Server `auth()` accepts **either** `Relay-Sig` **or** Basic (added; Basic still works).
2. Client: plumb the device auth private key into `RelayAPIClient`/`RelayWebSocket`; sign
   every REST request + the WS upgrade. Extensions (NSE, Share) must sign too.
3. Once all clients ship signatures, drop Basic auth from `auth()` (breaking; gate on a
   minimum-client-version check).

**Status:** server-side accept-either verifier + unit test done; client signing + the
eventual Basic-auth removal remain.



## Transport: QUIC status

**Congested-network connectivity (stadiums) — addressed:**
- **Send** already rides QUIC: with sealed sender default-on, outbound messages
  go via `POST /v1/messages/sealed` over HTTP/3, not the WebSocket.
- **Receive** now has a QUIC fallback: `runQueuePollLoop` polls `GET /v1/queue`
  over HTTP/3 every 5s whenever the TCP WebSocket isn't connected, acking via
  `POST /v1/messages/ack`. WebSocket stays the primary low-latency path; dedup by
  envelope id makes overlap harmless. So messaging works even when TCP can't
  connect — just at poll latency for receive.
- REST control plane already races QUIC/HTTP-3 (`assumesHTTP3Capable`).

**Remaining (optional, for live-latency receive over QUIC):** a raw-QUIC live
channel so live receive isn't limited to the 5s poll when TCP is blocked.

## (Optional) raw-QUIC live channel

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

## Infrastructure: DDoS protection + origin-IP hiding (deferred)

**Deferred by decision (2026-09-15): keep current Binary Lane infra for now.**

**Problem:** The origin is a Binary Lane (AU) VPS. Binary Lane's only DDoS response is
**null-routing / black-holing** — under attack they drop *all* traffic to the target IP
upstream (legit included), i.e. you go offline. That's the opposite of scrubbing. The
origin IP is also public (DNS-only / grey; correct for now — see below).

**Why not Cloudflare proxy:** orange-cloud and `cloudflared` both terminate TLS at
Cloudflare's edge, so Cloudflare would see client IPs, HTTP Basic-auth device passwords,
recipient-bearing URLs, sealed-send source→dest+timing, and ciphertext — a metadata/creds
regression for a privacy messenger. They also break the transport: Cloudflare never speaks
QUIC/HTTP-3 to origin (edge-only), and proxied WebSockets are HTTP/1.1 with a ~100s idle
timeout (our 25s keepalive only just survives it). Confirmed against CF docs.

**Key insight:** DDoS protection does NOT require TLS termination. Volumetric attacks are an
L3/L4 (packet) problem, scrubbed without decryption. So we can get scrubbing AND keep zero
third-party plaintext AND keep end-to-end QUIC/WebSocket.

**Options when we tackle this (AU-latency-sensitive):**
- **Tier 0 (simplest):** move origin to **OVH Sydney** — free always-on L3/4 scrubbing
  (~1.3 Tbit/s), sub-10 ms to Sydney/Melbourne, APP-compliant/onshore, keeps our own
  TLS/QUIC/WS. Caveat: OVH APAC *VPS* plans have a monthly traffic quota (1 TB VPS-1/2,
  3 TB VPS-3/4, then throttled to 10 Mbps) — size up or use bare-metal (no cap).
- **Tier 1 (also hide origin IP):** OVH Sydney **edge VPS** doing **L4 passthrough**
  (`nginx stream` TCP+UDP 443, or WireGuard) to a hidden origin (can stay on Binary Lane,
  firewalled to accept only the tunnel). Attacks hit the scrubbed edge; the origin's
  black-hole-prone IP is never targeted. Both in AU → few-ms extra hop. Passthrough → TLS
  terminates only on origin, nobody sees plaintext, QUIC/WS preserved. SPKI pin is unchanged
  (origin cert is untouched in passthrough).
- **Tier 2 (enterprise):** Cloudflare **Magic Transit** (L3 BGP scrubbing, no TLS
  termination) or **Spectrum UDP** — real but needs a /24 + BGP / Enterprise pricing.
- **App-layer (L7) floods** (hammering the WS handshake or `/v1/messages/sealed`) aren't
  covered by L3/4 scrubbing — rely on the existing in-app rate limiters, plus an optional
  no-decrypt `limit_conn` at the passthrough edge.
- **Optional flair:** a **Tor onion service** as a secondary endpoint has no public IP to
  flood and is censorship-resistant (high latency → fallback, not primary).

**Recommendation when revisited:** Tier 1 (OVH Sydney passthrough edge → hidden Binary Lane
origin) gets DDoS scrubbing + IP hiding + zero third-party plaintext + full QUIC, onshore.
