# Relay — Android client (project context)

You are building the **Android client** for Relay, an end-to-end-encrypted
messenger. A complete iOS client, a Go relay server, and the protobuf wire
schema already live in this monorepo (repo root). **The existing repo is the
source of truth for the protocol. Your job is to build an Android app that
interoperates with it byte-for-byte — not to invent anything.**

Owner: Ethan. Users are primarily in Australia. Relay is iOS-shipping today; this
is the second client. Keep the wire format language-neutral (a Windows client may
follow).

## First task (before any app code)

Read and summarize the contract, then get sign-off:
- `../proto/relay.proto` (server-visible envelopes + WS frames) and
  `../proto/content.proto` (client-only plaintext). **Codegen Kotlin from these**;
  never hand-transcribe field numbers.
- `../server/README.md` — the full REST + WebSocket API (auth, endpoints, fan-out,
  at-least-once delivery, sealed sender, queue/ack, directory/OPRF, groups, backup).
- Root `../CLAUDE.md` and the iOS sources (`../Relay/`, `../CryptoCore/`,
  `../SecureStorage/`, `../RelayKit/`, `../RelayCore/`) — to mirror behavior.

Produce `android/PROTOCOL.md`: every endpoint, every `content.proto` field number,
and every crypto parameter you must match. **Have the owner review it before Stage 1.**

## Non-negotiable interop requirements (must match iOS exactly)

- **libsignal**: official `org.signal:libsignal-client` / `libsignal-android`, the
  **same 0.97.x version** as iOS. PQXDH session establishment with a **mandatory
  Kyber last-resort prekey**, Double Ratchet, sender-key groups, safety numbers.
- **Sealed sender**: embed the **same trust-root public key** the server logs at
  startup; validate the Go-minted `SenderCertificate`; send via `sealedSenderEncrypt`
  + the unauthenticated `POST /v1/messages/sealed` with the destination access key;
  receive handles **both** sealed (empty envelope sender) and unsealed formats.
- **Blinded discovery**: ristretto255 2HashDH OPRF with the **exact domain tags**
  `Relay-OPRF-v1-h2g` and `Relay-OPRF-v1-token`; use libsodium (`lazysodium-android`)
  ristretto ops (`crypto_core_ristretto255_from_hash`, `scalar_random`,
  `scalar_invert`, `crypto_scalarmult_ristretto255`). Verify byte-identical
  blinded/unblinded values against the Go/iOS implementation.
- **Auth**: implement the **`Relay-Sig` request-signature scheme** — ECDSA-P256 (ASN.1)
  over SHA-256 of `METHOD "\n" PATH "\n" TIMESTAMP "\n" NONCE`, with headers
  `Authorization: Relay-Sig <accountId>.<deviceId>:<base64 sig>`, `X-Relay-Timestamp`
  (unix ms), `X-Relay-Nonce` (base64). Sign with the device auth keypair. HTTP Basic
  is legacy fallback only.
- **Delivery semantics**: at-least-once; **dedup by envelope id** (incoming msg id ==
  envelope id); exact per-device fan-out — cover every registered device of the
  destination with matching registration ids, on `MISMATCHED_DEVICES` re-fetch bundles
  and retry once; ephemeral envelopes (typing) skip the queue; failed decrypts are
  acked and dropped (poison-message protection).

## Platform mappings (each is a decision — propose and get approval)

- **Push: APNs → Firebase Cloud Messaging (FCM).** Preserve the **contentless-push**
  model: a data-message wake carries no message content; the client fetches
  `GET /v1/queue`, decrypts on-device, acks via `POST /v1/messages/ack`. ⚠️ This needs
  a **server-side FCM sender** added alongside the existing APNs one — propose it but
  flag it for the owner; it touches the shared `../server/` and must stay consistent
  with the contentless-push design.
- **Secure storage:** Secure Enclave/Keychain → **Android Keystore** (hardware-backed,
  StrongBox when available). DB: **SQLCipher for Android**, master key wrapped by a
  Keystore key. Identity private key + registration id live only in Keystore.
- **Backup:** CloudKit → **Google Drive app-data folder** (or a generic encrypted-blob
  target), same E2E model with a 32-byte **Recovery Key** + HKDF-derived AES-GCM.
- **Calls:** Google **WebRTC Android**; same relay signaling; Private Call Mode
  (TURN-only) preserved.
- **Deep links:** Universal Links → **Android App Links** for `/c/*` (contact) and
  `/g/*` (group invite).
- **UI:** SwiftUI / Liquid Glass → **Jetpack Compose + Material 3** (equivalent, not a
  pixel copy).

## Feature parity target (match the iOS app)

1:1 + group E2EE messaging, reactions, replies, typing, edits/unsend, media/attachments
(AES-GCM blobs), voice notes, live location (single moving bubble), polls, scheduled
messages, disappearing behavior, profiles (display name + avatar, E2EE distribution),
safety-number verification (QR), blocking, sealed-sender toggle, send-delay/jitter,
notification-privacy modes, panic/emergency wipe, contact discovery + one-time invite
links, multi-device self-sync.

## Process (hard rule)

Build in **stages with an owner check-in between each**, mirroring the iOS build:
1. Project setup (Gradle, JDK 17, min/target SDK) + libsignal-android + generated protos.
2. Crypto core (PQXDH, ratchet, sender keys, safety numbers, sealed sender, OPRF).
3. Secure storage (Keystore-wrapped SQLCipher; identity in Keystore).
4. Networking (REST + WebSocket + `Relay-Sig` auth; prekey maintenance).
5. Core messaging UI (Compose).
6. Push (FCM, contentless), then discovery / groups / media / calls / backup.

**Write an interop test at each stage against the live relay
(`https://api.relaymsg.app`)** proving an Android↔iOS message round-trips. **Do not
build ahead. Stop and check in between stages** — the owner reviews crypto/storage
layers especially.

## Tooling notes

- Requires Android Studio + JDK 17 + Android SDK + an emulator on the owner's Mac.
  Claude Code writes the code; the owner builds/runs in Android Studio.
- Anything affecting the wire → also update `../proto/` and `../server/README.md`, and
  keep the iOS client in sync (raise it with the owner; the iOS/server session handles it).
