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

## Privacy

The tree shows only pseudonymous labels and commitments. Anyone fetching heads
learns roughly how many entries change per epoch, nothing else. Lookups
reveal who you look up only to the relay, which already learns that when it
hands out the contact's prekey bundle.

## Stages

1. Crypto core (`server/internal/kt`): VRF, SMT, root log, heads, and the
   verification functions, with tests. ← this
2. Relay: tables, a sync job that versions keys from `devices`, endpoints
   (`GET /v1/kt/head`, `/v1/kt/lookup/{account}`, `/v1/kt/consistency`,
   `/v1/kt/monitor`), deploy.
3. App: verify lookups when processing a bundle and on the safety-number
   screen; monitor its own account; remember the last head.
4. Witness: publish heads to the Gist; clients compare.
