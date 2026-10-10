# Release prep — CloudKit production + App Review package

Morgan does the Apple-portal steps (his Apple ID owns team HK396F3767).

## 1. CloudKit: deploy the schema to Production (Morgan, ~2 min)

TestFlight and App Store builds use CloudKit's **Production** environment, which
can't create record types on the fly. Until this is done, iCloud Backup fails in
every TestFlight build.

1. Go to https://icloud.developer.apple.com and sign in with Morgan's Apple ID.
2. **CloudKit Database** → container picker (top left) → `iCloud.app.relaymsg`.
3. Make sure the environment switch says **Development**. Open **Schema → Record Types**
   and check that **Backup** exists, with these fields:
   - `payload` — Asset
   - `format` — Int(64)

   (`updatedAt`, Date/Time, may also be there from older builds — that's fine.)
   If **Backup** isn't listed, run one backup from an Xcode build first
   (Profile → Backup & Restore → turn on iCloud Backup), then reload.
4. Left sidebar, bottom: **Deploy Schema Changes…** → review (it should add the
   `Backup` record type) → **Deploy**.
5. Switch the environment to **Production** and confirm **Backup** is listed.

No indexes are needed: the app fetches backups by record name only.

## 2. Demo accounts for App Review (owner creates, then the server marks them)

Two accounts, so the reviewer can message between them. Once marked as demo they
can only reach each other (real users can't find them), their login can't be
changed, and "Delete Account" resets them instead of deleting (see
`server/README.md` "Demo accounts").

1. On a spare device/simulator: *Continue with Email* →
   `ethandaly525+relayreview1@gmail.com` (codes arrive in the normal inbox) →
   username e.g. `relay_review_a` → Profile → Account → **Account Password**.
2. Same again with `+relayreview2` → `relay_review_b`.
3. Mark both as demo with the SQL in `server/README.md` ("Demo accounts").
4. From A, start a chat with `relay_review_b` and exchange a few messages and a
   photo, so the reviewer sees a real conversation.
5. Simplest for Apple: the **review code** (in 1Password; on the server at
   `/opt/relay/demo-code`). Sign in → *Sign in with a review code*. The first
   device gets one demo account, a second device the other, and each already
   has a chat with the other demo account. Also give both email logins as a
   fallback (email + account password). They sign in with
   *Already have an account? Sign in*. Don't use the accounts yourself during
   review: each sign-in signs the other device out.

## 3. App Store Connect: TestFlight external testing (Morgan)

App Store Connect → Apps → **Relay Private Messenger** → **TestFlight**.

**Test Information** (left sidebar):
- Beta App Description: the "What is Relay" text below
- Feedback Email: `support@relaymsg.app`
- Marketing URL: `https://relaymsg.app`
- Privacy Policy URL: `https://relaymsg.app/privacy`

**Beta App Review Information:**
- Contact: Morgan Daly, his phone, `support@relaymsg.app`
- Sign-in required: **Yes**. Username = the demo email, Password = the demo
  account password
- Review Notes: paste the notes below

Then **External Testing** → **+** → new group (e.g. "Public Beta") → add the latest
build → fill in "What to Test" → **Submit for Review**. The first external build
waits for Beta App Review (usually under a day); later builds are often approved
automatically.

## What is Relay (Beta App Description)

Relay is a private messenger. Messages, photos, voice notes, calls and group
chats are end-to-end encrypted with the Signal Protocol, so only the people in
the conversation can read them. Sign up with Apple, Google or email. No phone
number needed. Relay's servers never see your messages, your contacts or who
you talk to.

## What to Test (TestFlight)

Thanks for testing Relay! Please try:
- Signing up (Apple, Google, or email with a one-time code) and choosing a username
- Messaging someone by username, link or QR code: text, photos, voice notes, polls, live location
- Voice and video calls
- Group chats
- Profile → Backup & Restore: turn on iCloud Backup, then sign out and back in. You should be offered your messages back
- Forgot password and change email (Profile → Account)

Report problems with TestFlight's screenshot feedback, or email support@relaymsg.app.

## Review Notes (paste into Beta App Review / App Review)

Relay is an end-to-end encrypted messenger (Signal Protocol). Our servers can't
read message content, so there is nothing for us to moderate centrally; users
are protected with the tools listed below.

SIGN IN: Use the demo account. On the welcome screen tap "Already have an
account? Sign in" and enter the email and password above. Signing in on a new
device signs out the account's other devices (a security feature). New accounts
can also be created with Sign in with Apple, Google, or an emailed one-time code.

TO TRY MESSAGING: Tap the compose button (top right of Chats) and enter a
username. The demo account already has a conversation, and "Note to Self" works
without a second person.

USER SAFETY (Guideline 1.2):
- Report: open a chat → tap the contact's name → "Report …". Reports go to
  support@relaymsg.app; message content is included only if the reporter chooses
  to share it. Groups: group info → "Report Group".
- Block: the contact's card → "Block". Manage under Profile → Chats → Blocked Contacts.

ACCOUNT DELETION (5.1.1(v)): Profile → Delete Account. This deletes the account
on our server and its sign-in record, and revokes the Sign in with Apple token.

OPTIONAL PRIVACY FEATURE (disclosed per 2.3.1): "Panic Mode" lets a user hide
selected chats behind a PIN. It's opened by tapping the version number at the
bottom of the Profile tab five times. Once enabled, long-press a chat → "Hide in
Panic Mode", and tap the lock icon in the Chats header to reveal hidden chats.

PERMISSIONS: Camera (calls, photos, QR scanning), Microphone (calls, voice
notes), Contacts (optional: finds friends via blinded lookups; the address book is
never uploaded), Location (only when the user shares a location in a chat).

ENCRYPTION: Standard algorithms only (Signal Protocol / AES / ECDH via libsignal
and Apple CryptoKit), used to protect user communications.

## Before public release — legal/compliance, not App Review

- ~~**libsignal is AGPL-3.0.**~~ Done 2026-10-10: the repo is public under
  AGPL-3.0 (github.com/CoderDude1232/Relay) and relaymsg.app/source links it.
- **Export compliance:** `ITSAppUsesNonExemptEncryption` is `NO` in `Info.plist`,
  but `TESTFLIGHT.md` says the plan was `YES` plus the mass-market exemption and
  the annual BIS self-classification report. The questionnaire answer in App
  Store Connect must match whichever is right. Confirm with Morgan before external
  testing.
