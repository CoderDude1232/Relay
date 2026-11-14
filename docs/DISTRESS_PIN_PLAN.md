# Relay PIN lock and Distress PIN — plan

Status: agreed with Ethan 2026-11-14. Stage 1 (server) code written 2026-11-15
(`internal/pinguard`, `store/pin_guard.go`, `api/pin_guard.go`, README "PIN guard"). Build in stages and check in
after each one; Stage 1 (server) and Stage 2 (crypto) need his review before
anything is wired into the app. The server deploy happens with him present.

## Goal

Expand Panic Mode into something like GrapheneOS's duress PIN. Hiding chats
behind the existing Panic Mode PIN stays as it is.

## Decisions (Ethan's answers)

- **Both lock modes, as a choice** in Settings → Panic Mode, "Lock Relay with a PIN":
  - **Off**
  - **Ask after every phone lock**: when the iPhone locks, Relay's PIN screen
    covers the app. Data stays decryptable on the device; the PIN only gates the
    app. Verified on device (Argon2id + the existing exponential backoff).
  - **Forget messages on lock**: when the iPhone locks, Relay closes the
    SQLCipher database and erases its key, plus every plaintext copy outside it.
    The PIN is the only way back ("forget the PIN" = data gone).
- **Brute force: the relay limits guesses.** A 4–6 digit PIN alone is
  brute-forceable (10^6 Argon2 guesses ≈ days on device; 10^4 ≈ hours), so the
  key needs a share only the relay can release, under a hard guess limit.
- **Distress PIN: wipe all devices and look fresh.** Erases Relay on this
  phone, sends the existing identity-signed emergency wipe (nuke) to every
  linked device, tells the relay to destroy its key share, then shows the normal
  sign-up screen as if Relay was never used.

## Design

### Key wrapping ("Forget messages on lock")

- DB master key (32 bytes) is wrapped under a KEK derived from two halves:
  1. **Device half**: Secure Enclave key (existing ECIES wrap pattern in
     `KeychainSecureStore`), so the blob is useless off this iPhone.
  2. **Relay half**: OPRF output. Client blinds H(PIN, salt) on ristretto255,
     relay returns k_d·B with a per-device secret scalar k_d; client unblinds.
     The relay never sees the PIN. Reuse the existing `server/internal/oprf` /
     `voprf` code style and domain-separated tags (new tags, e.g.
     "Relay-PINGuard-v1-…").
- KEK = HKDF(OPRF output ‖ device secret). Store only the wrapped DB key; on
  lock, delete the unwrapped/plain key items and drop it from memory.
- The relay keeps an **attempt counter per device, limit 10**. It increments
  before answering an evaluate; a correct PIN resets it via a verifier tag the
  client derived at enrolment from the OPRF output **and the device-only
  secret** (tag = HKDF(OPRF output ‖ device secret, "verify")). Without the
  device secret, a relay DB leak (k_d + tag) would let anyone test all 10^6
  PINs offline and learn the PIN. At 10 wrong attempts the relay deletes k_d
  permanently → data unrecoverable.
- Threat summary: needs this iPhone (Secure Enclave) **and** the relay's guess
  limit. A storage dump can't be attacked elsewhere; a relay compromise alone
  can't decrypt anything.

### Distress PIN

- Verified **on device first** (its own Argon2id hash), before any relay call,
  so it works offline and leaks nothing to the relay about which PIN was used.
- On match: relay DELETE of k_d, emergency wipe to all linked devices, local
  wipe (`AppModel.signOut` path + `wipeLocalFiles`, Panic Mode `wipe()`), land
  on the sign-up screen. Offline: wipe locally now, queue the relay calls.
- Both PINs must differ; refuse a distress PIN equal to the Relay PIN.

### What must be cleared on lock (strong mode)

- In-memory `MessagingService` / open DB (tear down and rebuild after PIN).
- `SiriPreviewCache` / `RecentChatsStore` snapshot (Siri UI + notification
  content extension), Watch snapshot (`WatchBridge`), widget data, share
  extension caches (`ShareBridge`), anything in the App Group holding message
  text. Attachment blobs are already ciphertext (key in the DB).

### Known costs to tell users (strong mode)

- Notifications show only "New message" (NSE can't decrypt without the DB).
- Incoming calls can't ring through CallKit until Relay is unlocked.
- Unlocking needs internet (relay share). Messages wait on the relay queue
  (at-least-once delivery) until unlocked.

## Stages

1. **Server**: PIN-guard endpoints (enrol / evaluate / reset counter / delete),
   store table + migration, tests (store tests on a throwaway DB per the
   `relay-vps-deploy` memory), `server/README.md` API docs. Deploy with Ethan.
2. **Client crypto**: OPRF client + KEK derivation + SE-wrapped DB key, unit
   tests in the Swift packages (xcodebuild against a simulator).
3. **App**: lock-on-device-lock lifecycle (protected-data notifications), PIN
   screen, Settings UI in Panic Mode, distress wipe, clearing plaintext caches.
4. **Device testing** on Ethan's iPhone and iPad.

Ethan's laptop can't run agents with the lid closed (local session), so work
happens while he's at the machine.
