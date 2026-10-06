# Relay — project context

Relay is an end-to-end-encrypted messenger. **iOS-only for now** (a Windows/WinUI
client may come later — keep the wire format language-neutral). We own **every
layer**: the Go relay server, the protobuf wire schema, and the iOS app. There is
no external spec to match; the source of truth for the protocol is this repo.

Owner: Ethan (ethandaly525@gmail.com). Targets sign with Apple team
`HK396F3767` (paid Developer Program — APNs, TestFlight); the project-level
setting still names the old free team `2P24M8G2CJ`. Bundle id `app.relaymsg`.
Production relay: `https://api.relaymsg.app` (VPS, PostgreSQL).

## Build order and status

Staged plan with a **user check-in between stages** (don't build ahead):

1. ✅ Xcode project setup (app + NSE targets, App Group, vendored libsignal)
2. ✅ Crypto core (`CryptoCore/`) — 6 tests passing
3. ✅ Secure storage (`SecureStorage/`) — 6 tests passing
4. ✅ Networking (`RelayKit/`) — unit + live e2e test against real relayd passing
5. ✅ Core messaging UI — working on 2 simulators + user's iPhone over LAN
6. ✅ Push/NSE — APNs (paid membership acquired) + FCM for Android; contentless
   wake by default with opt-in ciphertext-in-push. NSE fetches from `GET /v1/queue`.
7. ✅ Shipped since: safety-number verification UI, groups (client-authoritative,
   fully E2E — the relay keeps **no** group state), media/attachments, calls
   (WebRTC + TURN), profiles, sealed sender, blinded discovery, encrypted iCloud
   backup, device linking, remote wipe (nuke), and `Relay-Sig` request-signature
   auth. Now underway: an **Android client** (`android/`) and hardening — see
   `TODO.md`. Current focus is deploy + device-testing the built batch (`TESTING.md`).

## Repo layout

This is a **monorepo** (see root `README.md`): `proto/` is the shared protocol
source of truth; `server/` is the Go relay; the iOS app + Swift packages live at
the repo root (Xcode synced-group constraint — do **not** relocate them); `android/`
is the Android client (Kotlin, its own `android/CLAUDE.md`) and must interoperate
with the same wire contract. Wire-affecting changes land in `proto/` +
`server/README.md` and stay in sync across both clients.

- `proto/relay.proto` — server-visible wire format (envelopes, WS frames).
  `proto/content.proto` — client-only plaintext structure (text/receipt/typing),
  encrypted before it ever hits the wire. Server never parses Content.
- `server/` — Go relay (`go build ./...` from `server/`). PostgreSQL (pgx;
  `-dsn`), gorilla/websocket, bcrypt. Store tests need `RELAY_TEST_DSN`. Tests: `go test ./...`. API contract
  documented in `server/README.md` — **keep it in sync with the code**.
- `CryptoCore/` — Swift package wrapping libsignal. One entry type,
  `CryptoEngine`: prekey publication, PQXDH session establishment
  (`processPeerBundle`), Double Ratchet encrypt/decrypt (`SecureMessage`),
  safety numbers. Stores behind `SignalStores` typealias.
- `SecureStorage/` — Swift package: `Database` (thin SQLCipher wrapper),
  `SQLCipherSignalStore` (all six libsignal store protocols),
  `KeychainSecureStore` (SE-wrapped DB master key + Keychain-only identity),
  `MessageStore` (conversations/messages), `SecureStore` (composition root —
  renamed from `SecureStorage` because it collided with the module name).
- `RelayKit/` — Swift package: `RelayAPIClient` (JSON REST), `RelayWebSocket`
  (actor, one connection, protobuf frames), `PreKeyMaintainer` (threshold 20,
  batch 100), checked-in generated protos in `Sources/RelayKit/Generated/`.
- `Relay/` — **the app target's source root** (file-system-synchronized group:
  files dropped here join the target automatically; do NOT create `Relay/Relay/`
  — that mistake produced duplicate sources once already). Key files:
  `MessagingService.swift` (orchestrator), `AppModel.swift` (composition root),
  views. `NotificationServiceExtension/` is the NSE target.
- `third_party/` — **git-ignored**, recreated by `scripts/setup-libsignal.sh`:
  libsignal v0.97.4 checkout + prebuilt `libsignal_ffi.a` (device/simulator).
- Xcode packages: the three local packages + libsignal's `swift/` dir are added
  as **local** SPM packages; remote deps are `skiptools/swift-sqlcipher` (≥1.11)
  and `apple/swift-protobuf` (≥1.38).

## Non-negotiable protocol/security decisions (user-approved)

- **PQXDH, not classical X3DH** — user approved the switch 2026-07-19 because
  libsignal 0.97 removed classical-only bundles (Kyber prekey is mandatory in
  the API). Every bundle carries a **last-resort Kyber prekey** (single per
  device, replaced on upload, marked used but never deleted; no one-time Kyber
  pool yet).
- libsignal is **vendored** (no root Package.swift upstream → remote SPM is
  impossible). Prebuilt Rust ffi linked via per-SDK `LIBRARY_SEARCH_PATHS` on
  the app target; test bundles pass `-L` via `unsafeFlags` in each Package.swift.
- SQLCipher-encrypted DB in the **App Group container**
  (`group.app.relaymsg`).
  Master key: 32 bytes, ECIES-wrapped by a Secure Enclave P-256 key, wrapped
  blob in Keychain, `AfterFirstUnlockThisDeviceOnly`, App Group access group.
  Simulator fallback: Keychain-only (separate item name).
  **Identity private key + registration id live only in the Keychain.**
- Identity trust: TOFU; a changed peer key becomes untrusted and resets the
  `verified` flag (this drives the future safety-number-changed UI).
- Delivery: **at-least-once**. Server queues before push, deletes on client ack;
  clients dedup by envelope id (incoming message id == envelope id). Ephemeral
  envelopes (typing) never queue. Receipts reference sender timestamps; read
  never downgrades to delivered.
- Fan-out: `SendRequest.destination_account` is an **opaque mailbox id** and
  each frame carries **exactly one** device message; the sender sends one frame
  per recipient mailbox. The response's missing/extra/stale device lists drive a
  bundle re-fetch so the sender covers all of a recipient's devices (minus own
  device on self-sends). Sealed sends go over the unauthenticated
  `POST /v1/messages/sealed` path instead.
- Auth: `Relay-Sig` per-request ECDSA-P256 signatures (preferred; keyed on the
  device auth key) **or** HTTP Basic `"<accountUUID>.<deviceId>" : devicePassword`
  during the transition — for both REST and the WS upgrade. See `server/README.md`.
- UI: SwiftUI + Liquid Glass (glass on chrome only, flat fills for bubbles).

## Deliberate gaps (not bugs)

- On mismatch retry the client re-processes ALL bundles (may reset healthy
  sessions — wasteful but correct; acceptable for now).
- Failed decrypts are acked and dropped (poison-message protection).
- No one-time Kyber prekey pool — last-resort Kyber prekey only.
- Group sends in sealed-sender mode are pairwise (per-member), not sender-key.
- `GET /v1/accounts/by-username` is plaintext legacy; new code uses blinded discovery.

(Typing-indicator send/receive, self-sync to own devices, and device linking now
exist — they used to be listed here. The Keychain/Secure-Enclave path is
device-verified.)

## Dev environment quirks (this Mac)

- **No Homebrew.** Go 1.26.5 → `~/sdk/go/bin`, protoc 35.1 → `~/sdk/protoc/bin`,
  protoc-gen-go → `~/go/bin`, protoc-gen-swift (built from source) →
  `~/sdk/swift-protobuf/.build/release/`. None on default PATH — export per
  shell. Codegen: `server/scripts/genproto.sh` (Go); Swift protos are generated
  manually into RelayKit and checked in.
- Dev relay (stale — predates the PostgreSQL move; a local relay now needs a
  Postgres and `-dsn`): `~/.relay-dev/relayd -addr 0.0.0.0:8089 -db ~/.relay-dev/relay.db`
  (**never /tmp** — macOS wipes it on reboot, which orphans app credentials;
  Settings → Sign Out is the recovery path). `0.0.0.0` because the user's
  iPhone connects over LAN (`http://<mac-LAN-ip>:8089`; `ipconfig getifaddr en0`).
  The shipping app talks only to the HTTPS relay (`RelayConfig.serverURL`); the
  dev ATS exception was removed, so a LAN relay needs a temporary local change.
- Package tests run via xcodebuild against a simulator (prebuilt ffi has no
  macOS slice — `swift test` won't work):
  `cd <Package> && xcodebuild test -scheme <Package> -destination "id=<sim-udid>"`.
  Live e2e: start relayd, then
  `TEST_RUNNER_RELAY_SERVER_URL=http://127.0.0.1:8089 xcodebuild test -scheme RelayKit …`
  (skips itself when the env var is absent).
- Two-simulator manual testing: iPhone 17 Pro `1BA9AB70-…` + iPhone 17
  `B128009D-…`; install via `xcrun simctl install/launch`.

## Workflow rules (hard-won)

- **Never edit `Relay.xcodeproj/project.pbxproj` directly** — a harness hook
  blocks it (Xcode is open; risk of crashing it). All project-structure changes
  (targets, packages, capabilities, build settings) go to the **user with
  click-by-click Xcode instructions**; verify the result by reading the pbxproj
  afterward. App *source files* are fine to create/edit directly (synced group).
- The app target enforces `MemberImportVisibility`: any file touching a
  module's members needs an explicit `import` of that module (bites most often
  with `SwiftProtobuf` and `RelayKit`).
- App target also sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — package
  code does not; types conforming to nonisolated/Sendable protocols in app code
  need `nonisolated` (see `KVPreKeyIdAllocator`).
- Stop and check in with the user between stages; they review crypto/storage
  layers especially.

## Where to pick up

The core iOS app and its privacy program are shipped (see the build-status list
above). Current focus:
1. **Deploy + device-test the built batch** — contentless push, email-at-rest,
   groups, sealed sender, blinded discovery, multi-device sync, iCloud backup.
   Checklist: `TESTING.md`; tracked in `TODO.md` ("NEXT").
2. **`Relay-Sig` client signer** — the server accepts signatures; iOS still sends
   HTTP Basic. Plumb the device auth key into `RelayKit` (REST + WS) + extensions,
   then retire Basic. See `TODO.md` and the `relay-auth-hardening` memory.
3. **Android client** (`android/`, its own `CLAUDE.md`) — must interoperate with
   the same wire contract; the server-side FCM sender for it landed in `server/`.
4. Deferred: DDoS/origin-IP hiding (`TODO.md`).
