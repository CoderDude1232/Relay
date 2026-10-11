# TestFlight checklist

Code-side blockers are fixed in the repo. These steps need a person — Xcode
project settings (the pbxproj is hand-edited only), web/infra, and Apple portals.

## 1. Xcode project settings

Open `Relay.xcodeproj`, select each target listed, then **Build Settings** or **Info**.

1. **One deployment target for every target** (App Store validation rejects
   extensions that require a newer iOS than the app):
   project + all 7 targets → Build Settings → *iOS Deployment Target*.
   Today: app 18.6, project 26.5, NSE inherits 26.5, the other extensions 27.0.
   Pick one (e.g. 26.0 for everything) and set it on the project and every target.
2. **Display names** (shown in the share sheet / widget gallery):
   RelayShareExtension, RelayWidgetExtension, RelayNotificationContent,
   RelayIntents, NotificationServiceExtension → Info → *Bundle display name* → `Relay`.
3. **Relay target → Info / Build Settings**:
   - Delete *Privacy - Local Network Usage Description* (dev-only, mentions a
     "local relay server").
   - *Status bar is initially hidden* (`UIStatusBarHidden`) → delete or set NO.
   - *Privacy - Camera Usage Description* →
     "Relay uses the camera for video calls, taking photos to send, and scanning QR codes."
   - *Privacy - Microphone Usage Description* →
     "Relay uses the microphone for calls and voice messages."
   - *Privacy - Contacts Usage Description* →
     "Relay checks which of your contacts use Relay with private, blinded lookups. Your address book is never uploaded or stored on our servers."
4. **Project → Signing**: the project-level Development Team is still the old
   free team `2P24M8G2CJ`; set it to `HK396F3767` like the targets.
5. **Remove leftovers**: select the red `RelayBroadcastUploadSetupUI` folder →
   Delete → *Remove Reference*; Product › Scheme › Manage Schemes → delete the
   `RelayBroadcastUploadSetupUI` scheme.
6. **iPad**: `TARGETED_DEVICE_FAMILY = 1,2` means App Review tests on iPad and you
   need iPad screenshots. If iPad isn't polished, set the Relay target's
   *Supported Destinations* to iPhone only.
7. **Version/build**: bump *Build* (`CURRENT_PROJECT_VERSION`) on every target
   for each upload.

## 2. Server (VPS)

- Deploy the new `relayd` (adds `DELETE /v1/accounts/me`, `POST /v1/reports`;
  the `reports` table is created on start).
- Add `-supabase-service-key-file <path>` (file holding the Supabase
  service-role key, mode 0600) so deleting an account also deletes its
  Supabase auth user and email.
- The app no longer ships the static TURN credential (`relay` / `r3layTURN`):
  remove that static user from coturn so the leaked secret stops working.
- Run the store tests once against a real Postgres: `RELAY_TEST_DSN=… go test ./...`.

## 3. Web / accounts / Apple

- Publish https://relaymsg.app/terms and https://relaymsg.app/privacy (the app
  links to both). The privacy policy should mention that a report can include
  messages the reporter chooses to forward.
- Make sure support@relaymsg.app receives mail (Settings → Send Feedback).
- Serve https://relaymsg.app/.well-known/apple-app-site-association with team
  `HK396F3767` and `app.relaymsg`, or invite/username links won't open the app.
- CloudKit Console: deploy the `Backup` record type to **Production**
  (TestFlight builds use the production environment).
- App Store Connect: answer export compliance (the app uses non-exempt
  encryption; most E2E messengers use the mass-market exemption plus the
  annual BIS self-classification report) — or add
  `ITSAppUsesNonExemptEncryption` to `Relay/Info.plist` once decided.
- Sign in with Apple: deleting an account doesn't yet revoke the Apple token
  (`appleid.apple.com/auth/revoke`) — see `server/README.md` "Known gaps".
- libsignal is AGPL-3.0: publish the app's source (or a source offer).
- Give App Review a demo account, and mention Panic Mode / hidden chats in the
  review notes.

## 4. Needs a real iPhone

Simulators can't do push, CallKit/VoIP or CloudKit:
- Push while backgrounded/locked: a message, a group invite, a profile change
  and a block — then open the app and check the group/profile appear and the
  blocked contact's message didn't notify.
- Calls (audio + video) with dynamic TURN credentials only (no static creds).
- iCloud backup + restore.
- Linking a second phone that had Relay installed before.

## Release audit — 2026-10-08 status

Three audits (server security, iOS security, UI/App Review) ran on 2026-10-08.
Fixed and deployed: group/1:1 hijack and group takeover, account takeover via
sign-in (account-password lock), Relay-Sig body bypass, Basic auth scope,
replay cache, DoS limits, email discovery opt-in, username cooldown, Apple
token revocation (server + client), plaintext id→username lookups removed,
key-change message loss, app/NSE decrypt race, Siri vs panic mode, privacy
copy, friendly errors, accessibility, iPad fixes.

Still open:
- [x] Xcode (done 2026-10-09, commit 96f1b9f): one deployment target for all targets; extension display
      names = "Relay"; project-level team HK396F3767; remove UIStatusBarHidden;
      remove the RelayBroadcastUploadSetupUI leftovers; fix Camera / Microphone /
      Contacts usage strings; delete the Local Network and NFC usage strings.
- [x] ITSAppUsesNonExemptEncryption = YES (set 2026-10-09). Still to do:
      mass-market exemption answers in App Store Connect + annual BIS
      self-classification report.
- [x] Sign in with Apple revocation: key MFV3G8G4PD at /opt/relay/siwa.p8
      (root 0600), relayd runs with -siwa-* flags (2026-10-09).
- [ ] Device-test calls (voice/video over TURN) and iCloud backup/restore.
- [ ] Later: fetch prekey bundles anonymously (access-key gated) and exchange
      access keys end-to-end, so the relay can't see who fetches whose keys.
