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

| Method & path | Auth | Purpose |
|---|---|---|
| `POST /v1/accounts` | none | Create account + primary device. Body `{username, password}` → `201 {accountId, deviceId}` |
| `POST /v1/accounts/oauth` | none (Supabase token) | Sign in (or create) a social-login account and provision a fresh device. Body `{accessToken, password, username?, accountPassword?}`. The relay verifies `accessToken` with Supabase (`GET /auth/v1/user`) and resolves the account by Supabase user id, then email (back-filling the id). Returns `201 {accountId, deviceId, username, mailboxId, created:true}` on create, `200 {…, created:false}` on recover. `404` when no account exists yet and no `username` was supplied (client should prompt), `409` if the chosen username is taken, `503` if Supabase auth isn't configured on the server. Requires the `-supabase-url` / `-supabase-anon-key` flags. |
| `POST /v1/contact-invites` | basic | Mint a single-use contact invite token → `201 {token, expiresAt}` (7-day expiry). Share as `https://relaymsg.app/c/<token>`. |
| `POST /v1/contact-invites/claim` | basic | Redeem a contact invite. Body `{token}` → `200 {accountId, username}`; `404` if invalid, expired, or already used. Marked used atomically so it resolves exactly once. |
| `POST /v1/messages/sealed` | **none** | Sealed-sender delivery. Body `{mailboxId, type, content (base64 sealed blob), accessKey (base64), ephemeral, clientTimestamp}`. Server verifies `accessKey` matches the destination account (constant-time) without learning the sender, then delivers an envelope with **empty sender fields** → `200 {serverTimestamp}`; `403` on any failure (doesn't reveal mailbox existence). Rate-limited per IP + per mailbox. |
| `GET /v1/queue` | basic | Return this device's currently-queued envelopes (base64) without dequeuing → `{envelopes[]}`. HTTP/3-capable QUIC fallback for receiving when the TCP WebSocket can't connect (congested networks); the client acks each via the endpoint below. |
| `POST /v1/messages/ack` | basic | Remove a delivered envelope from this device's queue. Body `{envelopeId}` → `204`. REST equivalent of the WebSocket ack. |
| `PUT /v1/accounts/me/access-key` | basic | Store this account's 32-byte sealed-sender access key. Body `{accessKey}` (base64) → `204`. Returned to session-establishing peers in `GET /v1/keys/{account}` (`accessKey`); presented on the unauthenticated delivery path. Rotating it revokes old senders. |
| `POST /v1/devices/me/mailbox/rotate` | basic | Assign this device a fresh opaque mailbox id → `200 {mailboxId}`. Clients rotate daily (in sealed-sender mode) so the relay can't track a long-lived routing identifier. Peers pick up the new id on their next `GET /v1/keys/{account}` fetch; sealed sends to the stale id get `403` and the sender refreshes + retries. The offline queue is keyed by (account, device), not mailbox, so queued deliveries are unaffected. |
| `GET /v1/certificate/delivery` | basic | Mint a libsignal sealed-sender certificate for this device (binds account id, device id, stored identity key; 7-day expiry) → `201 {certificate, expiresAt}`. `503` if sealed sender isn't configured, `409` if the device hasn't published keys. Requires the `-sealed-sender-trust-key` flag; clients embed the trust-root public key (logged at startup) to validate. |
| `POST /v1/devices` | basic | Register an additional device. Body `{password}` → `201 {accountId, deviceId}` |
| `PUT /v1/devices/apns` | basic | Store this device's APNs token. Body `{token}` → `204` |
| `PUT /v1/devices/me/push-content` | basic | Set this device's push-content preference. Body `{includeContent}` → `204`. `false` (default) = content-free wake (payload carries no message; the NSE fetches the envelope from `GET /v1/queue`). `true` = the relay embeds the encrypted envelope in the APNs payload (`"e"`) for a faster wake without a fetch. Message stays E2E-encrypted either way. |
| `PUT /v1/keys` | basic | Upload `{registrationId, identityKey, signedPreKey{keyId, publicKey, signature}, kyberPreKey{keyId, publicKey, signature}, oneTimePreKeys[{keyId, publicKey}]}` → `204`. Identity, signed prekey and (last-resort) Kyber prekey replace; one-time prekeys append. PQXDH requires the Kyber prekey. |
| `GET /v1/keys/count` | basic | Remaining one-time prekeys for this device → `{count}`. Clients replenish below ~20. |
| `GET /v1/keys/{account}?device=N` | basic | Fetch prekey bundles (all devices when `?device` omitted), each with identity key, signed prekey and Kyber prekey. Consumes one one-time prekey per device; `oneTimePreKey` is `null` when the pool is exhausted (degraded PQXDH via signed prekeys only). |
| `POST /v1/directory/oprf` | basic | Blinded discovery, step 1. Body `{blinded:[base64 ristretto255 element,…]}` (1–1024) → `{evaluated:[base64,…]}` where each is `k·B`. The relay evaluates the OPRF under its secret key without learning the identifiers being queried. Requires `-oprf-key`; `503` if unset. Rate-limited per account. |
| `POST /v1/directory/resolve` | basic | Blinded discovery, step 2. Body `{tokens:[base64,…]}` (the OPRF outputs the client derives after unblinding) → `{results:[{token, accountId, username},…]}`. Unmatched tokens are omitted, so non-registered contacts stay private. Rate-limited per account. |
| `GET /v1/accounts/by-username/{username}` | basic | Resolve username → `{accountId}`. **Legacy/plaintext** — kept for compatibility; new clients use blinded discovery. |
| `GET /v1/accounts/{account}` | basic | Resolve account id → `{username}` |
| `GET /v1/presence/{account}` | basic | Connection state → `{online, lastSeen}`. `online` = any device has a live WebSocket; `lastSeen` is ms since epoch of the last connect/disconnect (0 if never). |
| `POST /v1/attachments` | basic | Allocate an attachment id → `201 {id}` |
| `PUT /v1/attachments/{id}` | basic | Upload the encrypted blob (raw `application/octet-stream`) → `204`. `413` if over the size cap. The relay stores opaque ciphertext only. |
| `GET /v1/attachments/{id}` | basic | Download the encrypted blob (raw bytes) → `200` / `404`. Reaped after the TTL. |
| `POST /v1/groups` | basic | Create a group. Body `{name, members[]}` (creator added automatically) → `201 {id, name, distributionId, revision, members[]}`. |
| `GET /v1/groups/{id}` | basic | Group roster + state; members only (`403` otherwise). |
| `POST /v1/groups/{id}/members` | basic | Add a member. Body `{account}` → updated group. Revision bumps; distribution id unchanged. |
| `DELETE /v1/groups/{id}/members/{account}` | basic | Remove a member (or self = leave) → updated group. **Rotates `distributionId`** so the removed member can't read future messages. |
| `PUT /v1/groups/{id}` | basic | Rename. Body `{name}` → updated group. |
| `GET /v1/ws` | basic | WebSocket upgrade for real-time delivery |

The relay stores the group roster (member account ids) and a `distributionId` (the current sender-key epoch) but never sees group message plaintext — group messages are sender-key-encrypted and fanned out per member, exactly like 1:1 traffic.

## WebSocket protocol

Every binary WS message is one serialized `relay.v1.ClientFrame`
(client→server) or `relay.v1.ServerFrame` (server→client).

On connect the server drains the device's offline queue as `Envelope`
frames, then sends `QueueEmpty`; everything after that is real-time.

Sending (`SendRequest`) fans out per device: the sender must include one
ciphertext for **every** registered device of the destination account
(omitting its own device when messaging itself). If the device list is
wrong or a `registration_id` is stale, the server rejects the entire send
with `SEND_STATUS_MISMATCHED_DEVICES` and lists
`missing/extra/stale_devices` so the client can re-fetch bundles and retry
— partial fan-out never happens.

Delivery is at-least-once: envelopes stay in the queue until the client
acks them (`AckRequest{envelope_id}`); clients must deduplicate by envelope
id. `ephemeral` envelopes (typing indicators) skip the queue entirely.
