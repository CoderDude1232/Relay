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
- The database uses a rollback journal, not WAL: an open WAL connection keeps a
  lock on the `-shm` file, and iOS kills a suspended app that holds a lock in a
  shared container (`0xdead10cc`).
- Safety numbers use the identity key of the peer's newest device; identities of
  devices the relay no longer lists are dropped when bundles are re-fetched.

## Groups

- Groups are client-authoritative; the relay keeps no group state. A group
  message is encrypted once with the sender's sender key and the same
  ciphertext is sealed per member device, so the relay sees neither the sender
  nor that the deliveries belong together. Members whose devices can't take that
  path get a pairwise sealed send instead.

## Message requests

- A 1:1 chat started by someone we've never chatted with, or a group we were
  added to by one, is a request (`conversations.accepted = 0`). Until it's
  accepted the client sends no receipts, typing or profile to them, doesn't
  download their media, and the notification never shows message text.
  Starting a chat with them or sending a message accepts it.

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
- Signing in on a new device: an email code or Apple/Google (through Supabase,
  plus the account password if one is set), a passkey (WebAuthn, verified by the
  relay, RP id `relaymsg.app`), or the recovery key. A passkey or the recovery
  key satisfies registration lock. Any sign-in replaces the account's devices.
- Email is optional. An account can be created with only a username and a
  passkey, and an existing account can drop its email once it has a passkey;
  the relay then deletes the Supabase user and the email token.
- The recovery key is generated on the device; the relay stores only
  SHA-256("relay-recovery-key-v1|" + normalised key).
- The chat list kept with the account ("RAS2") is encrypted under a random
  content key, wrapped in slots: one for the account password (Argon2id), one
  per passkey (WebAuthn PRF output through HKDF), one for the recovery key.

## Calls

- Every call goes through CallKit (1:1, group, call links, foreground or not);
  only the Mac app, which has no CallKit, rings in-app. Calls to a closed app
  are rung by an anonymous VoIP push carrying only the call id; the encrypted
  OFFER or GROUP_RING says who's calling, and the push's CallKit call takes
  that identity.
- The OFFER carries the caller's ICE candidates (gathered before it's sent),
  because trickled candidates are ephemeral and a closed app would never get
  them. The notification extension keeps every call signal it decrypts, in
  order, for the app to replay after the push wakes it.
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
