# Relay — Android interop contract

**Status:** draft for owner review. Nothing in `android/` beyond the empty Compose
scaffold has been written yet. **Stage 1 does not start until this is signed off.**

This document is the derived contract the Android client must match. It is derived
from — and is subordinate to — the following sources, in priority order:

| Rank | Source | Why |
|---|---|---|
| 1 | `server/internal/**/*.go` | The running relay. Authoritative for every endpoint, JSON key, status code and canonical signing string. |
| 2 | `proto/relay.proto`, `proto/content.proto` | Wire schema. **Codegen from these — never hand-transcribe a field number.** |
| 3 | iOS sources (`Relay/`, `CryptoCore/`, `SecureStorage/`, `RelayKit/`, `RelayCore/`) | The behaviour a peer actually exhibits (padding, fan-out retry, sealed-sender policy). |
| 4 | `server/README.md`, root `CLAUDE.md` | Prose. **Both are stale in material ways — see §0.** |

Live relay for interop testing: `https://api.relaymsg.app` (Let's Encrypt; system
trust, no pinning). Dev relay is self-signed with an SPKI pin (`RelayTLS.devPins`).

---

## 0. Documentation drift found while reading (read this first)

These are places where `server/README.md` and the root `CLAUDE.md` disagree with the
code. In every case **I follow the code**. Each is a question for you, not a change I
have made.

1. **WebSocket fan-out is no longer "all devices in one `SendRequest`".**
   `server/internal/api/ws.go:handleSend` requires **exactly one** `DeviceMessage` per
   frame and treats `SendRequest.destination_account` as an **opaque mailbox id**, not
   an account id. Per-device fan-out is now N separate frames, one per mailbox.
   `README.md`'s "include one ciphertext for every registered device" paragraph
   describes the old model.

2. **There are no `/v1/groups*` REST endpoints.** The README documents six of them
   (`POST /v1/groups`, roster, add/remove member, rename). The code has only
   `POST /v1/group-invites` and `POST /v1/group-invites/claim`, storing an opaque
   encrypted blob. Groups are now **fully client-managed and E2EE**: roster, name,
   admins, `distribution_id` and `invite_key` all travel inside
   `content.GroupUpdate`. The relay keeps no group state at all.

3. **The README's endpoint table is missing ~15 live endpoints**, including
   `POST /v1/accounts/recover`, `GET /v1/accounts/by-email/{email}`,
   `PUT /v1/accounts/me/username`, `POST /v1/accounts/me/nuke`, the whole device-link
   family, `PUT /v1/devices/voip`, `GET /v1/devices/{id}/auth-key`,
   `GET /v1/turn-credentials`, `POST /v1/call/{account}`. §3 below lists all 40.

4. **Envelope ids are 32-char hex (16 random bytes), not UUIDs** (`newEnvelopeID`).
   Cosmetic, but don't parse them as UUIDs.

5. **Root `CLAUDE.md` is a build-stage behind the repo.** It says "Stage 7 next:
   safety-number UI, then groups", and describes auth as HTTP Basic only. The repo
   has shipped sealed sender, blinded discovery, groups, calls, backup, device
   linking, nuke and signature auth since. It also says "no typing-indicator
   sending" and "no self-sync" — both now exist.

6. **iOS does not implement `Relay-Sig` yet.** `android/CLAUDE.md` requires it, and
   the server accepts it (`internal/api/sigauth.go`), but `RelayCredentials.swift`
   still sends HTTP Basic and `TODO.md` lists client signing as outstanding. So
   Android will be the **first** `Relay-Sig` client. That is fine (server-side
   verifier + tests exist), but see §2.3 for a bootstrap ordering problem it creates.

7. **Feature list vs. wire schema.** `android/CLAUDE.md` names voice notes, live
   location, scheduled messages and disappearing messages as parity features. Only
   *disappearing* has a wire field (`Content.expires_after_ms`). The others are
   **encoded in `TextMessage.body` with magic prefixes** or are local-only:
   - live location → body prefix `__relay_loc__` + a JSON payload; receivers collapse
     all updates from one sharer into one row keyed `liveloc:<conversation>:<sender>`
   - shared notepad → body prefix (see `notepadPrefix` in `MessagingService`)
   - polls → real wire messages (`PollMessage` 17 / `PollVote` 18) **and also** a
     `__poll__:` JSON body prefix used for local storage
   - voice notes → an ordinary `AttachmentPointer` with an audio MIME type
   - scheduled messages → purely local; the client sends at the due time
   I will mirror these exactly rather than propose wire changes.

---

## 1. Crypto parameters (must match byte-for-byte)

### 1.1 libsignal

- iOS pins **v0.97.4** (`scripts/setup-libsignal.sh`, SHA-256-verified prebuilt).
- Android: `org.signal:libsignal-android:0.97.4` (pulls `libsignal-client`).
  **Pin the exact patch version**, not `0.97.+`.
- `minSdk 26` in the scaffold — to be confirmed against libsignal-android's own
  manifest at Stage 1.

### 1.2 Identity, registration id, prekey ids

| Item | Value | Source |
|---|---|---|
| Identity key | Curve25519, **33-byte** serialization `0x05 ‖ X` | libsignal |
| Identity private key | **Never leaves the Keystore** (iOS: Keychain only, never in the DB) | `KeychainSecureStore` |
| Registration id | Random in `1...0x3FFF` (1–16383), generated once, persisted next to the identity key | `KeychainSecureStore.swift:341` |
| Prekey ids | Monotonic counter `next-prekey-id` in the encrypted kv table, starting at **1**, allocated in contiguous ranges, **never reused for the device's lifetime** | `KVPreKeyIdAllocator` |
| Allocation layout | `[base]` = signed prekey id, `[base+1]` = Kyber prekey id, `[base+2 … ]` = one-time prekeys | `PreKeyMaintainer` |
| One-time prekey pool | threshold **20**, batch **100**; server caps **200 per upload** | `PreKeyMaintainer`, `maxOneTimePreKeysPerUpload` |

### 1.3 PQXDH

- Every bundle carries a **mandatory last-resort Kyber prekey**. There is **no
  one-time Kyber pool**: one Kyber key per device, replaced on each upload, marked
  used but never deleted.
- Signed prekey = fresh Curve25519 keypair; signature = identity private key
  XEd25519 signature over the **serialized public key** (33 bytes).
- Kyber prekey = `KEMKeyPair.generate()`; signature over its serialized public key.
- `oneTimePreKey` may be `null` in a fetched bundle when the peer's pool is
  exhausted → build the bundle **without** a one-time prekey (degraded but valid).
  Android must handle both bundle shapes.
- On launch, iOS **republishes identity + signed prekey + Kyber prekey with an empty
  one-time list** (`republishSignedPreKey`), so the server can never serve a signed
  prekey whose private half was lost to a reinstall. Android must do the same.

### 1.4 Double Ratchet / sender keys

- Standard libsignal. Nothing custom.
- Groups: `distribution_id` is a **UUID string** carried E2E in
  `GroupUpdate.distribution_id`. SKDMs are sent **1:1 over pairwise sessions**
  (`Content.sender_key_distribution`), tracked per (group, epoch, member) so each
  member is served once per epoch.
- **Removing a member rotates `distribution_id` to a fresh UUID** (actor-side), which
  forces new sender keys the removed member cannot read.
- ⚠️ **In sealed-sender mode iOS does not use sender keys at all.** A group message
  is fanned out as *individual pairwise sealed messages*, each carrying
  `Content.group_id` so it lands in the right conversation. Sender-key broadcast is
  used only when sealed sender is off. Android must implement **both** paths to
  interoperate with either peer configuration.

### 1.5 Safety numbers

| Parameter | Value |
|---|---|
| Generator | `NumericFingerprintGenerator` |
| Iterations | **5200** |
| Version | **2** |
| Local identifier | UTF-8 bytes of the **local account id** |
| Remote identifier | UTF-8 bytes of the **remote account id** |
| Display | `displayable.formatted` — the 60-digit string |
| QR | `scannable.encoding`; compare with `scannable.compare(againstEncoding:)` (order-independent) |

Identities are keyed **by account**, not by device (the fingerprint address uses
`deviceId: 1` arbitrarily). Trust model is **TOFU**: a changed peer identity key
becomes untrusted and clears the `verified` flag; outgoing sends to that peer are
blocked until the user acknowledges the new number.

### 1.6 Sealed sender

**Trust root (embed verbatim):**

```
BUMHKPU9XPCdwHCVF8Eea8RxKLhbxq6BhpvYgBTo4IFU
```

33 bytes, base64, `0x05 ‖ X25519 public`. Logged by the relay at startup
(`-sealed-sender-trust-key`). Rotating it requires a client rebuild.

**Certificate format** — minted by Go (`internal/sealedsender/cert.go`), validated by
libsignal on the client, so the bytes matter:

- Outer envelope (both cert types): `{1: bytes certificate, 2: bytes signature}`.
- `ServerCertificate.Certificate`: `{1: varint key_id, 2: bytes key(33)}`, signed by
  the trust root.
- `SenderCertificate.Certificate`, in this exact emitted order:
  `2: varint device_id`, `3: fixed64 expires` (**unix ms**), `4: bytes identity_key(33)`,
  `5: bytes signer` (the serialized ServerCertificate), `6: string sender_uuid`.
  Field `1` (e164) is **omitted**.
- `sender_uuid` carries the **relay account id string**. Correcting an earlier
  hedge in this document: account ids **are** RFC 4122 v4 UUIDs — the relay's
  `store.newUUID()` sets the version and variant nibbles explicitly. This is
  load-bearing on Android, because libsignal's `SealedSessionCipher` constructor
  takes a `java.util.UUID` for the local identity, so an opaque non-UUID account
  id would have made the stock sealed-sender API unusable. Verified in Stage 2.
- Signatures are **XEd25519** (SHA-512, `0xFE ‖ 0xFF×31` domain prefix, sign bit in
  the top bit of the last signature byte) — libsignal validates these natively.
- Expiry: **7 days**. iOS refreshes when within 1 day of expiry.

**Send:** `UnidentifiedSenderMessageContent(ciphertext, cert, contentHint = DEFAULT,
groupId = <empty>)` → `sealedSenderEncrypt` → `POST /v1/messages/sealed`
(unauthenticated) with the recipient's 32-byte **access key**.
Note iOS passes an **empty groupId even for group sends**.

**Receive:** an envelope with an **empty `sender_account`** is sealed. Validate the
cert against the trust root at `envelope.server_timestamp` (ms) when non-zero, else
`now`. The cert-recovered identity is authoritative; if the decrypted
`Content.sender_account_id` is non-empty and disagrees, **treat it as a spoof and
drop** (`EnvelopeProcessorError.senderSpoofed`).

**Access key:** 32 random bytes, generated once, stored in the Keychain/Keystore,
uploaded via `PUT /v1/accounts/me/access-key`, and returned to session-establishing
peers in `GET /v1/keys/{account}`'s `accessKey`. Rotating it revokes old senders.

**Mailbox rotation:** at most **once per 24h**, and **only while sealed sender is
on** (the sealed path retries a stale-mailbox `403`; the WebSocket path has no such
recovery).

### 1.7 Blinded discovery (OPRF)

2HashDH over ristretto255. Server: `internal/oprf/oprf.go`. iOS client:
`Relay/BlindedDiscovery.swift`. Android: libsodium via `lazysodium-android`.

```
normalize(x)  = lowercase(trim_whitespace_and_newlines(x))
H1(x)         = ristretto255_from_hash( SHA-512( "Relay-OPRF-v1-h2g" ‖ x ) )   // 64B → 32B point
r             = crypto_core_ristretto255_scalar_random()
B             = crypto_scalarmult_ristretto255(r, H1(x))                        // sent to server
E             = k·B                                                             // server
N             = crypto_scalarmult_ristretto255( scalar_invert(r), E )
token         = SHA-256( "Relay-OPRF-v1-token" ‖ x ‖ N )                        // 32B, base64 std
```

`x` is the **normalized** identifier bytes in *both* hashes. Domain tags are ASCII,
no trailing NUL. Batch size 1–1024 per request.

### 1.8 Attachment / blob cipher

- **AES-256-GCM**, fresh random 32-byte key per blob.
- Uploaded bytes are libsignal/CryptoKit "combined" layout: **`nonce(12) ‖ ciphertext ‖ tag(16)`**.
  Android's `javax.crypto` emits `ciphertext ‖ tag`, so **prepend the 12-byte IV manually**.
- `digest` = **SHA-256 of the combined ciphertext** (not the plaintext). Verify the
  digest *before* attempting decryption — fail closed.
- `AttachmentPointer.size` = ciphertext length, not plaintext length.
- The same cipher is reused for group-invite blobs and linked-device history blobs.

### 1.9 Content padding

Applied to **every non-ephemeral** payload, immediately before encryption
(`RelayCore/ContentPadding.swift`):

```
buckets = [256, 512, 1024, 4096]
target(n) = first bucket strictly > n, else ((n / 4096) + 1) * 4096
```

Fill `Content.padding` (field **12**) with random bytes, initially
`target - n - 2`, then shrink until the re-serialized message is `<= target`.
**Ephemeral payloads (typing, receipts) are NOT padded.** Receivers ignore the field.

### 1.10 Backup key derivation

```
recovery_key = 32 random bytes (shown to the user as grouped hex)
backup_key   = HKDF-SHA256(ikm = recovery_key, salt = "relay-icloud-backup", info = "v1", L = 32)
blob         = AES-256-GCM(backup_key, snapshot)
```

Android reuses this derivation verbatim, with Google Drive `appDataFolder` in place
of CloudKit. Sessions are **not** in the backup by design (restoring brings back
history; sessions re-key on next contact, which looks like a safety-number change).

---

## 2. Authentication

### 2.1 `Relay-Sig` (preferred; `internal/api/sigauth.go`)

```
canonical = METHOD "\n" PATH "\n" TIMESTAMP "\n" NONCE
signature = ECDSA-P256-ASN.1( SHA-256( canonical ) )   using the device auth private key

Authorization:     Relay-Sig <accountId>.<deviceId>:<base64(signature)>
X-Relay-Timestamp: <unix milliseconds>
X-Relay-Nonce:     <base64 random>
```

- **`PATH` is `r.URL.Path` — the query string is excluded.** For
  `GET /v1/keys/{acct}?device=3` you sign `/v1/keys/{acct}`.
- The body is **deliberately not signed** (TLS covers integrity).
- Accepted iff: signature verifies against the stored `auth_public_key`, timestamp
  within **±5 minutes**, and the nonce is unseen for that device in the window
  (replay key is `<account>.<device>:<nonce>`).
- Works on **every** authenticated endpoint **including the `GET /v1/ws` upgrade**
  (`auth()` wraps the WS handler).

### 2.2 HTTP Basic (legacy fallback)

Username `<accountId>.<deviceId>`, password = the device password. Still accepted;
still what iOS uses. Android should implement it **only** for the bootstrap below.

### 2.3 ⚠️ Bootstrap ordering problem (needs your call)

`Relay-Sig` verifies against `devices.auth_public_key`, which is uploaded via
`PUT /v1/devices/auth-key` — **itself an authenticated endpoint**. A brand-new device
has no auth key on file, so its first authenticated call cannot be signed.

Proposed sequence (no server change needed):

1. `POST /v1/accounts` (unauthenticated) → `{accountId, deviceId, mailboxId}`; keep
   the device password.
2. Generate the P-256 auth keypair in the Android Keystore.
3. `PUT /v1/devices/auth-key` **using HTTP Basic**, body
   `{"publicKey": base64(uncompressed point)}` — **65 bytes, `0x04 ‖ X ‖ Y`**
   (`elliptic.Unmarshal`; a compressed or SEC1-DER-wrapped key is rejected).
4. Every subsequent request uses `Relay-Sig`. Retain the device password only for
   recovery/relink.

The Keystore constraint worth flagging: to sign with a hardware-backed key we need
`KeyProperties.PURPOSE_SIGN` + `setDigests(DIGEST_SHA256)`; `Signature("SHA256withECDSA")`
produces the ASN.1/DER form the server expects. StrongBox availability varies by
device, so I plan `StrongBox → TEE → software` fallback, recorded in the device row.

### 2.4 Other canonical signing strings

**Remote wipe (nuke)** — `POST /v1/accounts/me/nuke`, and re-verified client-side on
the `ServerFrame.nuke` broadcast:

```
"relay-nuke-v1\n" + accountId + "\n" + commandId + "\n" + creationTimeMs + "\n" + initiatingDeviceId
```
SHA-256 + ECDSA-P256 ASN.1, signed by the device auth key. Server rejects commands
older than 5 min or more than 30 s in the future, and rejects duplicate `commandId`.
Clients must verify the full signature before wiping.

**Device-list mutations** — `POST /v1/devices`, `POST /v1/devices/link-invitations`,
`DELETE /v1/devices/{id}`:

```
"relay-device-list-v1\n" + accountId + "\n" + expectedVersion + "\n" + action + "\n" + targetDeviceId + "\n" + password
```
`action` ∈ `{"add", "link", "remove"}`; `targetDeviceId` is `0` for add/link;
`password` is the new device's password for `add` and `""` otherwise. Sent as
`{"auth": {"expectedVersion", "signerDeviceId", "signature"}}`. A stale
`expectedVersion` returns **409**.

---

## 3. REST API — complete, from `internal/api/api.go:Handler()`

All JSON. **Binary fields are standard padded base64** (`b64` type). `auth` column:
`sig` = Relay-Sig or Basic; `none` = unauthenticated.

### 3.1 Accounts

| Method & path | Auth | Request → Response |
|---|---|---|
| `POST /v1/accounts` | none | `{username, password, email?, accountPassword?}` → **201** `{accountId, deviceId, mailboxId}`. Username regex `^[a-zA-Z0-9._\-]{1,64}$`; password 8–1024. **409** username taken, **429** >20/IP/hour. Email is stored only as its OPRF token. |
| `POST /v1/accounts/oauth` | none | `{accessToken, password, username?, accountPassword?}` → **201/200** `{accountId, deviceId, username, mailboxId, created}`. **404** = username required (prompt and retry), **409** taken, **503** Supabase unconfigured. |
| `POST /v1/accounts/recover` | none | `{email, accountPassword}` → **201** `{accountId, username, deviceId, devicePassword, mailboxId}`. **404/401/422/503**. |
| `GET /v1/accounts/by-username/{username}` | none | → `{accountId}`. 600/IP/hour. Legacy; prefer blinded discovery. |
| `GET /v1/accounts/by-email/{email}` | sig | → `{accountId, username}`. 3000/account/hour. |
| `GET /v1/accounts/{account}` | sig | → `{username}`. 600/account/hour. |
| `PUT /v1/accounts/me/username` | sig | `{username}` → **204**. **409** taken. Reindexes the blinded directory. |
| `PUT /v1/accounts/me/access-key` | sig | `{accessKey}` (base64, **exactly 32 bytes**) → **204**. |
| `POST /v1/accounts/me/nuke` | sig | `{commandId, creationTimeMs, initiatingDeviceId, signature}` → **204**. §2.4. |

### 3.2 Devices

| Method & path | Auth | Request → Response |
|---|---|---|
| `POST /v1/devices` | sig | `{password, auth{…}}` → **201** `{accountId, deviceId, mailboxId, deviceListVersion}`. Broadcasts `DeviceListChanged(DEVICE_ADDED)`. |
| `GET /v1/devices` | sig | → `{devices:[{deviceId, mailboxId}], deviceListVersion}` |
| `DELETE /v1/devices/{id}` | sig | `{auth{…}}` → **204**. Broadcasts `DEVICE_REMOVED`. |
| `POST /v1/devices/link-invitations` | sig | `{auth{…}}` → **201** `{linkToken, verificationCode, expiresAt}` |
| `POST /v1/devices/link-claims` | **none** | `{linkToken, verificationCode}` → **200** `{accountId, deviceId, password, username}`. **404** expired/used, **409** device list changed. |
| `PUT /v1/devices/auth-key` | sig | `{publicKey}` — uncompressed P-256 `0x04‖X‖Y`, ≤512 B → **204** |
| `GET /v1/devices/{id}/auth-key` | sig | → `{authPublicKey}` (same account only) |
| `PUT /v1/devices/apns` | sig | `{token}` → **204**. *(iOS only — see §7 FCM.)* |
| `PUT /v1/devices/voip` | sig | `{token}` → **204**. *(PushKit; no Android analogue.)* |
| `PUT /v1/devices/me/push-content` | sig | `{includeContent: bool}` → **204**. `false` (default) = content-free wake. |
| `POST /v1/devices/me/mailbox/rotate` | sig | → **200** `{mailboxId}` |

### 3.3 Keys

| Method & path | Auth | Request → Response |
|---|---|---|
| `PUT /v1/keys` | sig | `{registrationId, identityKey, signedPreKey{keyId,publicKey,signature}, kyberPreKey{…}, oneTimePreKeys[{keyId,publicKey}]}` → **204**. Identity/signed/Kyber **replace**; one-time keys **append**. ≤200 OTKs/upload, 100 uploads/account/hour. Kyber prekey is **required**. |
| `GET /v1/keys/count` | sig | → `{count}` — replenish below 20 |
| `GET /v1/keys/{account}[?device=N]` | sig | → `{devices:[{deviceId, mailboxId, registrationId, identityKey, signedPreKey, kyberPreKey, oneTimePreKey|null}], accessKey?}`. Consumes one OTK per device. 200 fetches per (requester,target)/hour; own-account fetches exempt. **404** unknown/no keys. |

### 3.4 Messaging

| Method & path | Auth | Request → Response |
|---|---|---|
| `POST /v1/messages/sealed` | **none** | `{mailboxId, type, content, accessKey, ephemeral, clientTimestamp}` → **200** `{serverTimestamp}`. `type` is the numeric `CiphertextType`. **403** for *any* failure (unknown mailbox or wrong access key — deliberately indistinguishable). 600/IP/min, 120/mailbox/min. |
| `GET /v1/queue` | sig | → `{envelopes:[base64 serialized Envelope]}`. Does **not** dequeue. |
| `POST /v1/messages/ack` | sig | `{envelopeId}` → **204** |
| `POST /v1/call/{account}` | sig | `{callId, callerName, kind}` → **204**. Fires a VoIP push. *(iOS/PushKit-specific.)* |

### 3.5 Discovery, invites, presence

| Method & path | Auth | Request → Response |
|---|---|---|
| `POST /v1/directory/oprf` | sig | `{blinded:[b64]}` (1–1024) → `{evaluated:[b64]}`. 200/account/hour (shared with resolve). **503** if unconfigured. |
| `POST /v1/directory/resolve` | sig | `{tokens:[b64]}` (1–1024) → `{results:[{token, accountId, username}]}`. Unmatched tokens omitted. |
| `POST /v1/contact-invites` | sig | → **201** `{token, expiresAt}` (7 days, single-use) |
| `POST /v1/contact-invites/claim` | sig | `{token}` → `{accountId, username}`; **404** invalid/expired/used |
| `POST /v1/group-invites` | sig | `{blob}` (base64, 1–65536 B) → **201** `{token, expiresAt}`. 20/account/day. |
| `POST /v1/group-invites/claim` | sig | `{token}` → `{blob}`. Multi-use until expiry. 50/account/hour. |
| `GET /v1/presence/{account}` | sig | → `{online, lastSeen}` (ms, 0 = never). In-memory only. 300/account/min. |

### 3.6 Attachments & TURN

| Method & path | Auth | Request → Response |
|---|---|---|
| `POST /v1/attachments` | sig | → **201** `{id}` |
| `PUT /v1/attachments/{id}` | sig | raw `application/octet-stream` body → **204**; **413** over cap |
| `GET /v1/attachments/{id}` | sig | → raw bytes; **404** after TTL reaping |
| `GET /v1/turn-credentials` | sig | → `{urls[], username, credential, ttl}` (coturn REST HMAC-SHA1, 1 h). **404** when TURN isn't configured — treat as "no TURN", not an error. |

### 3.7 Error shape

Every error is `{"error": "<message>"}` with the HTTP status. Request bodies are
size-limited globally (`limitRequestBody`), and visitor IP headers are stripped.

---

## 4. WebSocket protocol

- `GET /v1/ws`, authenticated (Relay-Sig or Basic on the upgrade).
- Every binary message is **exactly one** serialized `relay.v1.ClientFrame` (out) or
  `relay.v1.ServerFrame` (in). No text frames; non-binary is ignored.
- Server read limit **512 KiB**; server pings every **45 s** and expects a pong
  within **60 s**. iOS additionally client-pings every **25 s** and tears the socket
  down on ping failure to force a fast reconnect. Android should do the same
  (OkHttp `pingInterval(25, SECONDS)`).
- On connect: queued `Envelope` frames, then one `QueueEmpty`, then live traffic.
- A pending nuke is delivered **instead of** the queue drain, then the socket closes.
- `ServerFrame.device_list_changed` is a hint to re-fetch `GET /v1/devices` /
  prekey bundles. Not E2EE — the account owns all its devices.

### 4.1 Sending (the mailbox model)

`SendRequest.destination_account` is an **opaque mailbox id** (field name kept for
wire compatibility), and the server accepts **exactly one** `DeviceMessage` per
frame. Per-device fan-out = one frame per destination mailbox, sequentially.

Server checks, in order:
1. `len(messages) != 1` → `MISMATCHED_DEVICES`
2. mailbox unknown → `UNKNOWN_ACCOUNT`
3. `device_id != mailbox's device` → `MISMATCHED_DEVICES` + `extra_devices`
4. `registration_id != 0 && != stored` → `MISMATCHED_DEVICES` + `stale_devices`

### 4.2 The `missing_devices` trap (must be replicated)

On a **non-ephemeral, cross-account** send the server *always* lists **every other
device of the destination account** in `missing_devices` — **including devices this
send already reached** in an earlier frame. Self-sends are exempt.

So a naive "retry everything in `missing`" duplicates messages. iOS's algorithm,
which Android must match (`MessagingService.sendContent`):

```
firstRoundIds = set of device ids addressed in pass 1
on MISMATCHED_DEVICES:
    refreshSessions(peer)                      # re-fetch bundles, re-establish sessions
    retryIds = (missing - firstRoundIds) ∪ stale
    if retryIds is empty: treat as success
    else: send only to retryIds
          if the second response's extra is empty and (missing₂ ∪ stale₂) ⊆ (firstRoundIds ∪ retryIds):
              treat as success
```

Retry happens **once**. `refreshSessions` re-processes **all** bundles (which may
reset healthy sessions — wasteful but correct; documented as an accepted gap on iOS).

### 4.3 Delivery semantics

- **At-least-once.** Envelopes stay queued until acked (`AckRequest{envelope_id}` on
  the WS, or `POST /v1/messages/ack`).
- **Dedup by envelope id**, claimed exactly once before decryption.
- `ephemeral` envelopes (typing, receipts) **never queue** — online devices only.
- **Failed decrypts are acked and dropped** (poison-message protection). Never let a
  message that won't decrypt redeliver forever.
- iOS acks over the WS when live, else over REST. Android same.
- **QUIC fallback:** when the WebSocket isn't live, poll `GET /v1/queue` every **5 s**
  and ack over REST. Dedup makes overlap harmless.

---

## 5. `relay.proto` — field numbers (`package relay.v1`)

`CiphertextType`: `UNSPECIFIED=0`, `PREKEY_MESSAGE=1`, `MESSAGE=2`, `SENDER_KEY_MESSAGE=3`.

| Message | Field | # | Type |
|---|---|---|---|
| `ClientFrame` | id | 1 | uint64 |
| | send | 2 | `SendRequest` (oneof payload) |
| | ack | 3 | `AckRequest` (oneof payload) |
| `SendRequest` | destination_account | 1 | string — **opaque mailbox id** |
| | messages | 2 | repeated `DeviceMessage` — **exactly one** |
| | client_timestamp | 3 | int64 (ms) |
| | ephemeral | 4 | bool |
| `DeviceMessage` | device_id | 1 | uint32 |
| | registration_id | 2 | uint32 (0 = skip check) |
| | type | 3 | `CiphertextType` |
| | content | 4 | bytes |
| `AckRequest` | envelope_id | 1 | string |
| `ServerFrame` | send_response | 1 | `SendResponse` (oneof) |
| | envelope | 2 | `Envelope` |
| | queue_empty | 3 | `QueueEmpty` |
| | nuke | 4 | `NukeCommand` |
| | device_list_changed | 5 | `DeviceListChanged` |
| `SendResponse` | reply_to | 1 | uint64 |
| | status | 2 | `SendStatus` |
| | missing_devices | 3 | repeated uint32 |
| | extra_devices | 4 | repeated uint32 |
| | stale_devices | 5 | repeated uint32 |
| | server_timestamp | 6 | int64 |
| `Envelope` | id | 1 | string — 32-char hex |
| | sender_account | 2 | string — **empty ⇒ sealed sender** |
| | sender_device | 3 | uint32 |
| | type | 4 | `CiphertextType` |
| | content | 5 | bytes |
| | client_timestamp | 6 | int64 |
| | server_timestamp | 7 | int64 |
| | ephemeral | 8 | bool |
| `NukeCommand` | account_id / command_id / creation_time_ms / initiating_device_id / signature | 1–5 | see §2.4 |
| `DeviceListChanged` | action | 1 | `UNSPECIFIED=0, DEVICE_ADDED=1, DEVICE_REMOVED=2` |
| | device_id | 2 | uint32 |

`SendStatus`: `UNSPECIFIED=0`, `OK=1`, `MISMATCHED_DEVICES=2`, `UNKNOWN_ACCOUNT=3`, `RATE_LIMITED=4`.

---

## 6. `content.proto` — every field number (`package relay.content`)

The relay never parses this. **Codegen Kotlin from `../proto/content.proto`.**

### 6.1 `Content`

| Field | # | Type | Notes |
|---|---|---|---|
| `text` | **1** | `TextMessage` | oneof `body` |
| `receipt` | **2** | `ReceiptMessage` | oneof `body` |
| `typing` | **3** | `TypingMessage` | oneof `body` |
| `reaction` | **4** | `ReactionMessage` | oneof `body` |
| `sender_key_distribution` | **5** | `SenderKeyDistribution` | oneof `body` |
| `group_update` | **6** | `GroupUpdate` | oneof `body` |
| `delete` | **7** | `DeleteMessage` | oneof `body` |
| `profile` | **9** | `ProfileUpdate` | oneof `body` |
| `call` | **10** | `CallMessage` | oneof `body` |
| `edit` | **11** | `EditMessage` | oneof `body` |
| `poll` | **17** | `PollMessage` | oneof `body` |
| `poll_vote` | **18** | `PollVote` | oneof `body` |
| `group_id` | **8** | string | set on group messages; empty for 1:1 |
| `padding` | **12** | bytes | §1.9; ignore on receive |
| `sender_account_id` | **13** | string | **MUST be set on every outgoing message** |
| `sender_device_id` | **14** | uint32 | **MUST be set on every outgoing message** |
| `expires_after_ms` | **15** | int64 | disappearing timer; 0 = none/no change; receivers sync their local timer |
| `sync_recipient` | **16** | string | set **only** on sync copies to own devices; the original peer's account id |

Field numbers **8 and 12–16 are not in the oneof** — they are top-level and coexist
with any body.

### 6.2 `TextMessage`

| Field | # | Type |
|---|---|---|
| `body` | 1 | string |
| `timestamp` | 2 | int64 — sender clock, **doubles as the message id receipts reference** |
| `quote` | 3 | `Quote` |
| `attachments` | 4 | repeated `AttachmentPointer` |

### 6.3 `AttachmentPointer`

`id`=1 (string), `key`=2 (bytes, 32), `digest`=3 (bytes, SHA-256 of ciphertext),
`content_type`=4 (string), `size`=5 (uint64, **ciphertext** bytes), `filename`=6
(string), `width`=7 (uint32), `height`=8 (uint32).

### 6.4 `Quote`

`target_timestamp`=1 (int64), `author`=2 (string account id), `text`=3 (string, sender truncates).

### 6.5 `ReceiptMessage`

`type`=1 (`TYPE_UNSPECIFIED=0`, `TYPE_DELIVERY=1`, `TYPE_READ=2`),
`message_timestamps`=2 (repeated int64).
**Read never downgrades to delivered.** Sent **ephemeral**. In groups the receipt
carries `Content.group_id` and receivers record per-member state.

### 6.6 `TypingMessage`

`action`=1 (`ACTION_UNSPECIFIED=0`, `ACTION_STARTED=1`, `ACTION_STOPPED=2`), `timestamp`=2.
Sent with `Envelope.ephemeral = true`.

### 6.7 `ReactionMessage`

`emoji`=1, `target_author`=2, `target_timestamp`=3, `remove`=4 (bool), `timestamp`=5.
Non-ephemeral (queues). One reaction per author per message; a new one replaces.

### 6.8 `DeleteMessage` / `EditMessage`

`DeleteMessage`: `target_timestamp`=1, `target_author`=2. Leaves a tombstone, does
not erase the row. Only the original author may delete.
`EditMessage`: `target_timestamp`=1, `new_body`=2. Attachments are not editable.

### 6.9 `SenderKeyDistribution`

`data`=1 (serialized SKDM), `distribution_id`=2 (UUID string).

### 6.10 `GroupUpdate`

`revision`=1 (int64), `action`=2, `actor`=3, `target`=4, `name`=5, `description`=6,
`avatar`=7 (`AttachmentPointer`), `members`=8 (repeated string — **full roster after
the change**, present on CREATE/ADD/REMOVE/LEAVE), `admins`=9 (repeated string),
`announce_only`=10 (bool), `distribution_id`=11 (string — rotated on REMOVE),
`invite_key`=12 (bytes).

`Action`: `UNSPECIFIED=0` (also used as a **silent invite-key announcement**),
`CREATE=1`, `ADD=2`, `REMOVE=3`, `LEAVE=4`, `RENAME=5`, `DESCRIBE=6`, `AVATAR=7`,
`PROMOTE_ADMIN=8`, `DEMOTE_ADMIN=9`, `SET_ANNOUNCE_ONLY=10`.

Group state lives **only** here — the relay stores nothing. `revision` drops stale
updates.

### 6.11 `ProfileUpdate`

`display_name`=1, `avatar`=2 (`AttachmentPointer`, unset = no photo), `timestamp`=3
(newest wins). Sent pairwise, E2EE; the avatar reuses the blob pipeline.

### 6.12 `CallMessage`

`type`=1, `call_id`=2, `sdp`=3, `ice`=4 (JSON `RTCIceCandidate`), `group_id`=5,
`target_account`=6, `participants`=7 (repeated string).

`Type`: `OFFER=0`, `ANSWER=1`, `ICE=2`, `HANGUP=3`, `BUSY=4`, `RINGING=5`,
`GROUP_RING=6`, `GROUP_JOIN=7`, `GROUP_LEAVE=8`.

**Ephemeral:** ANSWER, ICE, RINGING, BUSY, GROUP_JOIN, GROUP_LEAVE.
**Non-ephemeral (queue):** OFFER, HANGUP, GROUP_RING.
Note `OFFER = 0` — proto3 cannot distinguish "unset" from OFFER; always set `type`.

### 6.13 `PollMessage` / `PollVote`

`PollMessage`: `question`=1, `options`=2 (repeated string), `multi_select`=3,
`timestamp`=4 (**the stable poll id**).
`PollVote`: `poll_author`=1, `poll_timestamp`=2, `selected_options`=3 (repeated
uint32, zero-based), `timestamp`=4. A new vote replaces the previous. Tallies are
aggregated client-side.

---

## 7. Client behaviours Android must mirror

### 7.1 Send pipeline (1:1)

1. Refuse if the peer's identity changed and the user hasn't acknowledged it.
2. Build `Content`; **always set `sender_account_id` + `sender_device_id`**; set
   `expires_after_ms` from the conversation's disappearing timer if > 0.
3. Pad (non-ephemeral only).
4. Optional **send jitter**: random 500–5000 ms delay before the wire send when
   enabled (the row already shows locally as "sending").
5. Sealed if enabled **and** the recipient has published an access key
   (`recipientSupportsSealed`) — otherwise fall back to the authenticated WS path so
   older peers stay reachable. Decide **per recipient, up front** to avoid double-sends.
6. Sealed path: one `POST /v1/messages/sealed` per device mailbox; on `403` refresh
   bundles/mailboxes once and retry **only the failed devices**.
   WS path: one frame per mailbox, then §4.2's mismatch algorithm.
7. **Self-sync:** re-send the same `Content` with `sync_recipient = <peer account>`
   to every *other* device of our own account (excluding this one). Best-effort;
   errors swallowed. Recipients store it as **outgoing**, using the **envelope id** as
   the local row id.

### 7.2 Receive pipeline (`RelayCore/EnvelopeProcessor.swift` is the reference)

1. Claim the envelope id (dedup) — return `duplicate` if already seen.
2. Empty `sender_account` ⇒ sealed: validate the cert, recover the sender.
   Otherwise decrypt with `(sender_account, sender_device)`.
3. Parse `Content`. **Spoof check** (§1.6).
4. Attested sender = `content.sender_account_id` when set, else the envelope/cert
   sender. **Prefer the E2E-attested value over the server-stamped field.**
5. Drop if the attested sender is blocked (post-decrypt — sealed messages can't be
   filtered earlier).
6. `sync_recipient` non-empty **and** attested sender == our own account ⇒ sync copy:
   store as outgoing in the `sync_recipient` conversation, never notify.
7. Conversation key = `group_id` if set, else the peer account (or `sync_recipient`).
8. Apply `expires_after_ms` to the conversation **before** inserting the message.
9. Send a **delivery receipt** only when a row was actually inserted.
10. **Ack regardless of outcome**, including on decryption failure.

### 7.3 Groups

- Create/add/remove/rename/describe/avatar/promote/demote/announce-only are all
  `GroupUpdate` messages sent pairwise to every member. The relay is not involved.
- Invite link: `https://relaymsg.app/g/<token>#<base64url(key ‖ digest)>` where the
  fragment is **64 bytes** (32-byte AES key ‖ 32-byte SHA-256 digest) and the blob is
  `AES-GCM(JSON)` uploaded to `POST /v1/group-invites`. The JSON is exactly:
  `{"groupId","name","members":[…],"distributionId","inviteKey"}` with `inviteKey`
  base64 (Swift `JSONEncoder` default for `Data`) — **key order/casing matters**.
- A link-joiner echoes `invite_key` in their self-`ADD` so members can verify the
  join without learning they are an admin. Rotating `invite_key` revokes links.
- Announce-only: only admins may send.

### 7.4 Deep links (Android App Links)

Host `relaymsg.app`. Android needs `/.well-known/assetlinks.json`, the counterpart
to the existing `apple-app-site-association`. **This is a website change, not a
relayd change:** nothing in the Go server routes the AASA file, and it couldn't —
App Links must be served from the host in the link (`relaymsg.app`), whereas relayd
runs on `api.relaymsg.app`. The file checked in at `server/apple-app-site-association`
is just parked there; whatever hosts the marketing site is what serves it. That host
isn't in this repo.

| Path | Meaning |
|---|---|
| `/add/<username>` | permanent username link |
| `/c/<token>` | one-time contact invite → `POST /v1/contact-invites/claim` |
| `/g/<token>#<fragment>` | encrypted group invite (§7.3) |

### 7.5 Push — ⚠️ requires a server change (your call, not mine)

The relay only speaks **APNs** (`internal/apns/apns.go`, `hub.Deliver` → `h.pusher.Push`).
There is no FCM sender and no place to store an FCM token — `PUT /v1/devices/apns`
stores into an APNs-specific column and the pusher builds an `aps` payload.

Current APNs contract, which FCM must preserve:
- Default = **content-free wake**: payload is `{"aps":{"alert":{"body":"New message"},
  "mutable-content":1,"sound":"default"}}` — no message data. The extension then
  fetches `GET /v1/queue`, decrypts on-device, acks via `POST /v1/messages/ack`.
- Opt-in (`PUT /v1/devices/me/push-content` `{includeContent:true}`) adds `"e"` =
  base64 of the serialized `Envelope` for a faster wake.

**Proposed** (not implemented — needs your approval since it touches `../server/`):

1. Add a `push_kind` (`apns`|`fcm`) + token column, or a new
   `PUT /v1/devices/fcm {token}` endpoint.
2. Add an `internal/fcm` sender (FCM HTTP v1, service-account JWT) and dispatch on
   `push_kind` inside `hub`.
3. Preserve the contentless default exactly: a **data-only** message
   (`{"data":{}}`, no `notification` block) so the app — not the OS — decides what to
   display; `"e"` carried in `data` for the opt-in case.
4. FCM data payload cap is 4 KB; large opt-in envelopes must silently degrade to the
   contentless wake. (APNs' cap is 4 KB too, so the same risk exists today.)

Until that lands, Android runs **WebSocket + 5 s queue poll while the process is
alive**, with a foreground service for reliability. Everything else works; only
background wake-ups are missing. This mirrors iOS's own Stage 6 block.

### 7.6 Platform mappings (all proposals, pending your approval)

| iOS | Android | Note |
|---|---|---|
| Keychain + Secure Enclave | Android Keystore (StrongBox → TEE → software) | identity private key + registration id live **only** here |
| SQLCipher in App Group | `net.zetetic:android-database-sqlcipher` (or `androidx.sqlite` + SQLCipher), master key wrapped by a Keystore key | |
| CloudKit backup | Google Drive `appDataFolder` | same HKDF (§1.10) |
| APNs / PushKit | FCM data messages | §7.5 — server change |
| WebRTC (iOS) | `io.github.webrtc-sdk:android` | same relay signalling; Private Call Mode = TURN-only |
| Universal Links | App Links | needs `assetlinks.json` server-side |
| SwiftUI + Liquid Glass | Compose + Material 3 | equivalent, not a pixel copy |
| `URLSession` + HTTP/3 | OkHttp (+ Cronet for QUIC, optional) | REST races QUIC on iOS; not required for correctness |

### 7.7 Deliberate gaps carried over from iOS (do not "fix")

- No one-time Kyber prekey pool — last-resort only.
- Mismatch retry re-processes **all** bundles, possibly resetting healthy sessions.
- Failed decrypts are acked and dropped.
- `GET /v1/accounts/by-username` is plaintext legacy; new code uses blinded discovery.
- Group sends in sealed mode are pairwise, not sender-key.

---

## 8. Proposed staged build plan

Rules: **one stage at a time, owner check-in between each, no building ahead.** Each
stage ends with an interop test against `https://api.relaymsg.app` and a real iOS
build on your device. Anything touching `../proto/` or `../server/` is raised with
you, never changed by me.

A note on running things: `java` is not on this shell's `PATH`, but Android Studio's
JBR is at `/Applications/Android Studio.app/Contents/jbr` and the SDK is at
`~/Library/Android/sdk`. I can drive `./gradlew` with `JAVA_HOME` set for compile and
unit tests; **instrumented/emulator runs and device installs are yours**.

### Stage 0 — this document
Sign-off on §0 drift items, §2.3 bootstrap, §7.5 FCM, §7.6 mappings.

### Stage 1 — project setup ✅ delivered

Package `app.relaymsg`; modules `:proto :crypto :storage :net :core :app`; JDK 17
bytecode; `libsignal-android:0.97.4`; protoc-generated Java-lite + Kotlin DSL from
`../proto/` at build time (nothing checked in); libsodium, OkHttp, SQLCipher and
coroutines wired to their stage's module.

**Interop test — passing:** `:proto`'s `WireVectorsTest` runs 22 golden vectors
generated from the relay's **own Go protobuf types** by `android/tools/genvectors`
(a standalone Go module that only *imports* `../server`, never modifies it).

One correction to the plan as written above: it promised the Kotlin bytes would
*equal* the Go bytes. They don't, legitimately — **protobuf field order is not
canonical across implementations**; Go emits `oneof` members after the top-level
fields while the Java/Kotlin runtime emits strictly ascending field numbers. Both
encodings are valid and each parses the other. The test therefore asserts: Go's
bytes decode in Kotlin to exactly the expected message (this is what catches a wrong
field number — the value would land elsewhere or in `unknownFields`), re-encoding
those bytes reproduces the Kotlin encoding byte-for-byte, and the two encodings have
equal length (catching a field encoded spuriously or not at all).

**Setup findings worth keeping:**
- `org.signal:libsignal-android` on Maven Central **stops at 0.86.5**. Signal
  publishes current releases to their own bucket, declared in the vendored
  checkout's `java/build.gradle`. `settings.gradle.kts` adds it, group-filtered:
  `https://storage.googleapis.com/build-artifacts.signal.org/libraries/maven`
- libsignal-android requires **core library desugaring** (`desugar_jdk_libs`),
  enabled in every module on its compile classpath.
- Its AAR declares `minSdkVersion 23`, so our `minSdk 26` is fine.
- `lazysodium-android` pulls JNA as a **jar**; Android needs the **aar** (it carries
  the native libs). Both on the classpath duplicates every `com.sun.jna` class and
  dexing fails, so `:crypto` excludes the transitive jar.
- `libsignal_jni.so` is ~140 MB per ABI and the AAR also ships a test-only
  `libsignal_jni_testing.so` of similar size. The latter is excluded in packaging;
  debug builds are pinned to `arm64-v8a` alone. Debug APK: **173 MB**. Budget disk
  accordingly — this project wants ~10 GB of slack.

### Stage 2 — crypto core ✅ delivered

`:crypto` holds `CryptoEngine` (the single entry point, mirroring iOS's
`CryptoCore.CryptoEngine`), `AttachmentCipher`, `BlindedDiscovery` and the value
types; `ContentPadding` sits in `:core`, matching iOS where it lives in
`RelayCore` rather than `CryptoCore`. `:crypto` carries no protobuf dependency,
the same boundary `CryptoCore` keeps.

**42 unit tests pass, and they run on the JVM** — libsignal's jar bundles a
desktop dylib, so PQXDH, the ratchet, sender keys, sealed sender and safety
numbers are all verifiable without an emulator. That was not a given and it
shapes every later stage's test strategy.

Covered: PQXDH establishment (with and without a one-time pre-key), ratchet
round-trips both directions, cross-peer ciphertext rejection, SKDM distribution,
distribution-id rotation locking out a removed member, safety-number symmetry /
60 digits / QR scan comparison, sealed-sender round-trip plus rejection of an
unknown trust root and an expired certificate, the OPRF against Go vectors, the
attachment blob layout against a Go-produced blob, and the padding bucket table.

**Two deviations from the plan above, both deliberate:**

1. **The OPRF vectors are transcribed, not imported.** `server/internal/oprf` and
   `internal/sealedsender` are under `internal/`, so Go forbids importing them
   from the separate `tools/genvectors` module — the module is separate precisely
   so vector generation cannot modify `../server/`. The generator therefore
   re-implements the ~15-line OPRF using the same `gtank/ristretto255` library the
   server uses. That still cross-checks everything that actually differs between
   implementations (ristretto encodings, SHA-512 → `from_hash`, domain tags, hash
   input order), but it is weaker than importing the server's own code. Moving the
   generator into `server/` or exporting `internal/oprf` would fix it — **your
   call, since both touch the shared module.** The attachment vector has no such
   caveat: it uses only Go's standard library.

2. **The live checks move to Stage 4.** Both the live OPRF round-trip and
   validating a real `GET /v1/certificate/delivery` certificate need an
   authenticated client, which does not exist until the networking stage. Stage 2
   instead mints certificates in-test using libsignal's own XEd25519 signing,
   reproducing the exact field layout §1.6 documents, and libsignal validates
   them — which proves the documented layout is the one libsignal accepts. Stage 4
   adds the live versions, following iOS's convention of a test that skips itself
   when the server env var is absent.

**Implementation traps worth keeping:**
- **`SessionBuilder` takes `(store, remote, local)` but `SessionCipher` takes
  `(store, local, remote)`** — the two libsignal classes order their addresses
  oppositely. Getting it wrong stores the session correctly and then throws
  `NoSessionException` at encrypt time, so `containsSession` still says true and
  the bug looks like state corruption. All uses funnel through one helper.
- libsignal reports a bad trust root, an expired certificate and a malformed
  sealed envelope all as `InvalidMetadataMessageException`, not
  `InvalidCertificateException`. Client behaviour is identical for all three (ack
  and drop), so they collapse into one exception type.
- lazysodium-java's bundled-native extractor fails under this toolchain's JDK
  (it enumerates the `.dylib` jar entry as a directory). Tests extract the library
  themselves and use `SodiumJava(absolutePath)`. **Production is unaffected** —
  lazysodium-android unpacks from the APK — but that Android path is still
  unverified until the instrumented tests run on your emulator.

### Stage 3 — secure storage ✅ built, ⚠️ unverified

`:storage` holds `MasterKeyStore` (Android Keystore), `RelayDatabase` (SQLCipher),
`SqlCipherSignalStore` (all six libsignal stores), `MessageStore` and the
`SecureStore` composition root. Identity key pair and registration id live in the
Keystore only and never enter the database, matching iOS's Keychain/SQLCipher split.

The master key is 32 random bytes, AES-GCM wrapped by a Keystore key, with only
the wrapped blob persisted. Hardware tier is attempted **StrongBox → TEE →
software** and the result is recorded, so the app can tell the user which
guarantee they actually got. The wrapping key is deliberately **not** bound to
user authentication: the client must decrypt incoming messages while the device
is locked (the push path), the same reason iOS uses
`AfterFirstUnlockThisDeviceOnly` instead of a biometric-gated item.

**Schema:** iOS reached its shape through 18 incremental migrations because it
has an installed base. Android has none, so the same final shape is created as a
single version 1, with identical table and column names.

**One table iOS does not have.** libsignal's Java `KyberPreKeyStore` requires
`markKyberPreKeyUsed(kyberPreKeyId, signedPreKeyId, baseKey)` and expects the
store to raise `ReusedBaseKeyException` when that tuple repeats. Relay publishes a
single **last-resort** Kyber prekey and never rotates it per handshake, so that
check is the only thing standing between a captured `PreKeySignalMessage` and a
successful replay — hence `kyber_prekey_uses`. iOS's Swift `KyberPreKeyStore`
protocol exposes no base key, so it cannot perform this check in the store.
**Worth confirming how the Swift side covers that case** — flagging rather than
assuming a gap.

> ⚠️ **These tests have not been run.** SQLCipher ships Android native libraries
> and the Keystore is a platform service, so neither exists on the host JVM and
> this module's tests must be instrumented. There is no emulator on this machine
> (no system images installed, and `cmdline-tools` is absent). The code compiles
> and the tests are written; running `./gradlew :storage:connectedDebugAndroidTest`
> against an arm64 AVD is what will actually prove it. Written and waiting:
> master-key stability across reopen, the raw key never appearing in
> preferences, tier recording, identity persistence, **a session encrypted before
> a restart decrypting after it**, TOFU plus distrust of a changed key, the
> verification-state transitions that drive the safety-number warning, Kyber
> replay refusal, envelope-claim exactly-once, read-receipts never downgrading,
> disappearing-message expiry, group roster round-trip and distribution-id
> rotation, newest-wins profiles, and wipe.

### Stage 4 — networking
REST client with **`Relay-Sig`** (+ Basic for the auth-key bootstrap), WebSocket with
25 s pings, queue poll fallback, prekey maintenance, mailbox rotation, access-key
publication, sender-certificate caching, the §4.2 mismatch algorithm.
**Interop test (the milestone):** register a fresh Android account against
`api.relaymsg.app`, publish keys, and **round-trip a text message with your iOS
device in both directions** — once sealed, once unsealed — asserting delivery
receipts come back.

### Stage 5 — messaging UI (Compose)
Conversation list, chat, composer, attachments, replies, reactions, typing, edit/
unsend, receipts, disappearing timer, safety-number screen (incl. QR).
**Interop test:** the Stage 4 round-trip driven through the real UI on an emulator,
plus a reaction/edit/delete/receipt matrix against iOS.

### Stage 6 — push (blocked on §7.5)
FCM registration + contentless wake, **once you approve the server-side sender**.
If you'd rather not touch the server yet, I'll ship a foreground-service keepalive
instead and mark push blocked, exactly as iOS Stage 6 is.
**Interop test:** iOS sends while the Android app is swiped away; message arrives.

### Stage 7+ — one at a time
discovery/contact sync → groups (both sender-key and sealed-pairwise paths) →
media/voice notes → calls (WebRTC + TURN) → backup (Drive) → multi-device self-sync →
the long tail (polls, live location, scheduled, blocking, panic wipe, notification
privacy, profiles).
Each gets its own interop test against iOS.

---

## 9. Open questions for you

1. **FCM (§7.5)** — do I write the `../server/` FCM sender proposal up as a spec for
   the iOS/server session, or do you want Android to ship WS-only first?
2. **`Relay-Sig` bootstrap (§2.3)** — OK to use HTTP Basic for the single
   `PUT /v1/devices/auth-key` call on a fresh device, then signatures for everything
   after?
3. **`assetlinks.json`** — needs `/.well-known/assetlinks.json` on `relaymsg.app`
   for App Links. That's a **website** change (see §7.4), and I can't see the site's
   host or repo from here — where does `apple-app-site-association` actually get
   deployed from?
4. **Stale docs (§0)** — want me to draft corrections to `server/README.md` and the
   root `CLAUDE.md` for the iOS/server session to apply? I haven't touched them.
5. **Package name** — the scaffold is `app.relaymsg.Relay` (capital `R`). Keep, or
   normalize to `app.relaymsg.relay` before Stage 1 (cheap now, painful later)?
6. **Golden vectors** — I'd like a small committed fixture set (serialized `Content`
   samples, OPRF vectors, padding sizes, a sealed cert) generated from the Go/Swift
   side, so Android's tests can assert byte equality without a live server. Fine to
   add under `proto/testvectors/` or `android/src/test/resources/`?
