# relayd — the Relay server

A lean store-and-forward relay for the Relay E2EE messenger. It routes
ciphertext between devices and stores public prekey material; it never sees
message plaintext or private keys.

## Run

```sh
go run ./cmd/relayd -addr :8080 -db relay.db
```

### TLS (recommended for LAN / device testing)

Pass `-tls-cert` and `-tls-key` to serve HTTPS/WSS. Without them the server
runs plain HTTP (fine for loopback, but a same-network attacker can read
metadata and sniff the HTTP Basic device password — message *content* stays
end-to-end encrypted regardless).

Generate a self-signed dev cert (EC P-256, 10 years, SAN = this Mac's LAN IP)
and print the SPKI pin the iOS client must trust:

```sh
sh scripts/gen-dev-cert.sh            # writes ~/.relay-dev/relayd.{crt,key}
```

Then run with TLS:

```sh
~/.relay-dev/relayd -addr 0.0.0.0:8089 -db ~/.relay-dev/relay.db \
    -tls-cert ~/.relay-dev/relayd.crt -tls-key ~/.relay-dev/relayd.key
```

The client pins the cert's public key (`RelayTLS.devPins` in RelayKit). If you
regenerate with a **new** key, update that pin to the value the script prints.
Connect the app to `https://<mac-LAN-ip>:8089`.

## Test

```sh
go test ./...
```

## Wire format

The schema source of truth lives at the repo root in [`../proto/`](../proto/):

- `relay.proto` — server-visible envelopes and WebSocket frames.
- `content.proto` — the plaintext structure clients encrypt. The server
  never parses this; it is included here only so all clients codegen from
  one place.

Regenerate Go code after editing the protos:

```sh
./scripts/genproto.sh
```

## Authentication

Authenticated endpoints accept either of two schemes:

- **Signature (preferred)** — `Authorization: Relay-Sig <accountId>.<deviceId>:<base64 ECDSA-P256 sig>`
  plus `X-Relay-Timestamp` (unix ms) and `X-Relay-Nonce` (base64). The signature is
  ECDSA-P256 over SHA-256 of the canonical string `METHOD "\n" PATH "\n" TIMESTAMP "\n" NONCE`
  using the device's auth key (the same keypair as nuke signatures; the private half never
  leaves the device). Accepted iff the signature validates against the stored
  `auth_public_key`, the timestamp is within ±5 min, and the nonce is unseen in that window.
  Nothing replayable transits the wire. The body is not signed (TLS covers integrity).
- **HTTP Basic (legacy/transition)** — username `<accountId>.<deviceId>`, password = the
  device password. Being phased out; see `TODO.md`.

Account creation is unauthenticated.

## Data at rest

The relay never stores a plaintext email address. When an email is supplied
(registration, social login) it is kept only as its **OPRF-keyed token** — the
same one-way, keyed hash used for blinded discovery. Email lookups (recovery,
OAuth adoption, `by-email`) match on that token, so the email→account link
exists only in keyed form and a database dump can't be reversed to addresses
without the server's OPRF key. Source IPs are used transiently for
rate-limiting and are never logged or persisted; presence/last-seen is kept in
memory only.

## REST API (JSON; binary fields are standard base64)

`auth` column: `sig` = an authenticated endpoint (`Relay-Sig` signature, or HTTP
Basic during the transition — see Authentication); `none` = unauthenticated.
Envelope ids are 32-char hex (16 random bytes), not UUIDs.

### Accounts

| Method & path | Auth | Request → Response |
|---|---|---|
| `POST /v1/accounts` | none | `{username, password, email?, accountPassword?}` → `201 {accountId, deviceId, mailboxId}`. Username `^[a-zA-Z0-9._\-]{1,64}$`, password 8–1024. `409` username taken, `429` >20/IP/hour. Email stored only as its OPRF token. |
| `POST /v1/accounts/oauth` | none (Supabase token) | `{accessToken, password, username?, accountPassword?}`. Verifies the token with Supabase, resolves by Supabase user id then email (back-filling the id) → `201/200 {accountId, deviceId, username, mailboxId, created}`. `404` username required (prompt + retry), `409` taken, `503` Supabase unconfigured. Requires `-supabase-url`/`-supabase-anon-key`. |
| `POST /v1/accounts/recover` | none | `{email, accountPassword}` → `201 {accountId, username, deviceId, devicePassword, mailboxId}`. `404/401/422/503`. Matches on the email's OPRF token. |
| `GET /v1/accounts/by-username/{username}` | none | → `{accountId}`. 600/IP/hour. **Legacy/plaintext** — new clients use blinded discovery. |
| `GET /v1/accounts/by-email/{email}` | sig | → `{accountId, username}`. 3000/account/hour. |
| `GET /v1/accounts/{account}` | sig | → `{username}`. 600/account/hour. |
| `PUT /v1/accounts/me/username` | sig | `{username}` → `204`. `409` taken. Reindexes the blinded directory. |
| `PUT /v1/accounts/me/access-key` | sig | `{accessKey}` (base64, **exactly 32 bytes**) → `204`. Sealed-sender access key; returned to session-establishing peers in `GET /v1/keys/{account}`, presented on the unauthenticated delivery path. Rotating revokes old senders. |
| `POST /v1/accounts/me/nuke` | sig | `{commandId, creationTimeMs, initiatingDeviceId, signature}` → `204`. Signed remote wipe; broadcasts a `Nuke` frame to all live sessions. Signature over `relay-nuke-v1\n…`; rejects >5 min old / >30 s future / duplicate `commandId`. |

### Devices

| Method & path | Auth | Request → Response |
|---|---|---|
| `POST /v1/devices` | sig | `{password, auth{expectedVersion, signerDeviceId, signature}}` → `201 {accountId, deviceId, mailboxId, deviceListVersion}`. Broadcasts `DeviceListChanged(DEVICE_ADDED)`. `409` on stale `expectedVersion`. |
| `GET /v1/devices` | sig | → `{devices:[{deviceId, mailboxId}], deviceListVersion}` |
| `DELETE /v1/devices/{id}` | sig | `{auth{…}}` → `204`. Broadcasts `DEVICE_REMOVED`. |
| `POST /v1/devices/link-invitations` | sig | `{auth{…}}` → `201 {linkToken, verificationCode, expiresAt}` |
| `POST /v1/devices/link-claims` | none | `{linkToken, verificationCode}` → `200 {accountId, deviceId, password, username}`. `404` expired/used, `409` device list changed. Legacy forward-QR flow; superseded by the provisioning-session flow below. |
| `POST /v1/provisioning-sessions` | none | → `201 {sessionId, expiresAt}`. New device mints a blind mailbox for reversed linking; shows `{sessionId, ephemeralPublicKey}` in a QR (ephemeral key never touches the server). 10-min expiry. Rate-limited to 10 sessions / source IP / 10 min (`429`). (Top-level path, not under `/v1/devices/`, to avoid a `{id}` route collision with `/v1/devices/{id}/auth-key`.) |
| `GET /v1/provisioning-sessions/{id}` | none | → `200 {blob}` once the primary has provisioned, `204` while pending, `404` expired/consumed. New device polls this. Single-use: the session is deleted on the first successful fetch. |
| `PUT /v1/provisioning-sessions/{id}` | sig | `{blob}` → `204`. Primary deposits the ciphertext (identity key + credentials, AES-GCM under an ECDH-derived key, **signed by the account identity key** so the new device authenticates the primary). **Write-once** — a session can be provisioned only once, so a second writer can't substitute the payload (`404` if expired/unknown/already used). Blob capped at 64 KiB (`413`). Relay stores only the opaque blob. |
| `POST /v1/devices/link` | sig | `{password, auth{expectedVersion, signerDeviceId, signature}}` → `201 {deviceId}`. Primary creates the new device after scanning the QR; `password` is bound into the mutation signature. `409` on stale `expectedVersion`. No verification code — the camera scan is the trust anchor. |
| `PUT /v1/devices/auth-key` | sig | `{publicKey}` — uncompressed P-256 point `0x04‖X‖Y` (65 bytes), ≤512 B → `204`. Stores the key `Relay-Sig` and nuke/device-list signatures verify against. |
| `GET /v1/devices/{id}/auth-key` | sig | → `{authPublicKey}` (same account only). Lets clients verify a peer device's nuke/device-list signatures. |
| `PUT /v1/devices/apns` | sig | `{token}` → `204`. Registers an APNs token (iOS); sets push kind `apns`. |
| `PUT /v1/devices/fcm` | sig | `{token}` → `204`. Registers a Firebase Cloud Messaging token (Android); sets push kind `fcm`. Requires `-fcm-service-account` for the server to actually send. |
| `PUT /v1/devices/voip` | sig | `{token}` → `204`. PushKit VoIP token (iOS; no Android analogue). |
| `PUT /v1/devices/me/push-content` | sig | `{includeContent}` → `204`. `false` (default) = content-free wake (the device fetches the envelope from `GET /v1/queue`); `true` embeds the encrypted envelope in the push (`"e"`). Applies to both APNs and FCM. |
| `POST /v1/devices/me/mailbox/rotate` | sig | → `200 {mailboxId}`. Fresh opaque mailbox id (clients rotate daily in sealed mode). The offline queue is keyed by (account, device), not mailbox, so queued deliveries are unaffected. |

### Keys

| Method & path | Auth | Request → Response |
|---|---|---|
| `PUT /v1/keys` | sig | `{registrationId, identityKey, signedPreKey{keyId,publicKey,signature}, kyberPreKey{…}, oneTimePreKeys[{keyId,publicKey}], replaceOneTimePreKeys?}` → `204`. Identity/signed/Kyber **replace**; one-time keys **append** by default, or **replace** the device's whole pool when `replaceOneTimePreKeys:true` (deletes this device's existing one-time rows first, in the same transaction — used on fresh install/restore or desync heal so the relay never serves an orphaned key). ≤200 OTKs/upload, 100 uploads/account/hour. Kyber prekey is **required** (PQXDH). |
| `GET /v1/keys/count` | sig | → `{count}`. Replenish below ~20. |
| `GET /v1/keys/{account}[?device=N]` | sig | → `{devices:[{deviceId, mailboxId, registrationId, identityKey, signedPreKey, kyberPreKey, oneTimePreKey|null}], accessKey?}`. Consumes one OTK per device; `null` when exhausted (degraded PQXDH). 200/(requester,target)/hour; own-account fetches exempt. |

### Messaging

| Method & path | Auth | Request → Response |
|---|---|---|
| `POST /v1/messages/sealed` | **none** | `{mailboxId, type, content (base64 sealed blob), accessKey (base64), ephemeral, clientTimestamp}` → `200 {serverTimestamp}`. Verifies `accessKey` matches the destination account (constant-time) without learning the sender, delivers an envelope with **empty sender fields**. `403` for *any* failure (unknown mailbox and wrong key are indistinguishable). 600/IP/min, 120/mailbox/min. |
| `GET /v1/queue` | sig | → `{envelopes:[base64 serialized Envelope]}`. Does **not** dequeue. HTTP/3-capable QUIC fallback for receiving when the TCP WebSocket can't connect. |
| `POST /v1/messages/ack` | sig | `{envelopeId}` → `204`. REST equivalent of the WebSocket ack. |
| `POST /v1/call/{account}` | sig | `{callId, callerName, kind}` → `204`. Fires a VoIP push (iOS/PushKit). |

### Session establishment, discovery, invites, presence

| Method & path | Auth | Request → Response |
|---|---|---|
| `GET /v1/certificate/delivery` | sig | Mint a libsignal sealed-sender certificate (binds account id, device id, stored identity key; 7-day expiry) → `201 {certificate, expiresAt}`. `503` if sealed sender unconfigured, `409` if no keys. Requires `-sealed-sender-trust-key`; clients embed the trust-root public key (logged at startup). |
| `POST /v1/directory/oprf` | sig | `{blinded:[base64 ristretto255,…]}` (1–1024) → `{evaluated:[base64,…]}` (`k·B`). Blinded discovery step 1; the relay never learns the identifiers. Requires `-oprf-key`; `503` if unset. 200/account/hour (shared with resolve). |
| `POST /v1/directory/resolve` | sig | `{tokens:[base64,…]}` (1–1024, unblinded OPRF outputs) → `{results:[{token, accountId, username},…]}`. Unmatched tokens omitted, so non-registered contacts stay private. |
| `POST /v1/contact-invites` | sig | → `201 {token, expiresAt}` (7-day, single-use). Share as `https://relaymsg.app/c/<token>`. |
| `POST /v1/contact-invites/claim` | sig | `{token}` → `{accountId, username}`; `404` invalid/expired/used. Marked used atomically. |
| `POST /v1/group-invites` | sig | `{blob}` (base64 opaque ciphertext, 1–65536 B) → `201 {token, expiresAt}`. 20/account/day. |
| `POST /v1/group-invites/claim` | sig | `{token}` → `{blob}`. Multi-use until expiry. 50/account/hour. Share as `https://relaymsg.app/g/<token>`. |
| `GET /v1/presence/{account}` | sig | → `{online, lastSeen}` (ms since epoch, 0 = never). In-memory only. 300/account/min. |

### Attachments & TURN

| Method & path | Auth | Request → Response |
|---|---|---|
| `POST /v1/attachments` | sig | → `201 {id}` |
| `PUT /v1/attachments/{id}` | sig | raw `application/octet-stream` body → `204`; `413` over the cap. Opaque ciphertext only. |
| `GET /v1/attachments/{id}` | sig | → raw bytes; `404` after TTL reaping. |
| `GET /v1/turn-credentials` | sig | → `{urls[], username, credential, ttl}` (coturn REST HMAC-SHA1, 1 h). `404` when TURN isn't configured — treat as "no TURN", not an error. |

### Real-time

| Method & path | Auth | Purpose |
|---|---|---|
| `GET /v1/ws` | sig | WebSocket upgrade for real-time delivery (see below). |

**Groups are client-authoritative and fully E2E-encrypted. The relay keeps no
group state** — no roster, name, admins, `distribution_id` or `invite_key`. All
of that travels inside the encrypted `content.GroupUpdate`; group messages are
sender-key-encrypted and fanned out per member exactly like 1:1 traffic. The
only group-related server surface is the opaque `group-invites` blob store
above. (Earlier revisions had `/v1/groups*` roster endpoints; they were removed.)

## WebSocket protocol

Every binary WS message is one serialized `relay.v1.ClientFrame`
(client→server) or `relay.v1.ServerFrame` (server→client).

On connect the server drains the device's offline queue as `Envelope`
frames, then sends `QueueEmpty`; everything after that is real-time.

**Sending (`SendRequest`) is per-mailbox, one device per frame.**
`destination_account` is an **opaque mailbox id** (not an account id), and
`messages` must contain **exactly one** `DeviceMessage` for the device behind
that mailbox — the server rejects any other count with
`SEND_STATUS_MISMATCHED_DEVICES`. To reach every device of a recipient the
sender sends N separate frames, one per mailbox. On a cross-account send the
response lists the recipient's other registered devices in `missing_devices`
(and `extra_devices`/`stale_devices` when the addressed device id or
`registration_id` is wrong) so the sender can fetch those bundles and send the
remaining frames; a stale `registration_id` yields `stale_devices`. Self-sends
(own-device sync) skip the missing-devices hint. Unknown mailbox →
`SEND_STATUS_UNKNOWN_ACCOUNT`.

Delivery is at-least-once: envelopes stay in the queue until the client
acks them (`AckRequest{envelope_id}`); clients must deduplicate by envelope
id. `ephemeral` envelopes (typing indicators) skip the queue entirely. When a
destination device is offline (or its socket is backlogged) the server fires a
push (APNs or FCM per the device's registered kind) to wake it.

## Push (APNs + FCM)

The relay wakes offline devices over **APNs** (iOS) or **FCM** (Android),
chosen per device by which token it registered (`push_kind`). Both are optional
and disabled unless configured; without them the envelope still delivers on the
device's next connect.

**Content-free by default.** The push carries **no message data** — for APNs an
`alert`/`mutable-content` wake, for FCM a **data-only** message (no
`notification` block) so the app, not the OS, decides what to show. The device
then fetches the encrypted envelope from `GET /v1/queue`, decrypts it
on-device, and acks via `POST /v1/messages/ack`. So neither Apple nor Google
ever carries message content.

**Opt-in ciphertext-in-push** (`PUT /v1/devices/me/push-content
{includeContent:true}`) embeds the base64 `Envelope` under key `"e"` for a
faster wake without a fetch — identical on both providers. FCM's data payload is
capped at ~4 KB, so an envelope that would exceed the budget silently degrades
to a content-free wake (the device fetches it from the queue instead); the
message stays end-to-end encrypted either way.

Flags:
- APNs: `-apns-key` (`.p8`), `-apns-key-id`, `-apns-team-id`, `-apns-topic`,
  `-apns-production`. The same key also sends PushKit VoIP on the `.voip` sub-topic.
- FCM: `-fcm-service-account` (path to a Firebase service-account JSON key). The
  sender uses FCM HTTP v1 with a service-account-signed OAuth2 token.
