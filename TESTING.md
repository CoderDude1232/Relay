# Relay — device-test checklist

On-device verification for the batch of built-but-unverified changes. Simulators
can't do APNs or CloudKit, so the push/backup items need two **physical** iPhones
(the pair in CLAUDE.md) plus a redeployed server.

Simulator results, 2026-10-06 (test1/test2 on the iPhone 17 / 17 Pro sims,
against the redeployed api.relaymsg.app): 1:1 send/reply/receipts, blinded
username lookup, groups (create/send/reply/admin controls), invite link
create + claim (via `relay://join/…`), block/unblock, photos (upload, download,
biometric unlock), and push → NSE fetch/decrypt/ack all pass. Simulators on
Apple silicon DO receive APNs here. Universal links (`https://relaymsg.app/…`)
don't open the app until the site's AASA is fixed (old team/bundle id live).

Preconditions:
- Server redeployed with the latest `main`/branch build (contentless push,
  email-at-rest, encrypted groups, sealed sender, blinded discovery).
- Verify the email migration backfilled:
  `ssh root@api.relaymsg.app "psql relay -c 'SELECT count(*) FROM accounts WHERE email_token IS NULL;'"`
  (a non-zero count = pre-discovery accounts that lost email recovery — expected/acceptable).
- Two devices signed in on the same LAN; a third account for group tests.

## 1. Contentless push (default) + opt-in
- [ ] Kill the app on device B (fully backgrounded / not connected).
- [ ] Send B a 1:1 message from A. B shows a push; opening it reveals the correct
      sender + body. Confirms the NSE fetched from `GET /v1/queue`, decrypted, and acked.
- [ ] Check server logs: push fired, and the envelope was acked (dequeued) by the NSE.
- [ ] Settings → Privacy → Notifications → **Include Message in Push** ON.
- [ ] Repeat the send: push still correct, and arrives without the fetch round-trip
      (payload carried `e`). Toggle OFF again; confirm back to content-free.
- [ ] Muted conversation → no banner. Notification privacy "none"/"nameOnly" respected.

## 2. Email-at-rest (keyed token)
- [ ] New account with an email → succeeds.
- [ ] Recover that account by email + account password on a fresh device → succeeds.
- [ ] OAuth/social sign-in on a second device adopts the same account (not a dup).
- [ ] `psql`: `SELECT email_token IS NOT NULL FROM accounts LIMIT 5;` → tokens present;
      no plaintext `email` column exists.

## 3. Multi-device sync (A + B same account, C is a peer)
- [ ] A sends to C → C receives; **B shows the same sent message** (self-sync).
- [ ] B sends to C → C receives; **A shows it too**.
- [ ] Reaction / edit / unsend / group op on A appears on B (and vice-versa).
- [ ] Leave both A and B idle >2 min, then send → still delivered live (keepalive holds
      the socket; no silent drop).

## 4. iCloud backup / restore
- [ ] Settings → Backup & Restore → Back Up Now → succeeds; note the Recovery Key.
- [ ] Wipe/reinstall the app on that device (or use a spare) → Restore with the
      Recovery Key → conversations + messages return.
- [ ] Wrong Recovery Key → restore fails cleanly (no partial/corrupt state).
- [ ] Confirms the CloudKit **production** schema is deployed (dev schema won't work
      for a release build).

## 5. Encrypted groups
- [ ] Create a group (3 members), send messages → all receive.
- [ ] Add a member → they get subsequent messages, not prior ones.
- [ ] Remove a member → distribution id rotates; removed member can't read new messages.
- [ ] Encrypted invite link claims correctly on a fresh device.

## 6. Sealed sender
- [ ] With sealed sender ON (default), send 1:1 → recipient receives; server logs show
      an envelope with **empty sender fields**.
- [ ] Block a sealed sender → their messages are dropped on receipt.
- (Sealed sender is now mandatory — there is no toggle. A recipient without a
  published access key gets "Not Delivered", never a non-sealed send.)

## Regression sweep (any transport/QUIC change)
- [ ] Cold start on a poor network (Network Link Conditioner "Very Bad Network"):
      connect spinner clears in a few seconds; first send completes.
- [ ] Calls still connect (STUN/TURN); Private Call Mode forces relay.
