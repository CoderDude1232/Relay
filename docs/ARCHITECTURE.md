# Relay architecture notes

Design decisions that the iOS client, the relay (`server/`) and any other client
must agree on. The wire contract itself is `proto/` plus `server/README.md`.

## Cryptography

- **PQXDH.** Sessions use libsignal's PQXDH, so every prekey bundle carries a
  Kyber prekey. Each device keeps a pool of one-time Kyber prekeys (ids with bit
  0x800000 set, deleted after use) and one last-resort Kyber prekey that bundles
  fall back to when the pool is empty.
- **libsignal is vendored.** Upstream has no root `Package.swift`, so it is
  checked out under `third_party/` by `scripts/setup-libsignal.sh`. The prebuilt
  Rust FFI is linked through per-SDK `LIBRARY_SEARCH_PATHS` on the app target;
  package test bundles pass `-L` via `unsafeFlags`.
- **Identity trust is TOFU.** A changed peer identity key becomes untrusted and
  clears the peer's `verified` flag until the user re-verifies the safety number.

## Local storage

- Messages live in a SQLCipher database in the App Group container
  (`group.app.relaymsg`) so the notification extension can read it.
- The 32-byte database key is ECIES-wrapped by a Secure Enclave P-256 key; the
  wrapped blob is in the Keychain (`AfterFirstUnlockThisDeviceOnly`, App Group
  access group). The simulator falls back to a Keychain-only item.
- The identity private key and registration id are stored only in the Keychain.

## Groups

- Groups are client-authoritative; the relay keeps no group state. A group
  message is encrypted once with the sender's sender key and the same
  ciphertext is sealed per member device, so the relay sees neither the sender
  nor that the deliveries belong together. Members whose devices can't take that
  path get a pairwise sealed send instead.

## Delivery

- **At-least-once.** The relay queues before pushing and deletes on client ack;
  clients de-duplicate by envelope id (the incoming message id is the envelope
  id). Ephemeral envelopes such as typing indicators never queue.
- Receipts reference the sender's timestamps, and "read" never downgrades to
  "delivered".
- **Fan-out.** `SendRequest.destination_account` is an opaque mailbox id and each
  frame carries exactly one device message, so a sender sends one frame per
  recipient mailbox. The response's missing/extra/stale device lists trigger a
  bundle re-fetch so every device of the recipient is covered (minus the
  sender's own device on self-sends). Sealed-sender messages use the
  unauthenticated `POST /v1/messages/sealed` path instead.
- Key bundles are fetched anonymously with the peer's access key, which comes
  from the blinded directory entry; the signed fetch is only a fallback.

## Authentication

- Requests are signed with `Relay-Sig` (per-request ECDSA P-256 with the
  device's auth key), for REST and the WebSocket upgrade. HTTP Basic
  (`<accountUUID>.<deviceId>` / device password) is only used to register that
  auth key.

## Calls

- Calls are relay-only by default: media goes through TURN so peers never see
  each other's IP address. The relay hands out our own coturn while it's healthy
  and falls back to Cloudflare Realtime TURN when it's down, overloaded or near
  its monthly transfer allowance (`server/cmd/turnload`); live calls reconnect
  with an ICE restart. See `server/README.md`, "TURN failover".

## Known trade-offs

- After a device-mismatch response the client re-processes all of the peer's
  bundles, which can reset healthy sessions. Wasteful but correct.
- A message that fails to decrypt is acked and dropped, so one bad envelope
  can't block the queue.
- `GET /v1/accounts/by-username` is a plaintext legacy lookup; current clients
  use blinded discovery.
