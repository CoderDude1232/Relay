# Security policy

## Reporting a vulnerability

Please email **security@relaymsg.app** and don't open a public issue. Include:

- what's affected: the iOS app (with the version shown at the bottom of Profile), the
  relay server, or the protocol;
- the steps to reproduce it, and what an attacker could do with it;
- any proof-of-concept code or logs (with nobody else's data in them).

We'll acknowledge your report, keep you updated while we fix it, and credit you
when the fix ships unless you'd rather we didn't. Please give us a reasonable
time to release a fix before you publish anything.

## Scope

In scope:

- the iOS app and its extensions (this repository);
- the relay server (`server/`) and the production service at `api.relaymsg.app`;
- the wire protocol (`proto/`) and the cryptography described in
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Out of scope: denial of service or load testing against the production service,
social engineering, physical attacks, and issues in third-party services
(Apple, Cloudflare, Supabase) that aren't caused by how Relay uses them.

## Testing safely

Test against your own accounts, or better, a relay you run yourself (see
[server/README.md](server/README.md)). Don't access or change other people's
data, create accounts in bulk, or degrade the service for others. Research done
in good faith within these rules is welcome, and we won't pursue it.

## Supported versions

Fixes go into the latest App Store and TestFlight builds and the production
relay. Older builds aren't patched.
