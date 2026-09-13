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

        switch decrypt(request) {
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
            // notification icon (large photo, small app-icon badge bottom-right)
            // and elevates the notification through Focus modes.
            contentHandler(enriched(content: content,
                                    senderName: title,
                                    senderAccount: senderAccount,
                                    conversationId: conversationId))
        case .suppress:
            // Call signalling envelope — CallKit handles the UI via VoIP push.
            // Suppress the banner so the user doesn't see a "New message" alert.
            contentHandler(UNMutableNotificationContent())
        case .none:
            // Decryption failed. The most common cause is a race where the main app's
            // WebSocket already consumed the same envelope (read receipts hit this path
            // frequently). Suppress rather than surface a spurious "New message" banner.
            contentHandler(UNMutableNotificationContent())
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    // MARK: - Communication Notification enrichment

    private func enriched(
        content: UNMutableNotificationContent,
        senderName: String,
        senderAccount: String,
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
            personHandle: INPersonHandle(value: senderAccount, type: .unknown),
            nameComponents: nameComponents,
            displayName: senderName,
            image: image,
            contactIdentifier: nil,
            customIdentifier: senderAccount,
            isMe: false,
            suggestionType: .none
        )

        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: nil,
            conversationIdentifier: conversationId.isEmpty ? senderAccount : conversationId,
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

    private func decrypt(_ request: UNNotificationRequest) -> DecryptOutcome? {
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

        // Pass the trust root so sealed-sender pushes (empty envelope sender)
        // decrypt here too, and ownAccountId so self-sync copies resolve.
        let processor = EnvelopeProcessor(
            storage: storage,
            engine: engine,
            ownAccountId: account.accountId,
            sealedSenderTrustRoot: RelaySealedSender.trustRoot
        )
        guard let result = try? processor.process(envelope) else { return nil }

        // Call signalling: HANGUP means the caller gave up before we answered
        // — show a missed call banner. Everything else (OFFER, ICE, ANSWER…)
        // is handled by VoIP push + CallKit; suppress the regular APNs banner.
        if let callInfo = result.callInfo {
            if callInfo.type == .offer {
                savePendingCallOffer(callInfo, in: storage)
            }
            if callInfo.type == .hangup {
                let callerAccount = result.peerAccount ?? ""
                let name = callerDisplayName(for: callerAccount, in: storage)
                    ?? String(callerAccount.prefix(8))
                return .show(title: name, body: "Missed call",
                             conversationId: "", senderAccount: callerAccount)
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
        let mutedIds = defaults?.stringArray(forKey: "relay.mutedConversationIds") ?? []
        if mutedIds.contains(notification.conversationId) { return .suppress }

        let title = displayName(for: notification.conversationId, in: storage)
            ?? String(notification.senderAccount.prefix(8))

        // Notification privacy: app-level setting takes precedence over per-conversation.
        // "nameOnly": show sender name but redact message content.
        // "none": hide both sender name and content.
        // Per-conversation hidePreviews overrides with "nameOnly" when set.
        let globalPrivacy = defaults?.string(forKey: "relay.notificationPrivacy") ?? "full"
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
                body: notification.body,
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
