# Relay — monorepo

Relay is an end-to-end-encrypted messenger. We own **every layer**: the protobuf
wire schema, the Go relay server, and the clients. This repository is a
**monorepo** so the protocol contract and every client stay version-locked
together — there is no external spec, the source of truth is this repo.

## Layout

| Path | What it is |
|---|---|
| `proto/` | **Source of truth for the wire protocol.** `relay.proto` (server-visible envelopes + WS frames) and `content.proto` (client-only plaintext, encrypted before it hits the wire). Every client and the server codegen from here. |
| `server/` | The Go relay (`relayd`). Store-and-forward, prekeys, sealed sender, blinded discovery, groups, push. API contract in `server/README.md`. |
| `android/` | **Android client** (Kotlin / Jetpack Compose), in progress. Must interoperate byte-for-byte with the contract in `proto/` + `server/`. |
| iOS (repo root) | The iOS app + Swift packages, kept at the root because the Xcode project's file-system-synchronized group is rooted here. See below. |

### iOS layout (at the repo root)

The iOS client is **not** under an `ios/` folder — its Xcode project
(`Relay.xcodeproj`) and file-system-synchronized group are rooted at the repo
top level, and moving them would break the project. Its pieces:

- `Relay/` — the app target's source root (synced group).
- `NotificationServiceExtension/`, `RelayShareExtension/`, `RelayWidgetExtension/`,
  `RelayNotificationContent/`, `RelayIntents/`, `RelayBroadcastUpload*/` — app extensions.
- `CryptoCore/`, `SecureStorage/`, `RelayKit/`, `RelayCore/` — local Swift packages.
- `third_party/` — git-ignored; vendored libsignal, recreated by `scripts/setup-libsignal.sh`.

## Cross-cutting

- **Protocol is authoritative.** Any client change that affects the wire must be
  reflected in `proto/` and `server/README.md`, and both clients must match.
- **Shared design decisions** (crypto choices, delivery semantics, auth, calls)
  are in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
- **Ongoing work:** `TODO.md`, on-device verification checklist: `TESTING.md`.

## License

Relay is free software, licensed under the **GNU Affero General Public License
v3.0** (see [`LICENSE`](LICENSE)). It's built on
[libsignal](https://github.com/signalapp/libsignal), which is AGPL-3.0 too;
other components keep their own licences (listed in the app under Profile →
Privacy → Acknowledgements, and at https://relaymsg.app/source).

Security issues: please email security@relaymsg.app rather than opening a
public issue.
