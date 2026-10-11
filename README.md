# Relay

Relay is an end-to-end encrypted messenger for iPhone. Messages, calls, photos,
voice notes and group chats are encrypted with the Signal Protocol and a
post-quantum key exchange, and our servers delete each message as soon as it's
delivered.

**Website:** [relaymsg.app](https://relaymsg.app) ·
**How it works:** [relaymsg.app/security](https://relaymsg.app/security) ·
**Privacy policy:** [relaymsg.app/privacy](https://relaymsg.app/privacy)

This repository contains the wire protocol, the relay server and the iOS app.
They're versioned together so the protocol and the code that speaks it never
drift apart.

## What's here

| Path | Contents |
|---|---|
| [`proto/`](proto) | The wire protocol: `relay.proto` (what the server sees) and `content.proto` (what's inside the encryption). The server and every client generate code from these. |
| [`server/`](server) | The relay (`relayd`) in Go, plus `relayproxy` and `turnload`. The full API is documented in [`server/README.md`](server/README.md). |
| `Relay/` and the other folders at the root | The iOS app, its extensions, the Apple Watch app, and four Swift packages: `CryptoCore` (libsignal), `SecureStorage` (SQLCipher and the Keychain), `RelayKit` (networking) and `RelayCore` (message processing). |
| [`docs/`](docs) | [Architecture](docs/ARCHITECTURE.md), the [device test checklist](docs/TESTING.md) and other notes. |

The Android client is in development in a separate repository.

## Building

### iOS

You need Xcode 27 or later; the app runs on iOS 26 and watchOS 26.

```sh
scripts/setup-libsignal.sh
open Relay.xcodeproj
```

The script checks out [libsignal](https://github.com/signalapp/libsignal) into
`third_party/` and downloads its prebuilt library, verifying the checksum.
Package tests run on a simulator, for example:

```sh
cd SecureStorage && xcodebuild test -scheme SecureStorage -destination "platform=iOS Simulator,name=iPhone 17"
```

### Server

You need Go 1.26.9 or later and PostgreSQL.

```sh
cd server
go test ./...
go run ./cmd/relayd -addr :8080 -dsn 'postgres:///relay?host=/var/run/postgresql'
```

Tests that need a database run when `RELAY_TEST_DSN` is set and are skipped
otherwise. See [`server/README.md`](server/README.md) for every flag.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please report security issues privately,
as described in [SECURITY.md](SECURITY.md).

## License

Copyright © 2026 the Relay authors.

Relay is free software, licensed under the
[GNU Affero General Public License v3.0](LICENSE). It's built on
[libsignal](https://github.com/signalapp/libsignal), which is also AGPL-3.0.
Other components keep their own licenses; they're listed in the app under
Profile → Privacy → Acknowledgements, and at
[relaymsg.app/source](https://relaymsg.app/source).
