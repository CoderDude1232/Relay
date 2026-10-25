# relayd — the Relay server

A lean store-and-forward relay for the Relay E2EE messenger. It routes
ciphertext between devices and stores public prekey material; it never sees
message plaintext or private keys.

## Run

```sh
go run ./cmd/relayd -addr :8080 -dsn 'postgres://relay:relay@localhost/relay?sslmode=disable'
```

`-dsn` (or `$RELAY_DSN`) is **required**: there is no built-in default DSN, and
relayd exits with an error when neither is set.

**Run PostgreSQL on the relay host** (loopback or a unix socket, e.g.
`-dsn 'postgres:///relay?host=/var/run/postgresql'`). The DB connection carries
every routing row and queued envelope; if the DSN names a non-local host and
sets no `sslmode`, relayd logs a warning at startup (pgx's default silently
falls back to plaintext). For a remote DB use `sslmode=verify-full`.

### Operational flags

| Flag | Default | Meaning |
|---|---|---|
| `-log-level` | `warn` | `debug`, `info`, `warn` or `error`. Per-connection / per-message events (session registered, push sent, …) are `debug`; startup lines (incl. the sealed-sender trust-root public key) are `info`. |
| `-attachment-ttl` | `336h` (14 d) | Attachment blobs older than this are deleted (hourly GC). |
| `-attachment-daily-bytes` | `2147483648` (2 GiB) | Per-account upload budget, bytes per rolling day. |
| `-attachment-daily-count` | `1000` | Per-account `POST /v1/attachments` allocations per rolling day. |
| `-max-attachment` | 25 MiB | Max size of one attachment blob. |
| `-attachment-disk-cap` | `21474836480` (20 GiB) | Global attachment disk watermark: once the blob directory holds this many bytes, `POST /v1/attachments` and `PUT /v1/attachments/{id}` answer `507` until GC frees space. `0` = unlimited. Usage is measured at startup and tracked in memory; each upload reserves its declared `Content-Length` (or the 26 MiB request limit when chunked) against the cap before writing, so in-flight uploads can't overshoot it. |
| `-passkey-rp-id` | `relaymsg.app` | WebAuthn relying party ID for passkeys (see *Passkeys*). Override for local testing (e.g. `localhost`). |
| `-passkey-origins` | `https://relaymsg.app` | Comma-separated origins accepted in a passkey's `clientDataJSON`. |
| `-history-dir` | `/var/lib/relay/history` | Directory for chat-history backup segments (created `0700`; must be writable by relayd). If it can't be opened, history backup is disabled and the routes answer `507`; the relay still starts. History backup also needs `-oprf-key` (see *History backup storage*). |
| `-history-min-free` | `2147483648` (2 GiB) | Free bytes to keep on the `-history-dir` filesystem. Below it, new segments go to `-history-remote-url`. |
| `-history-remote-url` | (none) | historyd base URL, e.g. `https://turn.relaymsg.app:9479`. Empty = no failover (a full local disk means `507`). |
| `-history-remote-secret-file` | (none) | File holding the secret shared with historyd (≥ 32 bytes, e.g. `openssl rand -hex 32`). Required with `-history-remote-url`. |

HTTP server limits: 10 s to read request headers, 16 KiB max headers, 120 s
keep-alive idle timeout, and per-request deadlines of 30 s (read) / 60 s
(write) — 10 min for attachment upload/download, 3 min for `/v1/history/{seq}`,
none for the WebSocket.

### Retention

An hourly sweeper (also run at startup) deletes:

| Data | Kept for |
|---|---|
| Queued envelopes (`message_queue`) | 14 days, or until acked |
| Attachment blobs | 14 days (`-attachment-ttl`) |
| Abuse reports | 180 days |
| Nuke commands | 1 hour (only deliverable inside the 5-min freshness window) |
| Contact invites | until used or expired (7 d) |
| Released-username hashes (`released_usernames`) | 7 days (the reuse cooldown) |
| Group invites, provisioning sessions | until expired |
| Devices that never published an identity key (an unfinished link) | 1–2 days: reaped once created before yesterday (creation times are kept to the day), only on accounts that have a keyed device. Removed like `DELETE /v1/devices/{id}` (prekeys, queue, `device_list_version` bump, socket closed, `DEVICE_REMOVED` broadcast) |
| History backup segments (`history_segments` + blobs) | until the client deletes them, the account is deleted, or a demo reset. Kept across sign-ins that replace devices. A separate hourly sweep (not at startup) deletes blobs, local or remote, that no row refers to and that are over an hour old |

### TLS (recommended for LAN / device testing)

Pass `-tls-cert` and `-tls-key` to serve HTTPS/WSS. Without them the server
runs plain HTTP (fine for loopback, but a same-network attacker can read
metadata and sniff the bootstrap HTTP Basic device password — message *content* stays
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

Authenticated endpoints use **Relay-Sig v2** per-request signatures:

```
Authorization:          Relay-Sig <accountId>.<deviceId>:<base64 ECDSA-P256 (DER) signature>
X-Relay-Timestamp:      <unix ms>
X-Relay-Nonce:          <base64 of 16–64 random bytes>
X-Relay-Content-SHA256: <hex>   (optional; see below)
```

The signature is ECDSA-P256 over SHA-256 of the canonical string (fields joined by `\n`):

```
relay-sig-v2
METHOD
REQUEST-URI      escaped path + "?" + raw query when present, e.g. /v1/queue?limit=100&cursor=…
ACCOUNT-ID
DEVICE-ID        canonical decimal (no leading zeros / sign — "01" is rejected)
TIMESTAMP
NONCE            exactly as sent
BODY-SHA256      lowercase hex SHA-256 of the request body (of "" when empty)
```

signed with the device's auth key (the same keypair as nuke/device-list
signatures; the private half never leaves the device). Accepted iff the
signature validates against the stored `auth_public_key`, the timestamp is within
±5 min, and the (account, device, decoded nonce) triple is unseen in that window.
The replay cache keys entries by salted hash (never raw ids), buckets them by
expiry into 5-minute slots that are dropped whole, and lets one device hold at
most 20 000 nonces per slot (~66 signed requests/s sustained); past that the
device gets `429` until the slot expires.
The replay cache lives in memory, so a valid signature whose timestamp is
**before the relay process started** is refused with `425 Too Early` (never
`401`, and not counted as a failed authentication): it might be a request
captured before a restart. Clients re-sign and retry once; a client whose clock
runs slow sees `425` only until its clock passes the start time.
The server **always buffers and hashes the body itself** (bodies are capped at
1 MiB, 2 MiB for `PUT /v1/history/{seq}`; an oversized body gets `413`, not
`401`); an `X-Relay-Content-SHA256` header, if sent, must equal that hash. The
only route on which a declared digest may instead be checked while the body
streams (the read fails at EOF on mismatch) is `PUT /v1/attachments/{id}` — and
that route is unauthenticated today. JSON bodies must hold **exactly one JSON
value**: trailing data after it is rejected (`400`), so the body a handler acts
on is always the whole body the signature covers.

**HTTP Basic** (`<accountId>.<deviceId>` : device password) is a bootstrap
credential only: it is accepted on **exactly one route, `PUT /v1/devices/auth-key`**,
and only for a device that has **not** registered an auth key. Every other
authenticated route refuses Basic with `401 "this endpoint requires Relay-Sig
authentication"` before any password work (counted toward the per-IP failure
budget). Once a key exists the bootstrap route refuses Basic too (`401`), and
changing the key requires a request signed by the old key. Successful Basic
authentications are capped at **10 per device per hour** (`429`), since each
costs a bcrypt and a device needs only one. The WebSocket upgrade is signed the
same way as any request (`GET /v1/ws`, empty body).

Unauthenticated endpoints (`auth` = `none` below) must be sent **without**
credentials, and the iOS client sends them over a separate ephemeral
`URLSession` (no cookies/cache, no shared connection) so they can't be tied to
the logged-in connection.

**Failed-auth throttling.** Failed authentications are counted per source IP
bucket (50 per 10 min, both schemes) and, for HTTP Basic, per target device
(20 per 10 min). Once a budget is spent the server answers `429` without doing
any password hashing / signature work until it refills. (Relay-Sig is never
throttled per device, so a third party can't lock a device out by failing on
its behalf.)

## Data at rest

The relay never stores a plaintext email address, and never stores an
**unverified** one: an email is only ever taken from a Supabase access token the
relay verifies server-side, and kept only if Supabase reports it confirmed. It is
stored as its **OPRF-keyed token** — the same one-way, keyed hash used for
blinded discovery. Email lookups (recovery, OAuth adoption) match on that token,
so the email→account link exists only in keyed form and a database dump can't be
reversed to addresses without the server's OPRF key. The email is findable
through blinded discovery **only if its owner opted in**
(`PUT /v1/accounts/me/discoverability`; off by default). Source IPs are used
transiently for rate-limiting and are never logged or persisted. The relay keeps
no presence or last-seen data at all. A recovery key is stored only as its
SHA-256 hash (see *Recovery key*).

**Rate-limiter state holds no raw identifiers.** Every in-memory limiter key —
a source-IP bucket (full IPv4 address, or the IPv6 **/64**), an account id, a
requester:target pair — is replaced by an HMAC under a random salt that lives
only in memory and rotates every 24 h (limiter counters restart on rotation).
The other long-lived in-memory maps are keyed the same way: the demo-flag cache,
the recovery backoff, pending passkey ceremonies (account id or source IP), and
the hub's queue-share and push-coalescing bookkeeping. Those that must still
match after a rotation (queue shares live for the 14-day queue TTL; a pending
ceremony must be found again) use a salt that lasts as long as the process
instead. Live WebSocket sessions are the exception: they are indexed by account
and device for routing and live only as long as the connection.

**Coarse timestamps.** `accounts.created_at` / `devices.created_at` are stored
at day granularity (existing rows were truncated); prekey rows store no upload
time (it used to be rewritten on every upload, acting as a last-active log).
`passkeys.created_at` and `history_segments.created_at` are day-rounded too; `message_queue.created_at` stays exact because it drives ordering and
the 14-day TTL.

The one exception to "ciphertext only" is an abuse report (`POST /v1/reports`):
it stores the plaintext messages the reporter explicitly chose to forward,
plus their free-text details, in the `reports` table.

## REST API (JSON; binary fields are standard base64)

`auth` column: `sig` = an authenticated endpoint (`Relay-Sig` signature; HTTP
Basic only for the first `PUT /v1/devices/auth-key` — see Authentication);
`none` = unauthenticated.
Envelope ids are 32-char hex (16 random bytes), not UUIDs.

### Sign-in change notices

When a signed device adds or removes a passkey, sets or removes the recovery
key, sets the account password, or removes or changes the email, the relay
records an `AccountNotice{kind, time_ms}` (relay.proto) for each of the
account's **other** devices. Connected devices get it at once as a WebSocket
frame; the rest get it right after `QueueEmpty` on their next connection. A
notice is deleted once sent, when its device is removed, or after 30 days.
Kinds: `passkey_added`, `passkey_removed`, `recovery_key_set`,
`recovery_key_removed`, `account_password_set`, `email_removed`,
`email_changed`.

### Account password on the wire

Current clients never send the account password. They send
`accountPasswordKey`: base64url of Argon2id(password, salt =
SHA-256("relay-account-password-key-v1")[0..16], opslimit moderate, memlimit
interactive, 32 bytes). The chat-list blob's password slot uses a different
derivation (salted with the account id), so the relay can't open it with what
it receives. Wherever this table says `accountPassword`, a request may carry
`accountPasswordKey` instead; older clients still send the raw password as
`accountPassword`. The stored hash records which it is (`k2$` + bcrypt for a
key). A key never matches a hash of a raw password: the relay doesn't ask for
the raw password (a malicious relay could at will). Such accounts set a new
password from a signed-in current client, or reset it.

### Accounts

| Method & path | Auth | Request → Response |
|---|---|---|
| `POST /v1/accounts` | none | `{username, password, supabaseAccessToken?, accountPassword?}` → `201 {accountId, deviceId, mailboxId}`. Username `^[a-zA-Z0-9._\-]{1,64}$` (unique **case-insensitively**), password 8–1024. A raw `email` field is rejected (`400`). With `supabaseAccessToken` the relay verifies the token with Supabase, links the Supabase user id, and stores the email's OPRF token **only if Supabase reports it confirmed** (`email_confirmed_at`). `409 "username already taken"`; `409` generic "sign in instead" when the identity already belongs to an account; `401` bad token; `503` Supabase unconfigured; `429` >20/IP/hour. |
| `POST /v1/accounts/oauth` | none (Supabase token) | `{accessToken, password, username?, accountPassword?}`. Verifies the token with Supabase, resolves by Supabase user id, then — **only if the Supabase email is confirmed** — by email token (back-filling an empty Supabase link; never overwriting another user's) → `201 {…, created:true}` for a new account / `200 {…, created:false}` for an existing one, body `{accountId, deviceId, username, mailboxId, created}`. **Signing in to an existing account replaces all of its devices** (a fresh install has no copy of the identity key; like re-registering in Signal): their prekeys and queues are deleted, each gets `DeviceListChanged(DEVICE_REMOVED)` and its socket is closed, then one new device is provisioned (`deviceListVersion` bumped). **Registration lock:** when that existing account has an account password set (at sign-up via `accountPassword`, or `PUT /v1/accounts/me/account-password`), the request must carry it as `accountPassword` — missing → `423 {"error":"account password required"}`, wrong → `423 {"error":"account password incorrect"}`, and nothing is changed. Wrong guesses back off per account like recovery (5 free, then 1 min doubling to ≤24 h → `429 "too many account password attempts; try again later"`, even for the right password while locked). A supplied `accountPassword` always costs one bcrypt (against a dummy hash when the account has no lock), so timing doesn't reveal whether a lock is set. Accounts without an account password sign in as before, unless they have a passkey or recovery key: then `403` (sign in with one of those; the email inbox alone can't take the account over). For a **new** account, `accountPassword` (8–1024) sets its account password. `404` username required (prompt + retry), `409` taken (incl. the username reuse cooldown), `503` Supabase unconfigured. Requires `-supabase-url`/`-supabase-anon-key`. Supabase calls time out after 10 s. |
| `PUT /v1/accounts/me/account-password` | sig | `{accountPassword}` (8–1024 bytes) → `204`. Sets or changes the account password (bcrypt), which guards email recovery (`POST /v1/accounts/recover`) **and** the sign-in registration lock above. Any signed device of the account may set it. `400` bad length; `429` past 10 changes/account/hour. |
| `POST /v1/accounts/recover` | none | `{email, accountPassword}` → `201 {accountId, username, deviceId, devicePassword, mailboxId}`. **Every** failure (unknown email, no recovery password, wrong password) is the same `401 "recovery failed"` after the same bcrypt work; after 5 failures per email the email is locked out with exponential backoff (1 min doubling, ≤24 h → `429`), applied identically to registered and unregistered emails. Like a social sign-in to an existing account, recovery **replaces all of the account's devices** (each gets `DEVICE_REMOVED` and its socket closed) and provisions one new device; bumps `deviceListVersion`. `503` without OPRF. |
| `POST /v1/accounts/password-reset` | none | `{accessToken, accountPassword, password}` (both passwords 8–1024) → `201 {accountId, username, deviceId, mailboxId}`. "Forgot password": `accessToken` must be a Supabase session minted by a **password-recovery code** (its `amr` has a `recovery` entry) **within 15 minutes**, for a confirmed email — any other session gets `403`, so a stolen sign-in can't bypass the account-password lock. Finds the account by Supabase user id, then by email token (`404` if none); sets the new account password; like any fresh sign-in, **replaces all devices** with this one (`DEVICE_REMOVED` to the old ones). **Registration lock:** if the account has an account password and any of its devices made a signed request in the last 7 days, the reset is refused with `423` (sign in with the account password instead, or wait until the account has gone 7 days unused). Devices record only the *day* of their last signed request (`devices.last_active_day`, written at most once a day). `403` also when the account has a passkey or recovery key; `401` invalid session; `429` per-IP limit. |
| `PUT /v1/accounts/me/email` | sig | `{accessToken}` → `204`. After the user confirms a new email with Supabase, re-keys the account's email token so recovery and opt-in email discovery follow the new address. The session must belong to the account's **linked** Supabase user (`403` otherwise) and its email must be confirmed (`401`). `409` if another account already uses that email. |
| `GET /v1/usernames/{name}/available` | none | → `{available: bool}` (case-insensitive; `false` also while the name is in its reuse cooldown). Never returns an account id. `400` invalid name. 120/IP/hour. (Replaces the removed `GET /v1/accounts/by-username` and `GET /v1/accounts/by-email` lookups.) |
| `PUT /v1/accounts/me/username` | sig | `{username}` → `204`. `409` taken (case-insensitive; changing the case of your own name is allowed). Reindexes the blinded directory. At most **5 completed changes per account per rolling day** (`429`; a `409` costs nothing). The old name enters the **username reuse cooldown** (below); `409` also when the requested name is in another account's cooldown. |
| `PUT /v1/accounts/me/discoverability` | sig | `{email: bool}` (required) → `204`. **Email discovery is opt-in**: an account's verified email gets a blinded-directory entry only while this is `true` (`accounts.email_discoverable`, default `false` — existing accounts included). Reindexes the account immediately. Username entries are unaffected (always discoverable). `400` when `email` is missing / not a bool. |
| `GET /v1/accounts/me/phone` | sig | → `200 {hasPhone, discoverable, available, allowedPrefixes}`. **Optional phone number, for discovery only** (never a way to sign in, never shown to anyone). `available` is false until the relay has Twilio configured. `allowedPrefixes` is `-phone-allowed-prefixes` (e.g. `["+61"]`), so the app offers only those countries. |
| `POST /v1/accounts/me/phone/start` | sig | `{phone}` (E.164, e.g. `+61412345678`) → `204` once Twilio Verify has texted a code. `400` bad format or a number Twilio rejects; `422` country not in `-phone-allowed-prefixes`; `429` over a limit (3 sends a day per account and per number, 5 per source address, `-phone-daily-cap` across everyone); `503` not configured; `403` demo account. The relay stores nothing at this point. |
| `POST /v1/accounts/me/phone/verify` | sig | `{phone, code, discoverable}` → `204`. A correct code stores the number's **OPRF token** (`accounts.phone_token`, never the number) and `phone_discoverable`, and reindexes: a discoverable number gets a blinded-directory entry (kind 2) found the same way as emails. A number belongs to one account; verifying it takes it from any other account. Posts a `phone_added` account notice. `401` wrong or expired code; `429` over 10 checks an hour. |
| `PUT /v1/accounts/me/phone/discoverability` | sig | `{discoverable: bool}` → `204`; `404` when the account has no number. |
| `DELETE /v1/accounts/me/phone` | sig | → `204`. Removes the token and its directory entry; posts `phone_removed`. |
| `PUT /v1/accounts/me/access-key` | sig | `{accessKey}` (base64, **exactly 32 bytes**) → `204`. Sealed-sender access key; returned to session-establishing peers in `GET /v1/keys/{account}`, presented on the unauthenticated delivery path. Rotating revokes old senders. |
| `DELETE /v1/accounts/me` | sig | Optional body `{appleAuthorizationCode?}` (empty body allowed; malformed JSON → `400` and nothing is deleted) → `204`. When `appleAuthorizationCode` is present and the relay runs with `-siwa-key` (see *Sign in with Apple* below), the relay, after deleting the account, exchanges the code at Apple's `/auth/token` and revokes the resulting refresh token at `/auth/revoke` (App Store guideline 5.1.1(v)) — **best-effort**: Apple failing or timing out (10 s) never fails the deletion, and the code/tokens are never stored or logged. Unconfigured relays ignore the field. The client must obtain a **fresh** code (re-authenticate with Apple; codes expire after 5 minutes and are single-use) right before calling. **Permanently deletes the authenticated account** and everything keyed to it, in one DB transaction: devices (mailbox ids, auth keys, APNs/FCM/VoIP tokens), signed/Kyber/one-time prekeys, queued envelopes for its devices, contact invites it minted, blinded-directory rows, stored nuke commands, reports it **filed**, its passkeys, and the account row (username, email token, Supabase user id, access key, recovery hash, recovery key hash, passkey user handle). Then closes all of the account's live WebSockets (close code 1008, "account deleted"). A linked Supabase auth user is queued for deletion (`pending_supabase_deletions`, holding only its Supabase user id) in the same transaction, and with `-supabase-service-key-file` deleted right away via the admin API; if Supabase can't be reached the deletion still succeeds and relayd retries the queue at startup and hourly until Supabase confirms (`404` counts as done). A queued user that is linked to an account again before the retry (the person signed up anew) is dropped from the queue, not deleted. Afterwards its credentials get `401`; the username enters the 7-day reuse cooldown (claimable by **no one** until it ends) and is then free to register again. **Kept:** reports filed *against* the account (moderation records). **Not reachable:** anonymous `provisioning_sessions` / `encrypted_group_invites` (no account column; TTL-reaped), attachment blobs (ownership isn't tracked; reaped by blob GC), and envelopes it sent that sit in *other* accounts' queues (the recipients' data). No extra confirmation signature — clients must confirm with the user before calling. |
| `GET /v1/accounts/me/sign-in-methods` | sig | → `200 {email: bool, passkeys: int, accountPassword: bool, recoveryKey: bool, accountPasswordNeedsUpdate: bool}`. `email` is true when the account has an email token **or** a Supabase link; `passkeys` is the passkey count; `accountPassword` / `recoveryKey` whether each is set. `accountPasswordNeedsUpdate` is true when the stored password hash predates key derivation (a hash of the raw password, which a current client's key never matches): the client asks the user to enter it again. Lets the client warn before removing the last way back in. |
| `POST /v1/accounts/me/nuke` | sig | `{commandId, creationTimeMs, initiatingDeviceId, signature}` → `204`. Signed remote wipe; broadcasts a `Nuke` frame to all live sessions. Signature over `relay-nuke-v1\n…`; rejects >5 min old / >30 s future / duplicate `commandId`. |

**Reserved usernames.** Nobody can take a name the app uses for you or its own
chats, or one that would pass for staff or the system: `you`, `me`, `notetoself`,
`system`, `admin`, `support`, `official`, `deleted` and similar, and anything
starting with `relay`. Names are compared after lower-casing, reading look-alike
digits and symbols as letters (`0`→o, `1`→i/l, `3`→e, `@`→a, …) and dropping
everything but letters, so `Note_To_Self` and `re1ay` count. Registration, OAuth
and passkey sign-up and rename answer `409 "username already taken"`, and
`/available` reports `false` (`internal/store/reserved_names.go`; the app applies
the same rule to display names).

**Username reuse cooldown.** Sealed-sender certificates carry the sender's
username for up to 7 days, so a released name — renamed away from, or freed by
account deletion — can't be claimed by **another** account for **7 days**
(registration, OAuth sign-up and rename all answer `409 "username already
taken"`, and `/available` reports `false`). The account that renamed away may
take its own old name back during the cooldown (same account, same
certificates); a deleted account's name is blocked for everyone. The relay
stores only `HMAC(k, lower(name))`, `HMAC(k, owner account id)` (null after
deletion) and the release time in `released_usernames` — never the name — with
`k` derived from the OPRF key (so the cooldown requires `-oprf-key`; without it
nothing is recorded). Rows are purged by the hourly retention sweep when the
cooldown ends.

### Reports

| Method & path | Auth | Request → Response |
|---|---|---|
| `POST /v1/reports` | sig | `{reportedAccount, reason, details?, messages?}` → `204`. `reason` ∈ `spam`, `harassment`, `inappropriate`, `impersonation`, `other`. `details` ≤2000 chars; `messages` ≤10 entries of ≤4000 chars each — plaintext messages the reporter **explicitly chose to forward** (the only way message content ever reaches the relay). `400` bad reason / oversize / reporting yourself, `404` unknown `reportedAccount`, `429` >20 reports/reporter/24 h (in-memory sliding window, like the other limiters). Stored in the `reports` table (`id, reporter_account, reported_account, reason, details, messages, created_at`; `messages` is a JSON array as text), with **no foreign keys**: reports are moderation records, so a report *against* an account survives that account's deletion, while reports an account *filed* are deleted with it (its own data). No read API yet — query the table directly. |

### Devices

| Method & path | Auth | Request → Response |
|---|---|---|
| `POST /v1/devices` | sig | `{password, auth{expectedVersion, signerDeviceId, signature}}` → `201 {accountId, deviceId, mailboxId, deviceListVersion}`. Broadcasts `DeviceListChanged(DEVICE_ADDED)`. `409` on stale `expectedVersion` or when the account already has 5 devices. |
| `GET /v1/devices` | sig | → `{devices:[{deviceId, mailboxId}], deviceListVersion}` |
| `DELETE /v1/devices/{id}` | sig | `{auth{…}}` → `204`. Deletes the device and, in the same transaction, its signed/Kyber/one-time prekeys and queued envelopes (its push tokens and auth key live on the device row). Closes the device's live WebSocket and broadcasts `DEVICE_REMOVED`. Device ids are allocated from a monotonic per-account counter, so a removed id is **never reused**. |
| `POST /v1/provisioning-sessions` | none | → `201 {sessionId, expiresAt}`. New device mints a blind mailbox for reversed linking; shows `{sessionId, ephemeralPublicKey}` in a QR (ephemeral key never touches the server). 10-min expiry. Rate-limited to 10 sessions / source IP / 10 min (`429`). (Top-level path, not under `/v1/devices/`, to avoid a `{id}` route collision with `/v1/devices/{id}/auth-key`.) |
| `GET /v1/provisioning-sessions/{id}` | none | → `200 {blob}` once the primary has provisioned, `204` while pending, `404` expired/consumed. New device polls this. Single-use: the session is deleted on the first successful fetch. Polls are limited per source IP (burst 120, then 1/s; `429`) — poll at most once a second. |
| `PUT /v1/provisioning-sessions/{id}` | sig | `{blob}` → `204`. Primary deposits the ciphertext (identity key + credentials, AES-GCM under an ECDH-derived key, **signed by the account identity key** so the new device authenticates the primary). **Write-once** — a session can be provisioned only once, so a second writer can't substitute the payload (`404` if expired/unknown/already used). Blob capped at 64 KiB (`413`). Relay stores only the opaque blob. |
| `POST /v1/devices/link` | sig | `{password, auth{expectedVersion, signerDeviceId, signature}}` → `201 {deviceId}`. `password` must be 8–1024 characters (`400` otherwise). Primary creates the new device after scanning the QR; `password` is bound into the mutation signature. `409` on stale `expectedVersion` or 5-device limit. Broadcasts `DeviceListChanged(DEVICE_ADDED)`. No verification code — the camera scan is the trust anchor. The iOS primary removes the device again if it can't store the provisioning payload; a device whose link never finishes (no `PUT /v1/keys`) still counts toward the 5-device limit and shows in `GET /v1/devices` until it is unlinked or reaped (see *Retention*). |
| `PUT /v1/devices/auth-key` | sig | `{publicKey}` — uncompressed P-256 point `0x04‖X‖Y` (65 bytes), ≤512 B → `204`. Stores the key `Relay-Sig` and nuke/device-list signatures verify against. The **first** upload for a device may use HTTP Basic (the only route that accepts it); once a key exists, the request must be Relay-Sig signed by the **current** key (so a leaked device password can't swap it). |
| `GET /v1/devices/{id}/auth-key` | sig | → `{authPublicKey}` (same account only). Lets clients verify a peer device's nuke/device-list signatures. |
| `PUT /v1/devices/apns` | sig | `{token}` → `204`. Registers an APNs token (iOS); sets push kind `apns`. Token must be 64–200 hex chars (`400` otherwise). |
| `PUT /v1/devices/fcm` | sig | `{token}` → `204`. Registers a Firebase Cloud Messaging token (Android); sets push kind `fcm`. The token must be 32–4096 characters of `A–Z a–z 0–9 _ : -` (`400` otherwise). Requires `-fcm-service-account` for the server to actually send. |
| `PUT /v1/devices/voip` | sig | `{token}` → `204`. PushKit VoIP token (iOS; no Android analogue). 64–200 hex chars. |
| `PUT /v1/devices/me/push-content` | sig | `{includeContent}` → `204`. `false` (default) = content-free wake (the device fetches the envelope from `GET /v1/queue`); `true` embeds the encrypted envelope in the push (`"e"`). Applies to both APNs and FCM. |
| `POST /v1/devices/me/mailbox/rotate` | sig | → `200 {mailboxId}`. Fresh opaque mailbox id, **only on explicit client request** — mailbox ids are otherwise stable (no scheduled rotation: the relay knows mailbox → device anyway). The offline queue is keyed by (account, device), not mailbox, so queued deliveries are unaffected. |

### Keys

| Method & path | Auth | Request → Response |
|---|---|---|
| `PUT /v1/keys` | sig | `{registrationId, identityKey, signedPreKey{keyId,publicKey,signature}, kyberPreKey{…}, oneTimePreKeys[{keyId,publicKey}], replaceOneTimePreKeys?}` → `204`. Identity/signed/Kyber **replace**; one-time keys **append** by default, or **replace** the device's whole pool when `replaceOneTimePreKeys:true` (deletes this device's existing one-time rows first, in the same transaction — used on fresh install/restore or desync heal so the relay never serves an orphaned key). ≤200 OTKs/upload, 100 uploads/account/hour. A device's stored one-time pool is capped at **2000** keys: an upload that would leave more is rejected whole with `409` (re-uploading existing key ids doesn't count twice; `replaceOneTimePreKeys` resets the pool). Kyber prekey is **required** (PQXDH). Optional `oneTimeKyberPreKeys[{keyId,publicKey,signature}]` (≤100/upload, pool ≤200/device) are served one per bundle fetch instead of the last-resort Kyber key while they last (same hand-out budgets as one-time prekeys); `replaceOneTimePreKeys` clears this pool too. |
| `GET /v1/keys/count` | sig | → `{count, kyberCount}`. Replenish below ~20 one-time and ~10 one-time Kyber prekeys. |
| `GET /v1/keys/{account}/sealed[?device=N]` | none (access key) | Header `Relay-Access-Key: <base64 32 bytes>` = the target's sealed-sender access key → same `{devices:[…]}` as below, **without** `accessKey`. Lets a client that knows a peer's access key fetch bundles anonymously, so the relay can't record who fetches whose keys. Clients learn the access key from the blinded directory (each bucket entry's `accessBox`: the key AES-GCM-sealed under the entry's token-derived key with AD `relay-access-key`, present once the account has published one; the directory is reindexed when it changes) — so even first contact by username, link or QR is anonymous — and keep it in their encrypted DB. Contacts also send their access key end-to-end in their profile update (`ProfileUpdate.access_key` in `content.proto`), which covers accounts that aren't discoverable. The signed fetch remains only for accounts the client has no access key for by either route. Wrong key, missing key and unknown account all → `403`. 300/IP/hour, 200 per (IP, target)/hour; one-time prekeys come out of the same per-target budget, with the source IP as the requester budget. |
| `GET /v1/keys/{account}[?device=N]` | sig | → `{devices:[{deviceId, mailboxId, registrationId, identityKey, signedPreKey, kyberPreKey, oneTimePreKey|null}], accessKey?}`. Consumes one OTK per device; `null` when exhausted (degraded PQXDH). 200/(requester,target)/hour; own-account fetches exempt. **OTK hand-out budgets** (cross-account): at most 60 OTKs per target device per hour (across all requesters) and 300 per requesting account per hour (across all targets). Past either budget the bundle is still returned, with `oneTimePreKey: null` (signed + last-resort Kyber prekey only), and the pool is untouched. |

### Messaging

| Method & path | Auth | Request → Response |
|---|---|---|
| `POST /v1/messages/sealed` | **none** | `{mailboxId, type, content (base64 sealed blob), accessKey (base64), ephemeral, silent}` → `200 {serverTimestamp}`. `silent` (receipts) queues without a push. Verifies `accessKey` matches the destination account (one mailbox+key query, constant-time compare) without learning the sender, delivers an envelope with **empty sender fields**. **No client clock on the wire**: the envelope's `client_timestamp` and `server_timestamp` are both the relay's receive time (timestamps that matter live in the encrypted content). `403` for *any* failure (unknown mailbox and wrong key are indistinguishable). 600/IP-bucket/min, 120/mailbox/min. `429` also when this source-IP bucket already holds 200 unacked envelopes in the destination device's queue, or that queue is full (500 envelopes / 50 MB). |
| `GET /v1/queue[?limit=N][&cursor=C]` | sig | → `{envelopes:[base64 serialized Envelope], more: bool, cursor?: string}`. **Paged**: at most `limit` envelopes (1–100, default 100) and at most 4 MiB of ciphertext per page (always ≥1 envelope when any remain). When `more` is true, pass the returned opaque `cursor` back to get the next page; `cursor` is omitted when `more` is false. Does **not** dequeue (ack independently). `400` bad limit/cursor. HTTP/3-capable QUIC fallback for receiving when the TCP WebSocket can't connect. |
| `POST /v1/messages/ack` | sig | `{envelopeId}` → `204`. REST equivalent of the WebSocket ack. |
| `POST /v1/calls/ring` | **none** | `{destinationMailbox, accessKey (base64), callId}` → `204`. Rings **all** devices of the account owning `destinationMailbox` (PushKit VoIP on iOS, high-priority FCM data on Android). Authorised exactly like a sealed send (same access-key check, identical `403` for unknown mailbox / wrong key); `callId` `^[A-Za-z0-9-]{1,64}$`. The push payload is only `{"call_id": "<id>"}` (FCM adds `"type":"call"` for routing) — **no caller account, name or call kind**; the callee learns who is calling only from the E2E-encrypted offer. 60/IP/min, 20/mailbox/min. |

### Session establishment, discovery, invites

| Method & path | Auth | Request → Response |
|---|---|---|
| `GET /v1/certificate/delivery` | sig | Mint a libsignal sealed-sender certificate (binds account id, device id, stored identity key, and the current **username in the `sender_e164` field** so recipients learn it from the sealed message itself; 7-day expiry) → `201 {certificate, expiresAt}`. `503` if sealed sender unconfigured, `409` if no keys. Requires `-sealed-sender-trust-key`; clients embed the trust-root public key (logged at startup). |
| `POST /v1/directory/oprf` | sig | `{blinded:[base64 ristretto255,…]}` (1–1024) → `{evaluated:[base64,…]}` (`k·B`). Blinded discovery step 1; the relay never learns the identifiers. Requires `-oprf-key`; `503` if unset. Metered **per element** (token bucket: 5000/account/day and 20000/IP/day, `429` when exhausted) plus 200 requests/account/hour. |
| `POST /v1/directory/buckets` | sig | `{buckets:[uint16,…]}` (1–1024) → `{buckets:[{bucket, entries:[{tag, box}]}]}`. Blinded discovery step 2 — **the final OPRF tokens never leave the client**. See below. 200/account/hour, 400/IP/hour. (Replaces `POST /v1/directory/resolve`, which received the tokens.) |
| `POST /v1/contact-invites` | sig | → `201 {token, expiresAt}` (7-day, single-use). Share as `https://relaymsg.app/c/<token>`. 50 invites per account per rolling day (`429`). |
| `POST /v1/contact-invites/claim` | **none** | `{token}` → `{accountId, username}`; `404` invalid/expired/used. The token is the capability (no credentials, so the relay can't record who redeemed it); the row is **deleted** on claim. 60 claims/IP/hour (shared with group-invite claims). Expired invites are purged by the hourly retention sweep. |
| `POST /v1/group-invites` | sig | `{blob}` (base64 opaque ciphertext, 1–65536 B) → `201 {token, expiresAt}`. 20/account/day. |
| `POST /v1/group-invites/claim` | **none** | `{token}` → `{blob}`. Multi-use until expiry; the token is the capability. 60 claims/IP/hour. Share as `https://relaymsg.app/g/<token>`. Expired blobs are purged by the hourly retention sweep. |

There is **no presence endpoint**: `GET /v1/presence/{account}` and all
last-seen tracking were removed (an online-status oracle for any account id).

**Bucketed discovery.** After step 1 the client holds a 32-byte token `t` per
identifier. It sends only `bucket(t)`; for each requested bucket the relay
returns every entry it holds, precomputed at index time:

```
bucket(t) = big-endian uint16 of SHA-256("relay-bucket" ‖ t)[0:2]
tag(t)    = HMAC-SHA256(key = t, "relay-tag")[0:8]
key(t)    = HKDF-SHA256(ikm = t, salt = none, info = "relay-entry", 32 bytes)
box       = nonce(12) ‖ AES-256-GCM(key(t), "accountId\nusername") ‖ gcm-tag(16)
```

The client recomputes `tag(t)`, opens the matching box, and gets the account id
and username. The relay learns at most which 16-bit buckets were requested
(each shared by many identifiers, registered or not) — not the identifiers, the
tokens, or whether anything matched. Interop vectors: `internal/oprf/directory_test.go`.

### Attachments & TURN

| Method & path | Auth | Request → Response |
|---|---|---|
| `POST /v1/attachments` | sig | → `201 {id}`. Reserves the id for a single anonymous `PUT`. `429` past the account's daily quota (1000 allocations or 2 GiB uploaded per rolling day by default). `507` when the relay's attachment storage is at its watermark (`-attachment-disk-cap`). |
| `PUT /v1/attachments/{id}` | **none** | raw `application/octet-stream` body → `204`; `413` over the cap; `429` when the allocating account's remaining daily byte budget is smaller than the upload (the declared `Content-Length`, or the 26 MiB request limit for a chunked body, is reserved up front and the unused part refunded afterwards, so parallel uploads can't overrun it; ids allocated before a relay restart share one account-sized budget); `507` at the storage watermark, counting in-flight uploads (the reservation is kept — retry later with the same id). Opaque ciphertext only. The 128-bit id is the capability: only an id **allocated** by `POST /v1/attachments` and **not yet written** is accepted (write-once; `404` otherwise). 600/IP/min. |
| `GET /v1/attachments/{id}` | **none** | → raw bytes, streamed from disk; supports `Range` (`206`); no `Last-Modified`. `404` after TTL reaping (14 days). No credentials — knowing the id (shared only inside E2E content) is the capability, so downloads can't be tied to an account. 600/IP/min. |
| `GET /v1/turn-credentials` | sig | → `{urls[], username, credential, ttl, iceServers[]}`. `iceServers` is the ordered list to use (`{urls[], username, credential}` each, preferred first); the top-level fields duplicate its first entry for older clients. Normally that's our coturn (REST HMAC-SHA1, 1 h; `username` is `<expiry>:<16 random hex>` — no account identifier). With TURN failover configured, when our coturn is down or overloaded the response carries **only** Cloudflare Realtime TURN credentials instead (see "TURN failover"). Clients should fetch per call, not cache. At most 60 requests per account per hour (`429` beyond). `404` when TURN isn't configured — treat as "no TURN", not an error. |

#### TURN failover

Flags: `-cloudflare-turn-key-id`, `-cloudflare-turn-token-file`, `-turn-status-url`.
relayd probes the first `turn:` URL in `-turn-urls` every 5 s with a STUN Binding
Request, and reads the TURN box's load agent (`cmd/turnload`, `GET /status` →
`{overloaded, reason, rxMbps, rxPps, cpu}`). Three failed probes in a row (no STUN
answer, or the agent reporting overload) switch new calls to Cloudflare; two good
ones switch back. A call that reports its relay failed (`?failed=1`) triggers an
immediate check (two probes, reused for 5 s) and fails over at once if both miss. The agent itself only clears overload after 60 s comfortably
below every threshold. The agent also keeps the month's transfer total
(`-monthly-limit-gb`, `-monthly-threshold`, `-monthly-count`, saved in its
StateDirectory) and reports overload from 90% of the host's allowance until the
month rolls over. Cloudflare is not contacted while coturn is healthy, and
the credential request to Cloudflare carries nothing about the user.

### History backup

Encrypted chat-history snapshots, as numbered opaque segments (see *History
backup storage* for where they're kept). `seq` is a canonical decimal in
1..2^53 (no sign, no leading zeros; else `400`). The client numbers segments
itself (generation × 1000 + index, manifest at index 0); the relay only stores
numbered blobs per account.

| Method & path | Auth | Request → Response |
|---|---|---|
| `GET /v1/history` | sig | → `200 {segments: [{seq, size}], usedBytes, maxBytes}`, sorted by `seq`. `maxBytes` is the per-account quota (64 MiB). |
| `PUT /v1/history/{seq}` | sig | raw `application/octet-stream` body, 1 byte to 2 MiB → `204`. Replaces an existing segment with that `seq`. `400` bad seq or empty body; `413` over 2 MiB (refused before authentication when `Content-Length` says so); `403` for demo accounts; `507` when the account would go over its quota (64 MiB total, the replaced segment's size not counted, and at most 512 segments) or when no storage is available. |
| `GET /v1/history/{seq}` | sig | → `200` raw bytes (`Cache-Control: no-store`), or `404`. `503` when the store holding it can't be reached (retry later). |
| `DELETE /v1/history/{seq}` | sig | → `204`, whether or not it existed. |
| `DELETE /v1/history` | sig | → `204`; removes all of the account's segments. |

Rate limits, per account per hour (`429` beyond): 600 `PUT`s, 600 `GET`s (list
and segment reads together) and 600 `DELETE`s. Deleting the account removes its
history; a demo reset does too. A sign-in that replaces the account's devices
**keeps** it: restoring onto the new device is its purpose.

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
frames, then sends `QueueEmpty`; everything after that is real-time. The
drain is paged (≤100 envelopes / 4 MiB per database read) and applies
backpressure, so no queued envelope (and never `QueueEmpty`) is dropped
because the client reads slowly. One live socket per device: a new
connection for the same device closes the previous one (close code 1008).
Removing a device closes its socket. Text frames and binary frames that don't
parse as a `ClientFrame` are dropped (logged at debug only); after 5 such
frames the server closes the connection (close code 1008).

**Send limits.** `SendRequest`s are limited per sender account (burst 1000,
then 1200/min) and, for fairness, one sender may hold at most 200 unacked
envelopes in any one destination device's queue (a device queue holds at most
500 envelopes / 50 MB). Over any of these the response is
`SEND_STATUS_RATE_LIMITED` — back off and retry; nothing was queued.

**Sending (`SendRequest`) is per-mailbox, one device per frame.**
`destination_account` is an **opaque mailbox id** (not an account id), and
`messages` must contain **exactly one** `DeviceMessage` for the device behind
that mailbox — the server rejects any other count with
`SEND_STATUS_MISMATCHED_DEVICES`. To reach every device of a recipient the
sender sends N separate frames, one per mailbox. On a cross-account send the
response lists the recipient's other devices that have published keys in
`missing_devices` (a device with no identity key yet, such as an unfinished
link, has no bundle to fetch and is left out)
(and `extra_devices`/`stale_devices` when the addressed device id or
`registration_id` is wrong) so the sender can fetch those bundles and send the
remaining frames; a stale `registration_id` yields `stale_devices`. Self-sends
(own-device sync) skip the missing-devices hint. Unknown mailbox →
`SEND_STATUS_UNKNOWN_ACCOUNT`.

Delivery is at-least-once: envelopes stay in the queue until the client
acks them (`AckRequest{envelope_id}`); clients must deduplicate by envelope
id. `ephemeral` envelopes (typing indicators) skip the queue entirely; `silent`
ones (receipts) are queued but never pushed, so they wait for the next connect. When a
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

**Coalesced.** At most one push per device every 3 s; a burst of messages
yields one immediate push plus one trailing push at the end of the window, so
the newest message always gets a wake.

**Dead tokens are cleared.** When APNs answers `410 Unregistered`, or
`BadDeviceToken` from **both** the sandbox and production environments (or
FCM answers `404`/`UNREGISTERED`), the stored token (APNs, VoIP or FCM) is
cleared; the device must re-register it.

**Opt-in ciphertext-in-push** (`PUT /v1/devices/me/push-content
{includeContent:true}`) embeds the base64 `Envelope` under key `"e"` for a
faster wake without a fetch — identical on both providers. Only **sealed**
envelopes (no `sender_account`/`sender_device`) are ever embedded, so the push
provider never learns who sent what; an envelope from the authenticated send
path gets a content-free wake instead and is fetched from the queue. FCM's data payload is
capped at ~4 KB, so an envelope that would exceed the budget silently degrades
to a content-free wake (the device fetches it from the queue instead); the
message stays end-to-end encrypted either way.

Flags:
- APNs: `-apns-key` (`.p8`), `-apns-key-id`, `-apns-team-id`, `-apns-topic`,
  `-apns-production`. The same key also sends PushKit VoIP on the `.voip` sub-topic.
  `-apns-production` only picks which environment is tried first: a token
  Apple rejects with `BadDeviceToken` is retried on the other environment and
  the working one is remembered per token, so Xcode (sandbox) and
  TestFlight/App Store (production) builds both receive pushes.
- FCM: `-fcm-service-account` (path to a Firebase service-account JSON key). The
  sender uses FCM HTTP v1 with a service-account-signed OAuth2 token.

## Sign in with Apple

Apple requires apps offering Sign in with Apple to revoke the user's tokens when
the account is deleted. The relay stores **no Apple or OAuth tokens** (social
login goes through Supabase; the only linkage persisted is
`accounts.supabase_user_id`, deleted with the account), so the client passes a
fresh authorization code with `DELETE /v1/accounts/me` and the relay exchanges
and revokes it (see that row). When relayd also runs with
`-supabase-service-key-file`, the Supabase auth user (and with it the stored
email) is deleted via the admin API, retried until it succeeds (see that row).

Flags (revocation is disabled unless `-siwa-key` is set; then it is required
that `-siwa-key-id` and a team id are available, or relayd exits at startup):
- `-siwa-key` — path to the Sign in with Apple `.p8` key (PKCS#8, P-256).
- `-siwa-key-id` — that key's id (JWT `kid`).
- `-siwa-team-id` — Apple team id (JWT `iss`); defaults to `-apns-team-id`.
- `-siwa-client-id` — the client id the codes were issued to (JWT `sub` and
  `client_id`); default `app.relaymsg`.

Each call uses a fresh ES256 client-secret JWT (5-minute lifetime).

## Known gaps

- Attachment blobs are not owner-tracked on disk, so account deletion cannot
  remove the account's uploads; they expire via the blob store's TTL GC (14 d).
  (The upload quota remembers the allocating account only in memory, as a
  salted hash, for at most 24 h.)
- Queue-fairness and push-coalescing bookkeeping is in memory only and starts
  empty after a restart.

## Demo accounts (App Review)

`accounts.is_demo` marks review/test accounts, set by an operator:
`UPDATE accounts SET is_demo = true, access_key = NULL WHERE username IN ('…', '…');`
(the API caches the flag for up to a minute). Demo accounts are an island:
directory lookups from a demo account only return demo accounts and nobody else
ever sees them; key fetches (`GET /v1/keys/{account}`) and WebSocket sends across
the line answer as if the account didn't exist (404 / `UNKNOWN_ACCOUNT`). The
unauthenticated sealed paths (sealed send, call ring, `GET /v1/keys/{account}/sealed`)
can't see who is asking and rely on the target's access key, which only those
same-side lookups hand out. So that a key learned before an account became a
demo account stops working, the account's access key is cleared when it is
marked demo (hence `access_key = NULL` above), on every review sign-in and on a
reset; the signed-in device uploads its own.
Username, account password, email change, password reset, email
discoverability and history segment uploads return `403 "This is a demo
account, so this is turned off."`.
`DELETE /v1/accounts/me` **resets** a demo account instead (devices, prekeys,
queues, chat list and history removed, sockets closed, `204`) and keeps the
account and its login.

Review sign-in: with `-demo-code-file` (a file holding a short code, e.g.
`REVIEW-XXXXXX`), `POST /v1/accounts/demo-signin {code}` (unauthenticated,
case-insensitive, 401 on a wrong code, per-IP limited) signs a new device in to
a demo account — the one with the fewest signed-in devices, so a second device
gets the other demo account — and answers like `/v1/accounts/recover`.
`GET /v1/accounts/me/demo` (sig) → `{demo, peers[]}` (peers = the other demo
accounts' usernames); the app uses it to hide what's switched off and to put the
other demo accounts in the chat list.

## Account storage (encrypted chat list)

`GET /v1/accounts/me/storage` (sig) → `{blob, version}` | `404`.
`PUT /v1/accounts/me/storage` (sig) `{blob, baseVersion}` → `{version}`; `409` if
`baseVersion` isn't current (another device wrote first — re-read, merge, retry);
≤512 KiB; 120 writes/account/hour. The blob is opaque to the relay: the client
stores its chat and group list (no messages) as `"RAS1" | AES-GCM(len | JSON |
zero padding to 4 KiB)` under a key from Argon2id(account password, salt =
SHA-256("relay-account-storage-v1|" + accountId)[0..16]), and restores it after
signing in with the account password. Deleted with the account; a demo reset
clears it.

## History backup storage

Each segment's blob is a file named by
`hex HMAC-SHA256(k, "relay-history-blob-v1\n" + accountId + "\n" + seq)`, so
neither file names nor the remote store reveal account ids. `k` is derived from
the OPRF key (`DeriveKey("history-blob-names")`), like the username-release key:
it needs no new secret to generate, back up or rotate, it never leaves the API
host (historyd can't compute names for a known account id), and it stays the
same across restarts. History backup therefore needs `-oprf-key`. **Changing the
OPRF key makes every stored segment unfindable**; the orphan sweep detects this
(rows exist but none of their blobs do) and refuses to delete anything.

The row (`history_segments`: account, seq, size, location, day-rounded
`created_at`) records where the blob went: `local` or `remote`. Reads and deletes
go to that location.

**Choosing a location** for each `PUT`:

1. **Local** (`-history-dir`, files written to a temp file, fsynced and renamed,
   mode `0600`) while the filesystem's free space (`statfs`) is at least
   `-history-min-free` and the write succeeds.
2. Otherwise **remote** (historyd, `-history-remote-url`), if configured and
   healthy.
3. Otherwise `507`.

Remote health comes from historyd's `GET /health` (`{freeBytes, usedBytes}`,
where `freeBytes` is what it will still accept), probed in the background every
30 s and right away after any failed remote request. It is healthy while the
probe answers `200` with room for at least one 2 MiB segment; it starts
unhealthy until the first probe. relayd logs once per change, at `warn`:
`history: new segments go to the remote store` (with why),
`history: new segments stored locally again`,
`history: no storage available; segment uploads get 507` (`error`), and
`history: remote store healthy` / `unhealthy`.

A replaced segment overwrites its blob in place when it lands in the same
location (the name depends only on account and seq) and deletes the old blob
when it moved. Blob deletes (single delete, delete all, account deletion, demo
reset, a replaced segment that moved) happen after the database change, best
effort; bulk ones run in the background. An hourly sweep lists the local
directory and historyd (`GET /v1/blobs`) and deletes blobs that no row refers to
and that are over an hour old (an upload writes its blob before its row), plus
temp files left by a crash.

Remote calls carry `Relay-History-Auth: <unix>.<hex HMAC-SHA256(secret, METHOD
"\n" PATH "\n" UNIX "\n" hex SHA-256(body))>`; historyd rejects bad MACs and
timestamps more than 5 minutes off. See [`cmd/historyd/README.md`](cmd/historyd/README.md).

## Passkeys

WebAuthn passkeys sign an existing account in on a fresh install, as an
alternative to social login, and can create an account with **no email at
all**; an account that has a passkey can also drop its email. Relying party ID `relaymsg.app` (origin
`https://relaymsg.app`; `-passkey-rp-id` / `-passkey-origins` override them for
local testing). Credentials must be discoverable (resident key) and every
ceremony requires user verification; attestation is `none`. **Binary fields on
these endpoints are base64url** (padding optional), unlike the rest of the API.

Each account gets a random 32-byte WebAuthn user handle
(`accounts.passkey_user_handle`) the first time it registers a passkey; it is
never the account id. `passkeys` stores each credential's public-key record
(`credential` JSONB: public key, sign count, flags), an optional name and a
**day-rounded** `created_at`. Ceremony state (challenge etc.) is held in memory
only, for 5 minutes, single use (≤10 000 pending per kind; beyond that `503`;
unauthenticated sign-in and sign-up ceremonies also ≤20 pending per source IP,
beyond that `429`). Expired ceremonies are pruned hourly.
Passkeys are deleted with the account. Demo accounts can't register passkeys.

**Passkey sign-up** creates the account from the ceremony alone: a fresh
random user handle, the username held with the pending ceremony, no email
token, no Supabase link and no account password, device 1 and the passkey row
in one transaction (`created_at`s day-rounded), then the blinded directory is
reindexed. Such an account signs in again with its passkey or a recovery key
(below); email recovery and the email registration lock don't apply.

**Removing the email** requires a fresh passkey assertion from one of the
account's own passkeys (non-discoverable: `allowCredentials` = its credentials,
UV required). On success the relay deletes the linked Supabase auth user (if
Supabase can't confirm it, the request fails with `502` and nothing changes; the
user retries), then in one transaction clears `email_token` and `supabase_user_id`,
turns `email_discoverable` off and deletes the account's email directory rows
(kind 1). The username entry stays.

| Method & path | Auth | Request → Response |
|---|---|---|
| `POST /v1/passkeys/register/options` | sig | → `200 {challenge, userId, userName, excludeCredentialIds[]}` (`userId` = the user handle, `userName` = the username, `excludeCredentialIds` = the account's existing credential ids). Starts a registration; one pending per account (a new call replaces it). `403 "not available for demo accounts"`, `409 "passkey limit reached"` at 10 passkeys. |
| `POST /v1/passkeys/register` | sig | `{credentialId, clientDataJSON, attestationObject, name?}` (`name` ≤64 chars) → `201 {id}`. Verified against the pending registration (challenge, origin, RP ID hash, UV flag), which it consumes. `400` on a malformed body, no/expired pending registration, or failed verification; `409` limit reached / credential already registered. |
| `GET /v1/passkeys` | sig | → `200 {passkeys: [{id, name, createdAt}]}` (`createdAt` ms, day-rounded). |
| `DELETE /v1/passkeys/{id}` | sig | `id` = base64url credential id → `204`; `404` if the account has no such passkey. |
| `POST /v1/passkeys/login/options` | none | → `200 {challenge, sessionId}`. Discoverable login (empty `allowCredentials`), UV required. 60/IP/hour; `429` with 20 ceremonies already pending from the address. |
| `POST /v1/passkeys/login` | none | `{sessionId, credentialId, clientDataJSON, authenticatorData, signature, userHandle, password}` (`password` = the new device's password, 8–1024) → `200 {accountId, deviceId, username, mailboxId, created:false}`, the same shape as `/v1/accounts/oauth`. The user handle resolves the account and the credential must be one of its passkeys; the stored sign count and flags are updated. **Like an OAuth sign-in it replaces all of the account's devices** (`DeviceListChanged(DEVICE_REMOVED)`, sockets closed) and provisions one new device, in one transaction. **A verified passkey satisfies the registration lock**: no `accountPassword` is needed. Every verification failure (unknown/expired session, unknown credential or handle, bad signature, missing UV, a sign count that went backwards) → `401 "passkey sign-in failed"`; failures don't count toward the shared per-IP failed-auth lockout (a passkey can't be guessed). `400` malformed body, `403` demo account, `409` device limit. 120/IP/hour. |
| `POST /v1/passkeys/signup/options` | none | `{username}` → `200 {sessionId, challenge, userId, userName}` (`userId` = a fresh random 32-byte user handle). `400` invalid username, `409 "username already taken"` (case-insensitive, incl. the reuse cooldown — same check as `POST /v1/accounts`). Discoverable credential, UV required, attestation `none`. The pending sign-up (challenge, handle, username) is held under `sessionId`. 60/IP/hour; `429` with 20 sign-ups already pending from the address. |
| `POST /v1/passkeys/signup` | none | `{sessionId, credentialId, clientDataJSON, attestationObject, password, name?}` (`password` = device 1's password, 8–1024; `name` ≤64 chars) → `201 {accountId, deviceId, username, mailboxId, created:true}`. Verified like `/v1/passkeys/register` (challenge, origin, RP ID hash, UV, credential id matches), consuming the session; unknown/expired session or failed verification → `401 "passkey sign-up failed"`. `400` malformed body; `409 "username already taken"` if the name went meanwhile; `409 "passkey already registered"`. Counts toward the per-IP account creation limit (20/hour). |
| `POST /v1/accounts/me/email/remove/options` | sig | → `200 {challenge, credentialIds[]}` (the account's passkey ids, to pass as `allowCredentials`). One pending per account (a new call replaces it). `409 "add a passkey first"` if the account has none; `403` demo account. |
| `POST /v1/accounts/me/email/remove` | sig | `{credentialId, clientDataJSON, authenticatorData, signature, userHandle}` → `204`. Verified against the pending assertion (consumed) and the account's own passkeys; the stored sign count and flags are updated. Every verification failure (no/expired session, a credential not on the account, bad signature, missing UV, a sign count that went backwards) → `401 "passkey check failed"`. `400` malformed body; `403` demo account. Then removes the email as described above. |

## Recovery key

A recovery key is a random key the **client** generates and shows the user
once. The relay stores only its hash, `accounts.recovery_key_hash` (BYTEA,
unique where set), and the key signs the account in on a fresh install like a
passkey. One per account; setting a new one replaces the old.

Normalisation and hash, identical on client and relay: upper-case ASCII
`a`–`z`, then drop every character that isn't `A`–`Z` or `0`–`9` (non-ASCII
letters are dropped, not case-folded). Hash = SHA-256 of the UTF-8 bytes of
`"relay-recovery-key-v1|" + normalized`, sent **base64url**. Test vector:
`"abcd-efgh ijkl"` → `ABCDEFGHIJKL` →
`24afe96099424bd806835c7b825f3068652949720dcbc4dfec07a6a3d3d82576`.

| Method & path | Auth | Request → Response |
|---|---|---|
| `PUT /v1/accounts/me/recovery-key` | sig | `{hash}` (base64url, exactly 32 bytes) → `204`. Sets or replaces the account's recovery key. `400` not 32 bytes; `409` the hash is already in use (regenerate); `403` demo account. |
| `DELETE /v1/accounts/me/recovery-key` | sig | → `204`. Removes it (idempotent). |
| `POST /v1/accounts/recovery-key/signin` | none | `{authKey, password}` → `200 {accountId, deviceId, username, mailboxId, created:false}`. `authKey` is the client's derivation of the key (base64url of HKDF-SHA256(normalised key, info `relay-recovery-key-auth-v2`)); the relay looks up SHA-256(`relay-recovery-key-v2\|` + authKey), which is what current clients register. The key itself, which also unlocks the chat-list blob, never leaves the device. Older clients send `{key}` (the raw key, ≤128 chars), matched against SHA-256(`relay-recovery-key-v1\|` + normalised key). No match → `401 "recovery key sign-in failed"`. **Replaces all of the account's devices** like a passkey sign-in (`DEVICE_REMOVED`, sockets closed) and provisions one new device in one transaction; **a recovery key satisfies the registration lock** (no `accountPassword`). `400` malformed body, `403` demo account, `409` device limit. 60/IP/hour, charged up front for every attempt whatever its outcome (so no answer is a free probe); not tied to the shared per-IP failed-auth lockout, since ~118 random bits can't be guessed. |

The key is deleted with the account row. The lookup is a unique-index match on
the hash; with ≥20 random characters there is nothing practical to enumerate.

## Proxy (`cmd/relayproxy`)

For people in places that block Relay. Anyone can run `relayproxy` on a VPS with
a domain name; users enter the domain in **Settings → Privacy → Proxy** (or
"Can't connect? Use a proxy" on the welcome screen), or open a shared link
`https://relaymsg.app/proxy#<host[:port]>`. The address lives only in the
fragment, so relaymsg.app never sees it.

How it works: the app opens TLS to the proxy (an ordinary HTTPS connection to the
proxy's own domain) and sends `CONNECT api.relaymsg.app:443` inside it (HTTP/1.1
or HTTP/2). The proxy splices that to the relay and the app speaks TLS to the
relay end to end, so the proxy sees only encrypted bytes. While a proxy is on the
app never falls back to a direct connection (`allowFailover = false`); the
notification extension uses it too. Calls (WebRTC/TURN) are not proxied.

Many people can share a proxy's IP address, as they do a carrier's or an
office's. So nothing one of them does can lock the others out: a request with a
valid `Relay-Sig` signature is never refused because of other failures from the
same address (only a flood of 1000 bad signatures in 10 minutes cuts an address
off), passkey and recovery-key sign-ins don't count toward the per-address
lockout (neither can be guessed), and the per-address failure lockout guards
only the HTTP Basic bootstrap.

The proxy reaches only the hosts in `-allow` (default: the relay API and the
Supabase project used for sign-in), so it can't be used as an open proxy. Any
non-CONNECT request gets a plain 404. Client addresses are never logged.

```
go build -o relayproxy ./cmd/relayproxy
# Let's Encrypt on port 443 only (TLS-ALPN-01); point the domain's A record at the VPS first.
sudo ./relayproxy -domain proxy.example.com
# or with your own certificate:
sudo ./relayproxy -cert fullchain.pem -key privkey.pem
```

| Flag | Default | |
|---|---|---|
| `-addr` | `:443` | listen address |
| `-domain` | | get a certificate for this name automatically |
| `-cache-dir` | `/var/lib/relayproxy/certs` | certificate cache for `-domain` |
| `-cert`, `-key` | | TLS certificate and key instead of `-domain` |
| `-allow` | relay API + Supabase, port 443 | comma-separated `host:port` targets |
| `-max-conns` | 4000 | concurrent tunnels before new ones get 503 |

## Optional phone numbers (Twilio Verify)

Phone numbers are optional and used only so people who have the number can
find the account; they never sign anyone in and are never shown. Codes are
texted by a Twilio Verify service; the relay keeps only the number's OPRF
token. Off unless all three Twilio flags are set (then `GET .../phone`
reports `available: true`).

Flags: `-twilio-account-sid`, `-twilio-auth-token-file` (file holding the auth
token, root-only), `-twilio-verify-service-sid`, `-phone-allowed-prefixes`
(default `+61`), `-phone-daily-cap` (default 30 texts a day across everyone).

Limits before anything is texted: Relay-Sig auth, E.164 format, the country
allow-list, 3 sends a day per account and per number, 5 per source address and
the daily cap. On the Twilio side, enable **Fraud Guard** on the Verify service,
limit **SMS geo permissions** to the same countries, and set a usage alert or
spending limit on the account.
