# Relay — TODO

## NEXT (2026-10-10)

- [ ] Two-phone device pass (`TESTING.md`): push, multi-device sync, iCloud
      backup/restore, groups, call links, mid-call TURN failover (run the outage
      test from the `relay-vps-deploy` memory while a call is up).
- [x] CloudKit **production** schema deployed (2026-10-10).
- [x] Reviewer demo accounts + export-compliance answer (2026-10-10).
- [x] Server batch deployed (contentless push, email-at-rest, groups, sealed
      sender, blinded discovery, Supabase codes, TURN failover).
- [x] Source published (AGPL-3.0), 2026-10-10.

## Siri / CarPlay sending (found 2026-10-09)

- [x] Fixed 2026-10-10: the app handles `INSendMessageIntent` itself (`SiriSendHandler`)
      and sends immediately; device-verified. Original report:
      Messages sent with Siri ("Send a Relay message to …", including in CarPlay)
      are queued by the Intents extension (`RelayIntents/IntentHandler.swift`) and
      only go out the next time the app runs, though Siri says "Sent". Fix options:
      handle `INSendMessageIntent` in the app (`application(_:handlerFor:)`, app is
      launched in the background) and remove it from the extension, or send from
      the extension directly. Needs device testing (Apple's docs are ambiguous on
      which handler wins when both claim the intent). Notification Reply
      (Watch/CarPlay) already sends immediately.
- [ ] Mac ("Designed for iPad"): register the Mac in the developer account and
      test. 1:1 calls are disabled there (no CallKit); group calls and call links
      should work.

## RESOLVED: production relay was running without `-oprf-key`

(Fixed 2026-09-18; verified 2026-10-06 — `-oprf-key /opt/relay/oprf.key` is in
the base unit, the drop-in is gone. DB password + TURN secret now live in the
root-only `/etc/relay/relayd.env`, rotated 2026-10-06. Kept below for history.)

`api.relaymsg.app` has no OPRF key configured. Consequences, live now:
- Both directory endpoints (`/v1/directory/oprf`, `/v1/directory/resolve`) return
  `503 "discovery not configured"`, so **starting any new chat by username fails**
  (`MessagingService.resolveAccount` is blinded-discovery only, by design — no
  plaintext fallback).
- `api.go`'s `emailToken()` returns nil when `s.oprf == nil`, so **no email has ever
  been stored, even as a keyed token**. Email contact sync, by-email lookup, and
  `POST /v1/accounts/recover` are all silently dead, and every account registered so
  far has **no recovery path**.

Actions:
- [x] **Redeploy `relayd` with `-oprf-key`.** DONE 2026-09-18: added
      `-oprf-key /opt/relay/oprf.key` to the systemd **override.conf** ExecStart
      (the base unit's ExecStart is dead — a drop-in overrides it). `LoadOrCreateKey`
      generated + persisted the key (`0600`). `/v1/directory/*` now returns 401
      (auth) instead of 503. Backed up off-box to `~/.relay-dev/oprf.key.backup`
      (0600, SHA-256 verified) 2026-09-18. Recommend a second copy in a password
      manager / offsite — losing it invalidates every stored token and forces a
      full index rebuild.
- [x] **Stranded accounts (registered while OPRF was off) have no stored email.**
      Superseded (checked 2026-10-14): email is optional now, and Settings >
      Change Email re-keys the account's `email_token` through the
      Supabase-verified `PUT /v1/accounts/me/email`. Accounts without an email
      sign in with a passkey or the recovery key. The planned automatic
      "re-enter your email" prompt on launch was not built.
- [x] **`resolveAccount` on 503:** decided — **surface a clear error, no silent
      plaintext fallback** (a fallback would leak the looked-up username to the relay,
      downgrading the privacy guarantee). Implemented: `resolveAccount` /
      `discoverContacts` map `503` to `DiscoveryError.unavailable` with a user-facing
      message. Stopgap; the real fix is the redeploy above.

## Website copy (non-app, keeps marketing claims honest)
- [ ] Contacts claim → "hashed & blinded on-device; server never learns contacts"
      (don't say "never reads your contacts" — the app reads the address book locally).
- [ ] Location claim → "only if you share live location; off by default; E2E" (drop
      "no location permission of any kind").
- [ ] Push claim → the strong "content-free wake" wording is now TRUE by default; keep
      it, optionally note the opt-in "Include Message in Push" toggle.

## DONE: Relay-Sig request signatures replaced Basic-auth device passwords

(Checked 2026-10-14.) Every authenticated REST call and the WebSocket upgrade
are signed with Relay-Sig v2 (`RelayKit/Sources/RelayKit/RelaySigning.swift`,
`server/internal/api/sigauth.go`); the signature covers the method, request URI,
account, device, timestamp, nonce and a SHA-256 of the body. The server accepts
HTTP Basic only on `PUT /v1/devices/auth-key` (the one-time upload of a new
device's auth key) and refuses it for any device that already has one. See
`docs/ARCHITECTURE.md`, "Authentication".

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

**Deferred by decision (2026-09-15): keep the current API origin VPS for now.**

**Problem:** The API origin VPS has no volumetric (L3/L4) DDoS scrubbing of its own.
Revisit once traffic or threat level justifies the cost.

**Why not terminate TLS at a third party:** a TLS-terminating proxy or tunnel would see
client IPs, HTTP Basic-auth device passwords, recipient-bearing URLs, sealed-send
source→dest+timing, and ciphertext — a metadata/creds regression for a privacy messenger.
It can also break the transport: CDN proxies typically don't speak QUIC/HTTP-3 to origin,
and proxied WebSockets get an idle timeout (our 25s keepalive must stay under it).

**Key insight:** DDoS protection does NOT require TLS termination. Volumetric attacks are an
L3/L4 (packet) problem, scrubbed without decryption. So we can get scrubbing AND keep zero
third-party plaintext AND keep end-to-end QUIC/WebSocket.

**Options when we tackle this (latency-sensitive — stay close to users):**
- **Tier 0 (simplest):** move the origin to a host with free always-on L3/4 scrubbing in
  the same region, keeping our own TLS/QUIC/WS. Check monthly traffic quotas on VPS
  plans (some throttle hard past the cap) — size up or use bare metal.
- **Tier 1 (also hide origin IP):** a scrubbed **edge VPS** doing **L4 passthrough**
  (`nginx stream` TCP+UDP 443, or WireGuard) to a hidden origin (can stay where it is,
  firewalled to accept only the tunnel). Attacks hit the scrubbed edge; the origin IP is
  never targeted. Same region → few-ms extra hop. Passthrough → TLS terminates only on
  origin, nobody sees plaintext, QUIC/WS preserved. SPKI pin is unchanged (origin cert is
  untouched in passthrough).
- **Tier 2 (enterprise):** Cloudflare **Magic Transit** (L3 BGP scrubbing, no TLS
  termination) or **Spectrum UDP** — real but needs a /24 + BGP / Enterprise pricing.
- **App-layer (L7) floods** (hammering the WS handshake or `/v1/messages/sealed`) aren't
  covered by L3/4 scrubbing — rely on the existing in-app rate limiters, plus an optional
  no-decrypt `limit_conn` at the passthrough edge.
- **Optional flair:** a **Tor onion service** as a secondary endpoint has no public IP to
  flood and is censorship-resistant (high latency → fallback, not primary).

**Recommendation when revisited:** Tier 1 (scrubbed passthrough edge → hidden API origin
VPS) gets DDoS scrubbing + IP hiding + zero third-party plaintext + full QUIC.
