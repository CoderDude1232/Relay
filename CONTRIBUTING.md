# Contributing to Relay

Thanks for your interest in Relay. Bug reports, fixes and improvements are all
welcome.

## Before you start

- **Security issues** go to security@relaymsg.app, never a public issue. See
  [SECURITY.md](SECURITY.md).
- **Bugs:** open an issue with your iOS version, the Relay version (bottom of
  Profile), what you did, what you expected and what happened.
- **Features and larger changes:** open an issue to discuss them first, so
  nobody spends time on something that won't fit.

## Making a change

1. Fork the repository and create a branch from `main`.
2. Set up the build as described in the [README](README.md#building).
3. Keep the change focused: one fix or feature per pull request.
4. Match the style of the surrounding code, and add or update tests where it
   makes sense (`go test ./...` for the server; package tests via `xcodebuild
   test` for the Swift packages).
5. Open a pull request that explains what changed and why, and how you tested
   it.

## Ground rules

- **The protocol comes first.** A change that affects the wire belongs in
  `proto/` and [`server/README.md`](server/README.md) as well as the code, and
  must stay compatible with existing clients or say clearly why it can't.
- **Privacy is a requirement.** Don't add analytics, tracking, third-party SDKs,
  or logging of identifiers, IP addresses or message metadata. New data kept on
  the server needs a strong reason, and an update to the privacy policy.
- **Cryptography changes need review.** Anything touching keys, sessions,
  storage encryption or authentication gets extra scrutiny; explain the threat
  model in the pull request.
- **No secrets.** Never commit keys, tokens, certificates or server addresses.
- **Project files.** Avoid hand-editing `Relay.xcodeproj/project.pbxproj`;
  describe project setting changes in the pull request instead.

## License

By contributing, you agree that your contributions are licensed under the
[GNU Affero General Public License v3.0](LICENSE), the same license as the rest
of Relay.
