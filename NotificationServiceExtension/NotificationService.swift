//
//  NotificationService.swift
//  NotificationServiceExtension
//
//  Decrypts the pushed envelope (carried in the APNs payload as base64) using
//  the SAME shared EnvelopeProcessor the app uses, then fills the banner with
//  the real sender + preview. Apple only ever saw ciphertext; decryption
//  happens here, on-device, against the App-Group SQLCipher store.
//

import CryptoCore
import Intents
import RelayCore
import RelayKit
import SecureStorage
import UserNotifications

class NotificationService: UNNotificationServiceExtension {
    private struct PendingCallOffer: Codable {
        let callId: String
        let callerAccount: String
        let sdp: String
    }

    private static let pendingCallOfferPrefix = "pending-call-offer:"

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
        bestAttemptContent = content

        guard let content else {
            contentHandler(request.content)
            return
        }

        // Two modes:
        //  • Content-free wake (default): the payload has no "e". Fetch the queued
        //    envelope(s) from the relay, decrypt on-device, then present.
        //  • Ciphertext-in-push (opt-in): the payload carries the encrypted
        //    envelope in "e". Decrypt it directly — no round-trip.
        Task { [weak self] in
            let outcome: DecryptOutcome?
            if let self, let embedded = self.decryptEmbedded(request) {
                outcome = embedded
            } else {
                outcome = await self?.fetchAndDecrypt()
            }
            self?.present(outcome, into: content, contentHandler: contentHandler)
        }
    }

    private func present(
        _ outcome: DecryptOutcome?,
        into content: UNMutableNotificationContent,
        contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        switch outcome {
        case .show(let title, let body, let conversationId, let senderAccount):
            // Reveal sender + preview, and embed conversationId for tap-to-navigate.
            content.title = title
            content.body = body
            content.categoryIdentifier = "RELAY_MESSAGE"
            if !conversationId.isEmpty {
                var info = content.userInfo
                info["conversationId"] = conversationId
                content.userInfo = info
                content.threadIdentifier = conversationId
            }
            // Wrap in INSendMessageIntent so iOS shows the sender's avatar as the
            // notification icon — but only when the preview level allows the
            // sender's name to be shown at all. In "no name or content" mode
            // nothing about the sender is handed to the system.
            guard Self.previewLevel(defaults: UserDefaults(suiteName: RelayStore.appGroupId)) != "none",
                  !senderAccount.isEmpty, !conversationId.isEmpty
            else {
                contentHandler(content)
                return
            }
            contentHandler(enriched(content: content,
                                    senderName: title,
                                    conversationId: conversationId))
        case .suppress, .none:
            // Call signalling (handled by VoIP push), a duplicate the app already
            // drained, a control message, or nothing to fetch — suppress rather than
            // surface a spurious "New message" banner.
            contentHandler(UNMutableNotificationContent())
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    // MARK: - Communication Notification enrichment

    /// The app-wide preview level. Default (never chosen): name only.
    private static func previewLevel(defaults: UserDefaults?) -> String {
        defaults?.string(forKey: "relay.notificationPrivacy") ?? "nameOnly"
    }

    /// Builds a communication notification. The donated intent carries NO
    /// message content (iOS stores donations in its own interaction database,
    /// outside Relay's encryption) and identifies the sender only by the opaque
    /// local conversation id — never their Relay account id.
    private func enriched(
        content: UNMutableNotificationContent,
        senderName: String,
        conversationId: String
    ) -> UNNotificationContent {
        var nameComponents = PersonNameComponents()
        let parts = senderName.split(separator: " ", maxSplits: 1)
        nameComponents.givenName  = parts.first.map(String.init) ?? senderName
        if parts.count > 1 { nameComponents.familyName = String(parts[1]) }

        var image: INImage? = nil
        if let data = avatarData(forConversationId: conversationId) {
            image = INImage(imageData: data)
        }

        let sender = INPerson(
            personHandle: INPersonHandle(value: conversationId, type: .unknown),
            nameComponents: nameComponents,
            displayName: senderName,
            image: image,
            contactIdentifier: nil,
            customIdentifier: conversationId,
            isMe: false,
            suggestionType: .none
        )

        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: nil,
            conversationIdentifier: conversationId,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)

        return (try? content.updating(from: intent)) ?? content
    }

    private func avatarData(forConversationId id: String) -> Data? {
        guard !id.isEmpty,
              let dir = FileManager.default.containerURL(
                  forSecurityApplicationGroupIdentifier: RelayStore.appGroupId
              )?.appendingPathComponent("relay-avatars", isDirectory: true)
        else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(id))
    }

    // MARK: - Decryption

    private enum DecryptOutcome {
        case show(title: String, body: String, conversationId: String, senderAccount: String)
        case suppress   // Decrypted successfully but nothing to surface (call, etc.)
    }

    // Opt-in ciphertext-in-push path: the encrypted envelope rode along in the
    // APNs payload ("e"). Decrypt it directly — no network round-trip. Returns
    // nil when the payload carries no envelope (the content-free default), so the
    // caller falls back to fetching from the queue.
    private func decryptEmbedded(_ request: UNNotificationRequest) -> DecryptOutcome? {
        guard
            let encoded = request.content.userInfo["e"] as? String,
            let data = Data(base64Encoded: encoded),
            let envelope = IncomingEnvelope(serializedEnvelope: data)
        else { return nil }

        let appGroupId = RelayStore.appGroupId
        guard
            let storage = try? RelayStore.open(appGroupId: appGroupId),
            let account = try? RelayStore.loadAccount(appGroupId: appGroupId),
            let engine = try? storage.makeCryptoEngine(accountId: account.accountId, deviceId: account.deviceId)
        else { return nil }

        let processor = EnvelopeProcessor(
            storage: storage,
            engine: engine,
            ownAccountId: account.accountId,
            sealedSenderTrustRoot: RelaySealedSender.trustRoot,
            processLock: .envelopeProcessing(appGroupId: appGroupId)
        )
        // Blocked senders are still decrypted (keeps the ratchet in sync) but
        // the processor drops them before storing — matching the app.
        let blocked = RelayStore.blockedAccounts(in: storage)
        guard let result = try? processor.process(envelope, blockedAccounts: blocked) else { return .suppress }
        // The envelope is now claimed and the ratchet advanced, so the app can
        // never re-decrypt it: hand it the control payloads to apply later.
        PendingControlStore.persist(result, envelopeId: envelope.id, in: storage)
        return outcome(for: result, storage: storage, appGroupId: appGroupId, account: account)
    }

    // Contentless push: the APNs payload carries no message data — not even
    // ciphertext. The push is only a wake. We fetch this device's queued
    // envelope(s) from the relay over our own (HTTP/3-capable) connection,
    // decrypt them on-device, store them, and ack each so the server dequeues.
    private func fetchAndDecrypt() async -> DecryptOutcome? {
        let appGroupId = RelayStore.appGroupId
        guard
            let storage = try? RelayStore.open(appGroupId: appGroupId),
            let account = try? RelayStore.loadAccount(appGroupId: appGroupId),
            let engine = try? storage.makeCryptoEngine(accountId: account.accountId, deviceId: account.deviceId)
        else { return nil }

        // Sign with this device's auth key (shared with the app through the App
        // Group keychain): the relay refuses HTTP Basic once a key is set.
        let keychain = KeychainSecureStore(configuration: KeychainConfiguration(accessGroup: appGroupId))
        let api = RelayAPIClient(
            baseURL: account.serverURL,
            credentials: RelayCredentials(
                accountId: account.accountId,
                deviceId: account.deviceId,
                password: account.password
            ),
            signer: RelayClosureSigner(
                sign: { try? keychain.signDeviceAuthorizationPayload($0) },
                publicKey: { try? keychain.deviceAuthorizationPublicKey() }
            )
        )
        guard let envelopes = try? await api.fetchQueue(), !envelopes.isEmpty else { return nil }

        // Pass the trust root so sealed-sender envelopes (empty envelope sender)
        // decrypt here too, and ownAccountId so self-sync copies resolve.
        let processor = EnvelopeProcessor(
            storage: storage,
            engine: engine,
            ownAccountId: account.accountId,
            sealedSenderTrustRoot: RelaySealedSender.trustRoot,
            processLock: .envelopeProcessing(appGroupId: appGroupId)
        )

        // Blocked senders are still decrypted (keeps the ratchet in sync) but
        // the processor drops them before storing — matching the app.
        let blocked = RelayStore.blockedAccounts(in: storage)

        var latest: DecryptOutcome?
        for envelope in envelopes {
            let result = try? processor.process(envelope, blockedAccounts: blocked)
            // The envelope is now claimed and the ratchet advanced, so the app
            // can never re-decrypt it: persist the control payloads (group
            // updates, profiles, receipts to send, …) for the app to apply.
            if let result {
                PendingControlStore.persist(result, envelopeId: envelope.id, in: storage)
            }
            // Ack either way: a message we stored, or a poison one we drop
            // (matches the app's poison-message protection). Ephemeral envelopes
            // never queue, so we won't see them here.
            try? await api.ackMessage(envelopeId: envelope.id)
            guard let result else { continue }
            if let mapped = outcome(for: result, storage: storage, appGroupId: appGroupId, account: account) {
                // Prefer a visible message over a suppress when the queue has several.
                if case .show = mapped { latest = mapped }
                else if latest == nil { latest = mapped }
            }
        }
        return latest
    }

    private func outcome(
        for result: ProcessedEnvelope,
        storage: SecureStore,
        appGroupId: String,
        account: RelayAccount
    ) -> DecryptOutcome? {
        // Call signalling: HANGUP means the caller gave up before we answered
        // — show a missed call banner. Everything else (OFFER, ICE, ANSWER…)
        // is handled by VoIP push + CallKit; suppress the regular APNs banner.
        if let callInfo = result.callInfo {
            if callInfo.type == .offer {
                savePendingCallOffer(callInfo, in: storage)
            }
            if callInfo.type == .linkJoinRequest {
                // Only for a link we really created, with the right secret, so
                // nobody can spam this banner. The app gets the request via
                // PendingControlStore and shows Admit / Deny.
                let defaults = UserDefaults(suiteName: appGroupId)
                guard let secret = CallLinkRecords.secret(forCallId: callInfo.callId, defaults: defaults),
                      secret == callInfo.sdp
                else { return .suppress }
                let showName = Self.previewLevel(defaults: defaults) != "none"
                let name = showName ? (callerDisplayName(for: callInfo.callerAccount, in: storage) ?? "Someone") : "Someone"
                return .show(title: "Call link", body: "\(name) wants to join your call",
                             conversationId: "", senderAccount: "")
            }
            if callInfo.type == .hangup {
                // Missed-call banner, honoring the preview level. No account
                // prefix fallback: an unknown caller is just "Missed call".
                let callerAccount = result.peerAccount ?? ""
                let showName = Self.previewLevel(defaults: UserDefaults(suiteName: appGroupId)) != "none"
                let name = showName ? (callerDisplayName(for: callerAccount, in: storage) ?? "Relay") : "Relay"
                return .show(title: name, body: "Missed call",
                             conversationId: "", senderAccount: "")
            }
            return .suppress
        }

        guard let notification = result.notification else {
            // The app may already have processed the same pushed envelope after a
            // VoIP wake or foreground reconnect. Duplicates, receipts, ICE, and
            // other non-visible control messages should not fall back to the
            // server's generic "New message" placeholder.
            return .suppress
        }
        let defaults = UserDefaults(suiteName: appGroupId)
        // Mute: the app stores per-conversation expiries in `relay.muteExpiries`.
        // Like the app, an @mention of us still surfaces in a muted conversation.
        if RelayStore.isConversationMuted(notification.conversationId, defaults: defaults) {
            let mentioned = account.username.map {
                Mentions.contains(notification.body, username: $0)
            } ?? false
            if !mentioned { return .suppress }
        }
        // Shared-notepad updates are stored as prefixed text; don't leak the
        // raw marker into the banner.
        let previewBody = notification.body.hasPrefix(PendingControlStore.notepadPrefix)
            ? "📝 Updated the shared notepad"
            : notification.body

        // Never fall back to (part of) the sender's account id in a banner.
        let title = displayName(for: notification.conversationId, in: storage) ?? "Relay"

        // Notification privacy: app-level setting takes precedence over per-conversation.
        // "nameOnly": show sender name but redact message content.
        // "none": hide both sender name and content.
        // Per-conversation hidePreviews overrides with "nameOnly" when set.
        let globalPrivacy = Self.previewLevel(defaults: defaults)
        let convHidePreviews = conversationHidesPreviews(notification.conversationId, in: storage)
        let effectivePrivacy = (globalPrivacy == "none") ? "none"
                             : (globalPrivacy == "nameOnly" || convHidePreviews) ? "nameOnly"
                             : "full"

        switch effectivePrivacy {
        case "none":
            return .show(title: "New Message", body: "You have a new message",
                         conversationId: "", senderAccount: "")
        case "nameOnly":
            return .show(title: title, body: "New Message",
                         conversationId: notification.conversationId, senderAccount: notification.senderAccount)
        default:
            return .show(
                title: title,
                body: previewBody,
                conversationId: notification.conversationId,
                senderAccount: notification.senderAccount
            )
        }
    }

    private func savePendingCallOffer(_ callInfo: CallInfo, in storage: SecureStore) {
        let pending = PendingCallOffer(
            callId: callInfo.callId,
            callerAccount: callInfo.callerAccount,
            sdp: callInfo.sdp
        )
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text(Self.pendingCallOfferPrefix + callInfo.callId), .blob(data)]
        )
    }

    private func conversationHidesPreviews(_ conversationId: String, in storage: SecureStore) -> Bool {
        guard !conversationId.isEmpty,
              let row = (try? storage.database.query(
                  "SELECT hide_previews FROM conversations WHERE id = ?", [.text(conversationId)]
              ).first) ?? nil
        else { return false }
        return (row[0].int64 ?? 0) != 0
    }

    private func displayName(for conversationId: String, in storage: SecureStore) -> String? {
        guard let row = (try? storage.database.query(
            "SELECT peer_account, peer_username FROM conversations WHERE id = ?",
            [.text(conversationId)]
        ).first) ?? nil else { return nil }
        let account = row[0].string ?? ""
        let username = row[1].string
        return resolvedName(forAccount: account, fallback: username, in: storage)
    }

    private func callerDisplayName(for account: String, in storage: SecureStore) -> String? {
        let username = (try? storage.database.query(
            "SELECT peer_username FROM conversations WHERE peer_account = ?", [.text(account)]
        ).first?.first?.string) ?? nil
        return resolvedName(forAccount: account, fallback: username, in: storage)
    }

    // Mirrors MessagingService.resolveDisplayName priority:
    // nickname (kv table) → profile display name → username
    private func resolvedName(forAccount account: String, fallback: String?, in storage: SecureStore) -> String? {
        if !account.isEmpty,
           let nick = (try? storage.database.query(
               "SELECT value FROM kv WHERE key = ?", [.text("nick:\(account)")]
           ).first?.first?.string) ?? nil, !nick.isEmpty { return nick }
        if !account.isEmpty,
           let name = (try? storage.database.query(
               "SELECT display_name FROM profiles WHERE account_id = ?", [.text(account)]
           ).first?.first?.string) ?? nil, !name.isEmpty { return name }
        return fallback
    }
}
