# Key transparency

Goal: the relay can't hand someone a fake identity key for a contact without
it being detected, and nobody can read the directory as a list of accounts or
keys. Same idea as CONIKS and WhatsApp's key directory, sized for Relay.

## What the relay publishes

Every epoch (a minute, when something changed) the relay builds a **sparse
Merkle tree** (SMT, depth 256) and publishes a **signed head**.

- **Label** — where an account sits in the tree: `VRF(accountId)`, using
  RSA-FDH-VRF-SHA256 (RFC 9381 §4). Only the relay can compute it, so the tree
  doesn't reveal which accounts exist; the relay hands out a proof with each
  label so a client can check it's the right one.
- **Commitment** — hides the key: `SHA256("relay-kt-commit" ‖ nonce ‖ keys)`,
  with a fresh 32-byte nonce each version. `keys` is the account's identity
  keys (normally one), each as a 2-byte length then the bytes, sorted.
  A removed account commits to no keys.
- **Leaf value** — a hash chain over the account's whole history, so a key
  can't be swapped in and quietly swapped back:
  `chain_v = SHA256("relay-kt-chain" ‖ chain_{v-1} ‖ uint32 v ‖ commitment_v)`,
  `chain_0 = 32 zero bytes`.
- **Tree hashing** — leaf `SHA256(0x00 ‖ label ‖ chain)`, inner node
  `SHA256(0x01 ‖ left ‖ right)`, empty subtree at depth d is a fixed value
  (`empty[256] = 32 zero bytes`, `empty[d] = SHA256(0x01 ‖ empty[d+1] ‖ empty[d+1])`).
- **Root log** — every epoch's SMT root is appended to an RFC 6962 Merkle log,
  so history can only grow: a client that saw an earlier head asks for a
  consistency proof to the new one.
- **Signed head** — Ed25519 over
  `"relay-kt-head-v1" ‖ uint64 epoch ‖ smtRoot ‖ uint64 logSize ‖ logRoot ‖ uint64 time`.

## What clients check

1. **Looking up a contact** (before trusting the key in their prekey bundle):
   VRF proof → label; the latest version's commitment opens to exactly the
   bundle's key; `chain_v` from `chain_{v-1}`; the SMT path from that leaf
   reaches the head's root; the head's signature; and the head is consistent
   with the last head this device saw. Any failure is a safety warning.
2. **Monitoring itself**: each device periodically fetches its own account's
   full version list (with openings, only for its own account) and checks
   every version commits to a key this account actually had. A version it
   didn't create means the relay showed someone a fake key.
3. **Witness** (later): heads are also published, signed, to the public Gist
   used for fallback addresses; clients compare, so the relay can't show
   different people different trees without it showing.

## Remembering what was accepted (stage 5)

A client stores, per contact, the `(version, chain)` it last accepted, and
asks for later lookups with `?since=version`: the relay returns the links
(`version`, `commitment`) after it, and the client recomputes the chain from
its remembered value to the new one. A key shown once and later swapped back
can't be reconciled with what the client remembers. A device does the same for
its own account (hourly), so its older history can't be rewritten either.
Lookups are limited to 600 an hour per account.

## Witness and key rotation (stage 6)

`server/cmd/ktwitness` runs on the TURN box, a different machine from the
relay. Every 5 minutes it fetches the relay's head, checks the relay's
signature and that the head extends the last one it co-signed (consistency
proof), then co-signs it, Ed25519 over `"relay-kt-witness-v1"` and the head's
fields, and publishes `{head fields, sig, witnessSig, endorsements}` to
`kt-head.json` in the public Gist. If a head doesn't extend what it saw, it
stops co-signing and logs an error. Apps accept the published head only with
both signatures and require it to be consistent with the head they were shown,
so faking the directory means compromising both machines.

The relay's signing key can be replaced without an app update:
`relayd -kt-key-dir … -kt-rotate-sign-key` makes a new key, endorsed by the old
one (Ed25519 over `"relay-kt-endorse-v1|head|"` and the new public key), kept in
`endorsements.json` and served at `GET /v1/kt/keys`; the witness passes them on
and apps trust any key reachable from the built-in one by endorsements.

Live witness key (public half, built into the app):
`t4GYsxbk2iG6sPnAWGPnF1I61Kcf4ujTsbhYRNhRkLE=`

## Privacy

The tree shows only pseudonymous labels and commitments. Anyone fetching heads
learns roughly how many entries change per epoch, nothing else. When the app
holds a contact's access key (every contact who has shared their profile), it
looks them up anonymously over `GET /v1/kt/lookup/{account}/sealed`, so the
relay sees a lookup but not who made it. Without an access key the lookup is
signed, which tells the relay who looked whom up; it learns that anyway when it
hands out the contact's prekey bundle on that path.

A first contact's key is checked before the first message is sent. If the
lookup shows a different key, the app waits out the publish delay, checks once
more, and refuses to send while the mismatch stands (unless the safety number
was verified in person).

## Live keys (public halves; the app builds these in)

Created 2026-11-04 by relayd (`-kt-key-dir /opt/relay/kt`). The private halves
must never be replaced or lost: every app's checks depend on them.

- Head signing key (Ed25519, base64): `AzBwua2UHxq2M6FiWv+rJ8lAwOvG8b3f2BZXafwWW0I=`
- VRF key (RSA-2048):

```
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoFRYR4xchotekT/gxGcW
yby+F4mVI65SmVB3bP1XTrm1B2d6XtPVbGadyav2WooeHKanNZNoT6Q0saFWZJxU
0dzx5vB2bqwcbrWMT6/j+3IWBlevqi2QJgs7crrqNYkV8V8eg7dR9jGr8LrCSg8T
rYZXW6viQK0IUtkxqe04m8AvZItjQhjHsWfpWzdS0dZE9PrYvHdqJj6MJ4cmR2eM
oN4++k6hYrRQw62Ny4vTr8CoIG2BsOVGq8G1WVN1rcHHeHguz88fAta05UtneZUI
ebGaNVvwqKpRPZciX+++HDOnCliMItkFlrPhPRch7BvpYgo6Viz2gAgihogckh9c
NwIDAQAB
-----END PUBLIC KEY-----
```

## Stages

1. Crypto core (`server/internal/kt`): VRF, SMT, root log, heads, and the
   verification functions, with tests. ← done
2. Relay: tables, a sync job that versions keys from `devices`, endpoints
   (`GET /v1/kt/head`, `/v1/kt/lookup/{account}`, `/v1/kt/consistency`,
   `/v1/kt/monitor`), deploy. ← live since 2026-11-04
3. App: verify lookups when processing a bundle and on the safety-number
   screen; monitor its own account; remember the last head. ← done
   (RelayKit `KeyTransparency.swift`, `MessagingService+KeyTransparency.swift`;
   the Go test `TestWriteVectors` writes vectors the Swift side is checked
   against). A mismatch is re-checked after 75 s, since a key changed in the
   last minute isn't published yet, then shows as a changed safety number.
   A changed key the directory confirms (a contact's new phone or reinstall)
   is acknowledged automatically, so it shows as verified instead of
   changed, unless that contact was verified in person: then the new key
   still has to be compared again.
4. Witness: publish heads to the Gist; clients compare. ← done
5. Remember accepted state per contact and for ourselves (above). ← done
6. Independent co-signing witness and signing-key rotation (above). ← done

Not covered: rotating the VRF key or the witness key needs an app update (they
only need to be kept safe; see the backups in the deploy notes).
