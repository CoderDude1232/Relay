# Relay Privacy Stages

Stage 1 is the logging and transport-baseline hardening pass. It preserves the
existing encrypted messaging/session system and does not implement phone-number
or contact-discovery changes.

## Implemented

- App logs redact common credential, token, key, nonce, UUID, long hex, and long
  base64-looking values before errors reach OSLog.
- Server logs redact common credential, token, key, nonce, UUID, long hex, and
  long base64-looking values before errors reach slog.
- Server websocket, APNs, VoIP, queue, and delivery logs no longer include
  account IDs, device IDs, envelope IDs, routing identifiers, request bodies, or
  tokens.
- Server API handlers strip visitor IP forwarding headers before requests reach
  route handlers:
  - `CF-Connecting-IP`
  - `CF-Connecting-IPv6`
  - `True-Client-IP`
  - `X-Forwarded-For`
  - `X-Real-IP`
  - `Forwarded`
- Non-attachment request bodies are capped at 1 MiB. Attachment uploads keep a
  separate 26 MiB cap to preserve existing media behavior.
- The app Privacy settings page documents Relay's encryption, Cloudflare/network
  metadata visibility, and best-effort deletion limits.

## VPS And Cloudflare Verification

Run these before considering Stage 1 deployed:

- Confirm the origin service is not directly reachable except through the chosen
  Cloudflare path.
- Prefer Cloudflare Tunnel for the API origin. If not using Tunnel, firewall the
  origin to authenticated Cloudflare traffic.
- Audit DNS records for origin leakage, including old A/AAAA records,
  subdomains, staging hosts, and admin panels.
- Confirm daemon logs do not contain request bodies, credentials, APNs tokens,
  account IDs, device IDs, routing identifiers, mailbox identifiers, or precise
  message metadata.
- Confirm Cloudflare request logs are understood as trusted-intermediary
  metadata, not hidden from Cloudflare.
- Prototype WebTransport end-to-end through client, Cloudflare, and origin
  before replacing production WebSocket transport.
- Do not enable 0-RTT for messages, authentication, device changes, token
  spending, or destructive commands.

## Later To-Do

- All phone-number and address-book contact-discovery work.
- OPRF/private-set-intersection discovery.
- Reverse-SMS verification.
- Privacy Pass abuse-prevention tokens.
- Signed device-list and recovery-secret changes.
- Full remote nuke command signing/revocation pipeline.
- TURN-only private calling mode and dynamic TURN REST credentials.

## Stage 2 Implemented

- Durable encrypted content is padded before Signal/sender-key encryption.
- Padding uses fixed plaintext-size buckets of 256, 512, 1,024, and 4,096 bytes.
- Ephemeral signalling, such as typing and call ICE, is not padded to avoid
  adding latency to non-durable traffic.
- The relay server still treats message contents as opaque ciphertext.
- Offline queue retention is capped:
  - queued envelopes expire after 30 days;
  - each serialized queued envelope is limited to 512 KiB;
  - each device mailbox is limited to 500 queued envelopes.
- Every server-side device row now has a random 128-bit opaque mailbox ID.
- Existing devices are backfilled with mailbox IDs during server startup.
- Device list, account creation, linked-device creation, and prekey-bundle
  responses expose mailbox IDs for new clients while preserving old account and
  device ID compatibility.
- The iOS client stores peer mailbox IDs in its encrypted device cache after
  prekey refresh.
- WebSocket sends now route to opaque mailbox IDs instead of destination account
  IDs. The legacy protobuf field name remains until generated schemas are
  refreshed, but new clients place a mailbox ID in that field.
- The iOS client sends one encrypted device payload per mailbox-addressed frame.
- Delivery/read receipts are sent as ephemeral live control messages, so they
  are not queued and do not trigger normal offline "New message" APNs alerts.

## Stage 2 Compatibility To-Do

- Rotate volatile connection tokens after reconnect once mailbox IDs exist.
- Stop returning account/device routing identifiers to new clients after the
  migration window.
- Restore atomic all-device fan-out using a signed/versioned device list so a
  stale sender cannot silently miss newly linked recipient devices.

## Stage 3A Implemented

- Each iOS device now creates a per-device authorization signing key in the
  Secure Enclave where available.
- Simulator and unsupported environments fall back to a Keychain-held
  non-exported private key so local testing still works.
- The app uploads only the public half of that authorization key to the relay
  whenever an account becomes ready.
- The relay stores the authorization public key on the authenticated device row
  using an additive `auth_public_key` database migration.
- PQXDH identity keys, prekeys, and ratchet/session state remain inside the
  existing Relay encryption system.

## Stage 3 To-Do

- Notify existing devices when another device is added or removed.
- Add a separate high-entropy recovery secret that can regain account control
  and revoke lost devices without exposing historical messages.

## Stage 3B Implemented

- Accounts now carry a monotonic `device_list_version`.
- Adding or removing linked devices now requires a signature from the
  authenticated device's Stage 3A authorization key.
- Device mutation signatures bind the account ID, expected device-list version,
  action, target device ID and linked-device password where applicable.
- The server rejects unsigned mutations, mutations signed by a different device,
  missing authorization keys, invalid signatures and stale device-list versions.
- The client refreshes the current device-list version, publishes its
  authorization public key, signs the mutation locally, and then calls the
  add/remove endpoint.

## Stage 3B Limitations

- The server enforces signed mutations, but it does not yet publish or require a
  separately signed full device-list document.

## Stage 3C Implemented

- QR device linking now uses a short-lived, single-use link token instead of
  embedding reusable account credentials in the QR payload.
- Link invitations must be created by an authenticated device using the signed
  Stage 3B device-list mutation flow.
- The QR payload carries the link token, server URL, expiry time and a
  human-readable verification code.
- The server creates the new device only when the linking device successfully
  claims the token and matching verification code.
- Expired or already-used link tokens cannot be claimed.

## Stage 3C Limitations

- The claim response necessarily returns the new device's account credentials
  once over HTTPS so the device can finish bootstrapping.
- The verification code is displayed on the authorising device and submitted by
  the scanning device, but the UI does not yet require both users to manually
  compare the code before claim.

## Stage 3D Implemented

- Contact identity-key replacements are detected while refreshing peer prekey
  bundles, before new message ciphertext is produced.
- The app records the first trusted identity locally, then treats a later
  replacement key as unacknowledged until the user verifies/trusts the new
  safety number.
- Normal 1:1 messages and sender-key group fanout are blocked when a peer has
  an unacknowledged replacement identity. Receipts and live call-control
  signals remain ephemeral best-effort traffic.
- A blocked send marks the local outgoing message failed and opens the existing
  safety-number verification sheet for the affected peer.

## Stage 3D Limitations

- Group sends fail closed if any member's identity replacement is unacknowledged.
  The group thread shows a banner naming the member (or how many members)
  whose safety number changed, and opens a list to verify each one
  (`GroupSafetyNumbersView`).
