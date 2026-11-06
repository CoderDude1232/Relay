# Encrypted tunnel

Cloudflare terminates TLS in front of relayd, so without this it can read
everything the relay can: the `Authorization` header (account and device id) on
every signed request, paths with account ids in them, and the WebSocket frames,
including the mailbox each sealed message is addressed to. With the IP address
it also sees, that is enough to work out who talks to whom.

The tunnel wraps every request in encryption to a key only relayd holds. What
Cloudflare (and a fallback Worker or proxy) can still see: the client's IP
address, the time, that it is Relay, and padded sizes. Not which endpoint, which
account, or which mailbox.

## Requests: `POST /v1/t`

An [Oblivious HTTP](https://www.rfc-editor.org/rfc/rfc9458) request
(`message/ohttp-req`) holding a known-length
[Binary HTTP](https://www.rfc-editor.org/rfc/rfc9292) request, padded with
zeros. Ciphersuite:

| | id | |
|---|---|---|
| KEM | `0x647a` | X-Wing (ML-KEM-768 + X25519), post-quantum hybrid |
| KDF | `0x0001` | HKDF-SHA256 |
| AEAD | `0x0002` | AES-256-GCM |

Message: `key_id (1) ‖ kem_id (2) ‖ kdf_id (2) ‖ aead_id (2) ‖ enc (1120) ‖ ct`,
HPKE `info = "message/bhttp request" ‖ 0x00 ‖ header`. The response is always
`200 message/ohttp-res`: `response_nonce (32) ‖ AEAD(key, nonce, padded BHTTP
response)` with the key and nonce derived as in RFC 9458 §4.4 (export
`"message/bhttp response"`, salt `enc ‖ response_nonce`). The inner status
(401, 429, …) is only inside. A plain `400` means the message didn't decrypt.

relayd rebuilds the inner request and runs it through the same handlers as a
direct one, with the outer request's source address for rate limits. Only these
inner headers are kept: `Authorization`, `Content-Type`, `Relay-Access-Key`,
`X-Relay-Timestamp`, `X-Relay-Nonce`, `X-Relay-Content-SHA256`. Responses carry
`Content-Type` and `Retry-After`. Inner paths must start with `/v1/` and can't be
`/v1/t…`. Signatures, nonces and replay protection are unchanged: the inner
request is signed exactly as a direct one would be.

**Padding.** Every plaintext (request, response, WebSocket frame) is padded to
the next of 256 B, 512 B, … 64 KiB, then to a multiple of 64 KiB.

**Size.** Bodies up to 8 MiB go through the tunnel. A larger upload goes direct,
and a response over 8 MiB comes back as an inner `413` with
`x-relay-tunnel: too-large`, after which the app fetches it directly. Only large
attachments (photos and files over 8 MiB) hit this.

## WebSocket: `GET /v1/t/ws`

An unauthenticated upgrade. The client's first message is a tunnel request (as
above) for a signed `GET /v1/ws`. The server answers with the tunnel response:
`200` to go ahead, or the authentication error, then closes. After `200`, every
binary frame is
`AES-256-GCM(key, nonce = 0⁴ ‖ counter⁸ (big-endian), plaintext = len⁴ ‖ frame ‖ zero padding)`,
with `key` exported from the opening HPKE context: `"relay tunnel ws c2s"`
(client to server) and `"relay tunnel ws s2c"`, 32 bytes each. Counters start at
zero per direction. A frame that doesn't open ends the connection, so frames
can't be dropped, reordered or replayed. Pings, pongs and close frames carry no
data and aren't encrypted.

## Keys

`relayd -tunnel-key /opt/relay/tunnel.key` (created on first run, `0600`). The
app builds in the public half (`RelayTunnel.publicKey`, key id 1), so the file
must never be replaced or lost: back it up with the other relay keys.
`relayd -tunnel-key … -tunnel-public-key` prints the public half and
`GET /v1/t/key` serves it, for checking only. The app never fetches it, since
Cloudflare could substitute its own.

Rotating it means shipping an app with the new public key under key id 2,
running both on the server until old builds are gone, then retiring id 1.
relayd currently holds one key.

## What it doesn't hide

- The IP address, timing and padded sizes of each request. Someone watching
  both ends could still try to correlate by timing.
- From relayd: everything it saw before. The tunnel hides things from the
  network in front of the relay, not from the relay.
- Requests that never go to the relay: Google's sign-in page, APNs, TURN media
  (already end-to-end encrypted), link previews, the witness and fallback Gist
  fetches.
- Replays by Cloudflare of a whole unauthenticated tunnel request (for example
  a sealed send) are possible, as they were before. Authenticated requests are
  protected by their signature nonce.

Older app versions keep using the direct routes until `relayd -tunnel-only`
turns them off. Then every direct request gets `426` ("update the app") except
the ones that have to stay direct: attachment uploads and downloads (bodies
over 8 MiB), `GET /v1/ping`, `/v1/speedtest`, the public key-transparency
routes and `/v1/supporter/keys`.

Code: `server/internal/tunnel` and `server/internal/api/tunnel.go`;
`RelayKit/Sources/RelayKit/RelayTunnel.swift`, `RelayAPIClient.fetch` and
`RelayWebSocket`.
