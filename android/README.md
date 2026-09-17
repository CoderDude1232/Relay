# Relay — Android client

The Android client for Relay (Kotlin / Jetpack Compose). Part of the Relay
monorepo; see the repo-root `README.md` for the overall layout.

**Status:** not started. The project brief, interop contract, platform mappings,
and staged build plan live in [`CLAUDE.md`](CLAUDE.md).

**How to work on it:** open a Claude Code session rooted at this `android/`
directory (separate from the iOS/server session). The agent reads `CLAUDE.md`
automatically. First deliverable is `PROTOCOL.md` (the exact contract to match),
for owner review before Stage 1.

**Build tooling:** Android Studio + JDK 17 + Android SDK + emulator.

**Interop:** every stage must round-trip a message with the iOS client against the
live relay (`https://api.relaymsg.app`). The wire protocol is defined in
`../proto/` and `../server/README.md` — those are authoritative.
