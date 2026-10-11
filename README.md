# Relay

Relay is an end-to-end-encrypted messenger. This repository holds the wire
protocol, the Go relay server, and the iOS app; they're versioned together so
the protocol and the code that speaks it never drift apart.

Related repositories:

- [Relay-Android](https://github.com/CoderDude1232/Relay-Android) — the Android
  client (in development). It copies `proto/` and must match it byte for byte.

## Layout

| Path | What it is |
|---|---|
| `proto/` | **Source of truth for the wire protocol.** `relay.proto` (server-visible envelopes + WS frames) and `content.proto` (client-only plaintext, encrypted before it hits the wire). The server and every client generate code from it. |
| `server/` | The Go relay (`relayd`), plus `relayproxy` and `turnload`. Store-and-forward, prekeys, sealed sender, blinded discovery, push, TURN failover. API contract in `server/README.md`. |
| iOS (repo root) | The iOS app, its extensions and Swift packages, kept at the root because the Xcode project's file-system-synchronized group is rooted here. See below. |
| `docs/` | Architecture notes, the device test checklist, App Review and TestFlight notes, open work, and the sign-in email templates. |
| `scripts/` | `setup-libsignal.sh`, which recreates `third_party/`. |

### iOS layout (at the repo root)

The iOS client is **not** under an `ios/` folder — its Xcode project
(`Relay.xcodeproj`) and file-system-synchronized group are rooted at the repo
top level, and moving them would break the project. Its pieces:

- `Relay/` — the app target's source root (synced group).
- `NotificationServiceExtension/`, `RelayShareExtension/`, `RelayWidgetExtension/`,
  `RelayNotificationContent/`, `RelaySiriUI/`, `RelayIntents/`, `RelayBroadcastUpload/`
  — app extensions; `RelayWatch Watch App/` — the Apple Watch app.
- `CryptoCore/`, `SecureStorage/`, `RelayKit/`, `RelayCore/` — local Swift packages.
- `third_party/` — git-ignored; vendored libsignal, recreated by `scripts/setup-libsignal.sh`.

## Cross-cutting

- **Protocol is authoritative.** Any client change that affects the wire must be
  reflected in `proto/` and `server/README.md`, and every client must match.
- **Shared design decisions** (crypto choices, delivery semantics, auth, calls)
  are in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
- **Ongoing work:** [`docs/TODO.md`](docs/TODO.md); on-device verification
  checklist: [`docs/TESTING.md`](docs/TESTING.md).

## License

Relay is free software, licensed under the **GNU Affero General Public License
v3.0** (see [`LICENSE`](LICENSE)). It's built on
[libsignal](https://github.com/signalapp/libsignal), which is AGPL-3.0 too;
other components keep their own licences (listed in the app under Profile →
Privacy → Acknowledgements, and at https://relaymsg.app/source).

Security issues: please email security@relaymsg.app rather than opening a
public issue.
