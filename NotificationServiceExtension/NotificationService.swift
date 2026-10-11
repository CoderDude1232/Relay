//
//  NotificationService.swift
//  NotificationServiceExtension
//
//  Decrypts the pushed envelope with the same EnvelopeProcessor the app uses,
//  against the App Group SQLCipher store, and fills in the banner with the
//  sender and preview. APNs only ever carries ciphertext or nothing.
//

import CryptoCore
import Intents
import RelayCore
import RelayKit
import SecureStorage
import UserNotifications

class NotificationService: UNNotificationServiceExtension {
    /// A 1:1 OFFER or a GROUP_RING the NSE decrypted, kept for the app to
    /// replay after the VoIP push wakes it.
    private struct PendingCallOffer: Codable {
        let callId: String
        let callerAccount: String
        let sdp: String
        var isGroupRing: Bool? = nil
        var groupId: String? = nil
        var ice: String? = nil
        var participants: [String]? = nil
    }

    private static let pendingCallOfferPrefix = "pending-call-offer:"

    /// Every call signal the NSE decrypted (OFFER, ICE, GROUP_RING, mesh
    /// messages...), kept in arrival order for the app to replay. Without the
    /// ICE candidates a call answered from the lock screen can't connect.
    private struct PendingCallMessage: Codable {
        let callId: String
        let type: CallInfo.CallType
        let sdp: String
        let ice: String
        let callerAccount: String
        let groupId: String
        let targetAccount: String
        let participants: [String]
        let receivedAt: Int64
    }

    private static let pendingCallMessagePrefix = "pending-call-msg:"

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
        //  - Contentless wake (default): no "e" in the payload. Fetch the queued
        //    envelopes from the relay and decrypt them.
        //  - Ciphertext in push (opt-in): "e" carries the encrypted envelope.
        //    Decrypt it directly.
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
        case .show(_, _, let conversationId, _) where !conversationId.isEmpty
            && PanicHiddenChats.load().contains(conversationId):
            // Hidden by Panic Mode: nothing on the lock screen, no Siri donation.
            contentHandler(UNMutableNotificationContent())
        case .show(let title, let body, let conversationId, let senderAccount):
            // Sender, preview, and the conversation id for tap-to-navigate.
            content.title = title
            content.body = body
            content.categoryIdentifier = "RELAY_MESSAGE"
            if !conversationId.isEmpty {
                var info = content.userInfo
                info["conversationId"] = conversationId
                content.userInfo = info
                content.threadIdentifier = conversationId
            }
            // Wrap in INSendMessageIntent so iOS shows the sender's avatar, but only
            // when the preview level allows the name. In "none" mode nothing about
            // the sender goes to the system.
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
            // drained, a control message, or nothing to fetch. Suppress instead of
            // showing a generic "New message" banner.
            contentHandler(UNMutableNotificationContent())
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    // MARK: - Communication Notification enrichment

    /// The app-wide preview level; name only if never set.
    private static func previewLevel(defaults: UserDefaults?) -> String {
        defaults?.string(forKey: "relay.notificationPrivacy") ?? "nameOnly"
    }

    /// Builds a communication notification. The donated intent carries no
    /// message content, since iOS keeps donations outside Relay's encryption,
    /// and identifies the sender only by the local conversation id, never the
    /// account id.
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
        case suppress // decrypted, but nothing to show
    }

    // Ciphertext-in-push path: the envelope is in the payload as "e". Returns
    // nil when it isn't, so the caller fetches from the queue instead.
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
        // Blocked senders are still decrypted to keep the ratchet in sync; the
        // processor drops them before storing, as in the app.
        let blocked = RelayStore.blockedAccounts(in: storage)
        guard let result = try? processor.process(envelope, blockedAccounts: blocked) else { return .suppress }
        // The ratchet has advanced and the app can't decrypt this again, so
        // hand it the control payloads to apply later.
        PendingControlStore.persist(result, envelopeId: envelope.id, in: storage)
        return outcome(for: result, storage: storage, appGroupId: appGroupId, account: account)
    }

    // Contentless push: the payload carries no message data at all, only a
    // wake. Fetch this device's queued envelopes, decrypt and store them, and
    // ack each one so the server dequeues it.
    private func fetchAndDecrypt() async -> DecryptOutcome? {
        let appGroupId = RelayStore.appGroupId
        guard
            let storage = try? RelayStore.open(appGroupId: appGroupId),
            let account = try? RelayStore.loadAccount(appGroupId: appGroupId),
            let engine = try? storage.makeCryptoEngine(accountId: account.accountId, deviceId: account.deviceId)
        else { return nil }

        // Sign with the device auth key, shared via the App Group keychain. The
        // relay refuses HTTP Basic once a key is set.
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

        // The trust root lets sealed-sender envelopes (empty sender) decrypt here;
        // ownAccountId resolves self-sync copies.
        let processor = EnvelopeProcessor(
            storage: storage,
            engine: engine,
            ownAccountId: account.accountId,
            sealedSenderTrustRoot: RelaySealedSender.trustRoot,
            processLock: .envelopeProcessing(appGroupId: appGroupId)
        )

        // Blocked senders are still decrypted to keep the ratchet in sync; the
        // processor drops them before storing, as in the app.
        let blocked = RelayStore.blockedAccounts(in: storage)

        var latest: DecryptOutcome?
        for envelope in envelopes {
            let result = try? processor.process(envelope, blockedAccounts: blocked)
            // The ratchet has advanced and the app can't decrypt this again, so
            // persist the control payloads for the app to apply.
            if let result {
                PendingControlStore.persist(result, envelopeId: envelope.id, in: storage)
            }
            // Ack stored and poison messages alike, as the app does. Ephemeral
            // envelopes never queue.
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
        // An unsend or edit: drop the chat's banners that show the old text.
        if result.removesNotifications, let conversationId = result.conversationId {
            let center = UNUserNotificationCenter.current()
            center.getDeliveredNotifications { delivered in
                let stale = delivered.filter { $0.request.content.threadIdentifier == conversationId }
                    .map(\.request.identifier)
                if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
            }
        }
        // HANGUP means the caller gave up before we answered: show a missed call.
        // Other signalling goes through VoIP push and CallKit; suppress it here.
        if let callInfo = result.callInfo {
            savePendingCallMessage(callInfo, in: storage)
            if callInfo.type == .linkJoinRequest {
                // Only for a link we created, with the right secret, so nobody can spam
                // this banner. The app picks the request up via PendingControlStore.
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
                // Missed-call banner, honouring the preview level. An unknown caller is
                // just "Missed call", never an account id prefix.
                let callerAccount = result.peerAccount ?? ""
                // Only from someone we've accepted a chat with: anyone can send a
                // HANGUP, and calls from requests don't ring in the first place.
                let accepted = (try? storage.database.query(
                    "SELECT 1 FROM conversations WHERE peer_account = ? AND group_id IS NULL AND accepted = 1",
                    [.text(callerAccount)]
                ))?.isEmpty == false
                guard accepted else { return .suppress }
                let showName = Self.previewLevel(defaults: UserDefaults(suiteName: appGroupId)) != "none"
                let name = showName ? (callerDisplayName(for: callerAccount, in: storage) ?? "Relay") : "Relay"
                return .show(title: name, body: "Missed call",
                             conversationId: "", senderAccount: "")
            }
            return .suppress
        }

        guard let notification = result.notification else {
            // The app may already have processed this envelope after a VoIP wake or
            // reconnect. Duplicates, receipts, ICE and other invisible control
            // messages shouldn't fall back to the server's "New message" placeholder.
            return .suppress
        }
        let defaults = UserDefaults(suiteName: appGroupId)
        // Like the app, an @mention of us still shows in a muted conversation.
        if RelayStore.isConversationMuted(notification.conversationId, defaults: defaults) {
            let mentioned = account.username.map {
                Mentions.contains(notification.body, username: $0)
            } ?? false
            if !mentioned { return .suppress }
        }
        // Notepad updates are stored as prefixed text; keep the marker out of
        // the banner.
        let previewBody = notification.body.hasPrefix(PendingControlStore.notepadPrefix)
            ? "📝 Updated the shared notepad"
            : notification.body == "__sticker__" ? "Sent a sticker"
            : notification.body

        // Never show any part of the sender's account id.
        let title = displayName(for: notification.conversationId, in: storage) ?? "Relay"

        // The app-level setting takes precedence. "nameOnly" redacts content,
        // "none" hides name and content. Per-conversation hidePreviews forces
        // "nameOnly".
        let globalPrivacy = Self.previewLevel(defaults: defaults)
        let convHidePreviews = conversationHidesPreviews(notification.conversationId, in: storage)
        let effectivePrivacy = (globalPrivacy == "none") ? "none"
                             : (globalPrivacy == "nameOnly" || convHidePreviews) ? "nameOnly"
                             : "full"

        // A stranger's first messages never show their text on the lock screen.
        let isRequest = ((try? storage.database.query(
            "SELECT accepted FROM conversations WHERE id = ?", [.text(notification.conversationId)]
        ).first?.first?.int64) ?? 1) == 0
        if isRequest {
            return .show(title: globalPrivacy == "none" ? "Relay" : title, body: "Sent you a message request",
                         conversationId: notification.conversationId, senderAccount: notification.senderAccount)
        }

        // Disappearing chats stay out of the snapshot: it would outlive the timer.
        let disappearing = ((try? storage.database.query(
            "SELECT disappearing_seconds FROM conversations WHERE id = ?", [.text(notification.conversationId)]
        ).first?.first?.int64) ?? 0) > 0
        if !convHidePreviews, !disappearing {
            let text = notification.body.hasPrefix(PendingControlStore.notepadPrefix)
                ? previewBody
                : RecentChatsSnapshot.previewText(body: notification.body, attachmentType: nil)
            RecentChatsStore.appendIncoming(
                conversationId: notification.conversationId,
                text: text,
                sender: callerDisplayName(for: notification.senderAccount, in: storage)
            )
        }

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

    private func savePendingCallMessage(_ callInfo: CallInfo, in storage: SecureStore) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let message = PendingCallMessage(
            callId: callInfo.callId, type: callInfo.type, sdp: callInfo.sdp, ice: callInfo.ice,
            callerAccount: callInfo.callerAccount, groupId: callInfo.groupId,
            targetAccount: callInfo.targetAccount, participants: callInfo.participants, receivedAt: now
        )
        guard let data = try? JSONEncoder().encode(message) else { return }
        // Zero-padded time first, so keys sort in arrival order.
        let key = Self.pendingCallMessagePrefix + String(format: "%015lld-", now) + UUID().uuidString
        try? storage.database.run("INSERT INTO kv (key, value) VALUES (?, ?)", [.text(key), .blob(data)])
    }

    private func savePendingCallOffer(_ callInfo: CallInfo, in storage: SecureStore) {
        let isGroupRing = callInfo.type == .groupRing
        let pending = PendingCallOffer(
            callId: callInfo.callId,
            callerAccount: callInfo.callerAccount,
            sdp: callInfo.sdp,
            isGroupRing: isGroupRing ? true : nil,
            groupId: isGroupRing ? callInfo.groupId : nil,
            ice: isGroupRing ? callInfo.ice : nil,
            participants: isGroupRing ? callInfo.participants : nil
        )
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text(Self.pendingCallOfferPrefix + callInfo.callId), .blob(data)]
        )
    }

    /// Previews off, or the chat needs Face ID to open: either way its text
    /// stays off the lock screen (and out of the Siri/notification snapshot).
    private func conversationHidesPreviews(_ conversationId: String, in storage: SecureStore) -> Bool {
        guard !conversationId.isEmpty,
              let row = (try? storage.database.query(
                  "SELECT hide_previews, require_biometric_chat FROM conversations WHERE id = ?", [.text(conversationId)]
              ).first) ?? nil
        else { return false }
        return (row[0].int64 ?? 0) != 0 || (row[1].int64 ?? 0) != 0
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

    // Same order as MessagingService.resolveDisplayName: nickname (kv),
    // profile display name, username.
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
