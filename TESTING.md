# Relay — device-test checklist

What to check on real devices before a release. Simulators can't do CallKit
calls, VoIP push, CloudKit or passkeys, so most of this needs two physical
iPhones (A and B) on the newest TestFlight build, plus a third account (C) for
groups and message requests.

"Closed" means swiped away in the app switcher.

## Status (2026-10-11)

Passed on device: 1:1 and group calls through CallKit, answering from the lock
screen with the app closed (after the OFFER-carries-ICE fix), group rings by
VoIP push, mid-call TURN failover to Cloudflare (5–10 s freeze, recovers),
passkey create and sign-in, iCloud backup, safety numbers matching after a
re-sign-in, export-compliance and CloudKit production setup.

Not yet verified: everything marked ☐ below.

## Accounts and sign-in
- ☐ Sign up without an email (passkey only): trade-offs screen, recovery key
  shown once and must be acknowledged.
- ☐ Recovery key: view with passkey and with email code; sign out, sign in
  with the key; chat list comes back; "Create New Key" stops the old one.
- ☐ Remove email (account with a passkey): Email shows "None" afterwards,
  Find Me by Email hidden, passkey sign-in still works.
- ☐ Passkey sign-in on a second iPhone restores the chat list.

## Messaging
- ✅ Message requests: C (never chatted with A) messages A. A sees "Message
  Requests", the lock screen says "Sent you a message request", photos show
  "Accept to view", C gets no read receipts. Accept, Delete, Block and
  Block and Report each behave.
- ☐ Group request: C adds A to a new group; it lands in requests.
- ☐ Faster group sends (sender keys under sealed sender): every member of a
  3+ person group receives every message.
- ☐ New chat with someone never messaged (one-time Kyber prekey path).

## Calls
- ✅ 1:1: A closed, B calls, A answers on the lock screen → connects. Reverse.
- ✅ 1:1 with both apps open rings through CallKit.
- ✅ Group call: green pill, lock-screen answer and mute, leave from the pill.
- ☐ Group call: A leaves → B's call ends by itself. A hangs up before anyone
  answers → B stops ringing.
- ☐ Group call screen with 2+ others: black/white background per theme, each
  card shows that person's blurred photo, controls readable in light mode.
- ☐ Call link: host and join both show a system call.
- ☐ A cellular call arriving during a Relay call can hold/end it.
- ✅ Mid-call TURN failover (stop coturn during a call; see the
  `relay-vps-deploy` memory for the commands).

## Location
- ☐ Live location: B keeps getting updates while A's phone is locked (blue
  location indicator shows), and sharing stops when it expires.

## Siri, notifications, Watch
- ☐ Siri send: one Relay card at each step, recent messages, chat theme.
- ☐ Expanded notification shows recent messages and the wallpaper.
- ☐ Watch: chat list with photos, reply, call (rings on the iPhone),
  tapping a notification opens the chat.

## Accessibility (labels are ticked in App Store Connect)
- ☐ VoiceOver and the largest text size on iPad and Apple Watch.

## Regression sweep (after any transport or crypto change)
- 1:1 send/reply/receipts, group send, photo send, push wake with the app
  closed, call both ways, sign out and back in.
