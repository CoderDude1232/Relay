//
//  MessagingService+Presence.swift
//  Relay
//
//  Read state and presence.
//  Split out of MessagingService.swift.
//

import CryptoCore
import CryptoKit
import Foundation
import Intents
import LibSignalClient
import Network
import Observation
import UniformTypeIdentifiers
import RelayCore
import RelayKit
import SwiftProtobuf
import SecureStorage
import UIKit
import UserNotifications
import os

extension MessagingService {
    // MARK: - Read state

    func openConversation(_ conversationId: String) {
        activeConversationId = conversationId
        activeMessages = []
        activeMessageLimit = Self.messagePageSize
        hasEarlierMessages = false
        messagesLoadedConversationId = nil
        cachedActiveGroup = group(for: conversationId)  // avoids per-message DB queries
        refreshActiveMessages(ifShowing: conversationId)
        Task { await markVisibleMessagesRead(in: conversationId) }
        // The official Relay chat and Note to Self have no real peer to poll,
        // pre-warm a session with, or send a profile to.
        let localOnlyPeers: Set<String> = [relayOfficialAccount, noteToSelfAccount]
        if let peer = resolvedPeerAccount(for: conversationId), localOnlyPeers.contains(peer) {
            stopPresencePolling()
            return
        }
        if cachedActiveGroup == nil, let peer = resolvedPeerAccount(for: conversationId) {
            startPresencePolling(peer: peer)
        } else {
            stopPresencePolling()
        }
        Task {
            if let group = group(for: conversationId) {
                await distributeProfileToGroupMembersIfNeeded(group: group)
            } else if let peer = resolvedPeerAccount(for: conversationId) {
                // Pre-warm the sealed-send path so the first message doesn't chain
                // a bundle fetch before sending.
                if knownAccessKey(peer) == nil { try? await refreshSessions(withPeer: peer) }
                _ = try? await senderCertificate()
                await sendMyProfileIfNeeded(toPeer: peer)
            }
        }
    }

    func closeConversation(id: String) {
        // SwiftUI fires the new view's onAppear before the old onDisappear.
        guard activeConversationId == id else { return }
        activeConversationId = nil
        activeMessages = []
        messagesLoadedConversationId = nil
        cachedActiveGroup = nil
        typingResetTasks[id]?.cancel()
        typingResetTasks.removeValue(forKey: id)
        typingConversations.remove(id)
        stopPresencePolling()
    }

    // MARK: - Presence

    // Intentionally a no-op: polling the relay for presence would tell it whose
    // status we watch.
    private func startPresencePolling(peer: String) {}
    private func stopPresencePolling() {}

    func postMentionNotification(body: String, senderAccount: String, conversationId: String) {
        // The same rules as the notification extension: nothing for a hidden
        // chat or a request, and no text where previews are off, a Face ID
        // lock is set or messages disappear.
        guard !PanicModeManager.shared.isHidden(conversationId),
              let conv = conversations.first(where: { $0.id == conversationId }), !conv.isRequest
        else { return }
        let content = UNMutableNotificationContent()
        let preview = NotificationPreviewSetting.current
        let textAllowed = preview.showsContent && !conv.hidePreviews && !conv.requireBiometricChat && conv.disappearingSeconds == 0
        content.title = "You were mentioned"
        content.body = textAllowed ? body
            : (preview.showsSenderName ? "by \(displayName(forAccount: senderAccount))" : "")
        content.sound = .default
        let id = "mention-\(senderAccount)-\(Int64(Date().timeIntervalSince1970 * 1000))"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        )
    }

    func markVisibleMessagesRead(in conversationId: String) async {
        guard let messages = try? storage.messages.messages(in: conversationId) else { return }
        let unread = messages.filter { !$0.isOutgoing && $0.status == .received }
        // Mark read locally first and unconditionally. The badge uses read_at,
        // which can disagree with per-message status, and a slow or interrupted
        // receipt send must not leave the chat unread.
        for message in unread {
            try? storage.messages.updateStatus(messageId: message.id, status: .read)
        }
        try? storage.messages.markConversationRead(conversationId)
        refreshConversations()

        // System lines and the Relay chat have nobody to receipt.
        let receiptable = unread.filter { $0.senderAccount != Self.systemSender }
        let peer = try? peerAccount(for: conversationId)
        let hasRealPeer = peer != relayOfficialAccount && peer != noteToSelfAccount
        guard sendReadReceipts, hasRealPeer, !receiptable.isEmpty else { return }
        if let group = group(for: conversationId) {
            let byAuthor = Dictionary(grouping: receiptable) { $0.senderAccount ?? "" }
            for (author, msgs) in byAuthor where !author.isEmpty && author != credentials.accountId {
                await sendReceipt(.read, timestamps: msgs.map(\.timestamp), toPeer: author, groupId: group.id)
            }
        } else if let peer {
            await sendReceipt(.read, timestamps: receiptable.map(\.timestamp), toPeer: peer)
        }
    }

    /// Messages the NSE stored while backgrounded are now on screen.
    func markActiveConversationReadOnForeground() {
        guard let conversationId = activeConversationId else { return }
        Task { await markVisibleMessagesRead(in: conversationId) }
    }

    func markConversationRead(_ conversationId: String) {
        do {
            try storage.messages.markConversationRead(conversationId)
            refreshConversations()
        } catch {
            log.error("mark conversation read failed: \(PrivacyRedactor.error(error))")
        }
    }

    func markConversationUnread(_ conversationId: String) {
        do {
            try storage.messages.markConversationUnread(conversationId)
            refreshConversations()
        } catch {
            log.error("mark conversation unread failed: \(PrivacyRedactor.error(error))")
        }
    }

    func setConversationPinned(_ conversationId: String, pinned: Bool) {
        do {
            try storage.messages.setConversationPinned(conversationId, pinned: pinned)
            refreshConversations()
        } catch {
            log.error("set pinned failed: \(PrivacyRedactor.error(error))")
        }
    }

    func setConversationLabel(_ conversationId: String, label: String?) {
        try? storage.messages.setConversationLabel(conversationId, label: label)
        refreshConversations()
    }

    func isConversationMuted(_ id: String) -> Bool {
        guard let expiry = muteExpiries[id] else { return false }
        if expiry == Int64.max { return true }
        return expiry > Int64(Date().timeIntervalSince1970 * 1000)
    }

    // seconds: 0 = unmute, -1 = forever, >0 = duration from now
    func setConversationMuted(_ id: String, muted: Bool) {
        setMuteDuration(id, seconds: muted ? -1 : 0)
    }

    func setMuteDuration(_ id: String, seconds: Int64) {
        if seconds == 0 {
            muteExpiries.removeValue(forKey: id)
        } else if seconds < 0 {
            muteExpiries[id] = Int64.max
        } else {
            muteExpiries[id] = Int64(Date().timeIntervalSince1970 * 1000) + seconds * 1000
        }
        saveMuteExpiries()
    }

    func muteLabel(for id: String) -> String {
        guard let expiry = muteExpiries[id] else { return "Mute" }
        if expiry == Int64.max { return "Muted (forever)" }
        let remaining = expiry - Int64(Date().timeIntervalSince1970 * 1000)
        guard remaining > 0 else { return "Mute" }
        let hours = remaining / 3_600_000
        if hours < 1 { return "Muted (<1h)" }
        if hours < 24 { return "Muted (\(hours)h)" }
        return "Muted (\(hours / 24)d)"
    }

    func loadMuteExpiries() {
        let ud = UserDefaults(suiteName: AppModel.appGroupId)
        // Migrate the old boolean mute set to forever entries.
        if let old = ud?.stringArray(forKey: "relay.mutedConversationIds"), !old.isEmpty {
            for id in old { muteExpiries[id] = Int64.max }
            ud?.removeObject(forKey: "relay.mutedConversationIds")
            saveMuteExpiries()
            return
        }
        if let data = ud?.data(forKey: "relay.muteExpiries"),
           let decoded = try? JSONDecoder().decode([String: Int64].self, from: data) {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            muteExpiries = decoded.filter { $0.value == Int64.max || $0.value > now }
        }
    }

    func saveMuteExpiries() {
        if let data = try? JSONEncoder().encode(muteExpiries) {
            UserDefaults(suiteName: AppModel.appGroupId)?.set(data, forKey: "relay.muteExpiries")
        }
    }

    var sendReadReceipts: Bool {
        get { UserDefaults.standard.object(forKey: "relay.sendReadReceipts") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "relay.sendReadReceipts") }
    }

    var hideLastSeen: Bool {
        get { UserDefaults.standard.bool(forKey: "relay.hideLastSeen") }
        set { UserDefaults.standard.set(newValue, forKey: "relay.hideLastSeen") }
    }

    /// Holds outbound messages for a short random delay so observers can't tie
    /// a send to the moment the user tapped Send.
    var sendJitterEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "relay.sendJitter") }
        set { UserDefaults.standard.set(newValue, forKey: "relay.sendJitter") }
    }

    /// Sends via the unauthenticated `/v1/messages/sealed` endpoint; the sender
    /// identity travels inside the encrypted blob with a relay-minted certificate.
    var sealedSenderEnabled: Bool {
        // Mandatory and not user-configurable.
        get { true }
        set { }
    }

    /// Opt-in ciphertext-in-push. Off by default, so pushes are a content-free
    /// wake and APNs carries no message data. When on, the relay embeds the
    /// encrypted envelope to skip a fetch. Mirrored to the server per device.
    var pushIncludeContent: Bool {
        get { UserDefaults.standard.bool(forKey: "relay.pushIncludeContent") }
        set {
            UserDefaults.standard.set(newValue, forKey: "relay.pushIncludeContent")
            Task { try? await self.api.setPushIncludeContent(newValue) }
        }
    }

    /// Call after a username change: the certificate carries the username.
    func invalidateSenderCertificate() {
        cachedSenderCert = nil
    }

    func senderCertificate() async throws -> Data {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if let cert = cachedSenderCert, cert.expiresAt - nowMs > 86_400_000 {
            return cert.data
        }
        let fetched = try await api.deliveryCertificate()
        cachedSenderCert = (fetched.certificate, fetched.expiresAt)
        return fetched.certificate
    }

    /// Up to ~5s when send jitter is enabled.
    func applySendJitter() async {
        guard sendJitterEnabled else { return }
        let delayMs = UInt64.random(in: 500...5000)
        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
    }

    func starMessage(_ messageId: String, starred: Bool, in conversationId: String) {
        do {
            try storage.messages.setMessageStarred(id: messageId, starred: starred)
            refreshActiveMessages(ifShowing: conversationId)
        } catch {
            log.error("star message failed: \(PrivacyRedactor.error(error))")
        }
    }

    func starredMessages(for conversationId: String) -> [StoredMessage] {
        (try? storage.messages.starredMessages(in: conversationId)) ?? []
    }

    func deleteConversation(_ conversationId: String) {
        if activeConversationId == conversationId { closeConversation(id: conversationId) }
        LocationShareManager.shared.stop(in: conversationId)
        do {
            try storage.messages.deleteConversation(id: conversationId)
            sweepAttachmentFiles()
            refreshConversations()
        } catch {
            log.error("delete conversation failed: \(PrivacyRedactor.error(error))")
        }
    }

    func setDisappearingSeconds(_ conversationId: String, seconds: Int64) {
        let previous = conversations.first(where: { $0.id == conversationId })?.disappearingSeconds ?? 0
        do {
            try storage.messages.setDisappearingSeconds(conversationId, seconds: seconds)
            if seconds != previous {
                // The timer travels with each message, so note the change in the thread.
                let text = seconds == 0
                    ? "You turned off disappearing messages"
                    : "You set disappearing messages to \(Self.durationLabel(seconds))"
                insertSystemLine(text, conversationId: conversationId)
            }
            refreshConversations()
        } catch {
            log.error("set disappearing messages failed: \(PrivacyRedactor.error(error))")
        }
    }

    private static func durationLabel(_ seconds: Int64) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.weekOfMonth, .day, .hour, .minute, .second]
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) seconds"
    }

    func setConversationPrivacy(
        _ conversationId: String,
        mediaRequiresBiometric: Bool,
        requireBiometricChat: Bool,
        hidePreviews: Bool
    ) {
        do {
            try storage.messages.setConversationPrivacy(
                conversationId,
                mediaRequiresBiometric: mediaRequiresBiometric,
                requireBiometricChat: requireBiometricChat,
                hidePreviews: hidePreviews
            )
            refreshConversations()
        } catch {
            log.error("set conversation privacy failed: \(PrivacyRedactor.error(error))")
        }
    }
}
