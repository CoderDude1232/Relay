//
//  MessagingService+Privacy.swift
//  Relay
//
//  Screenshot protection and the block list.
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
    // MARK: - Screenshot protection

    /// Groups use the admin-set flag; DMs hide if either side asks to.
    func effectiveScreenHidden(_ conversationId: String) -> Bool {
        if let group = group(for: conversationId) { return group.screenSecurity }
        guard let conv = conversations.first(where: { $0.id == conversationId }) else { return true }
        if conv.peerAccount == noteToSelfAccount || conv.peerAccount == relayOfficialAccount { return false }
        return conv.screenSecurity || conv.peerScreenSecurity
    }

    func myScreenSecurityPref(_ conversationId: String) -> Bool {
        conversations.first { $0.id == conversationId }?.screenSecurity ?? true
    }

    /// Synced to the peer so both sides agree on the effective state.
    func setScreenSecurity(_ enabled: Bool, conversationId: String) {
        guard let conv = conversations.first(where: { $0.id == conversationId }), !conv.isGroup else { return }
        try? storage.messages.setConversationScreenSecurity(conversationId, enabled: enabled)
        refreshConversations()
        let peer = conv.peerAccount
        guard !peer.isEmpty else { return }
        Task {
            var content = Relay_Content_Content()
            content.screenSecurityUpdate.enabled = enabled
            content.screenSecurityUpdate.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            content.senderAccountID = credentials.accountId
            content.senderDeviceID = credentials.deviceId
            if let data = try? content.serializedData() {
                try? await sendContent(data, toPeer: peer, clientTimestamp: Int64(Date().timeIntervalSince1970 * 1000))
            }
        }
    }

    /// Admin-only.
    func setGroupScreenSecurity(_ enabled: Bool, conversationId: String) async throws {
        guard let group = group(for: conversationId) else { throw GroupError.notFound }
        try requireGroupAdmin(group)
        try storage.messages.setGroupScreenSecurity(id: group.id, enabled: enabled)
        guard let grp = try? storage.messages.group(id: group.id) else { return }
        var update = Relay_Content_GroupUpdate()
        update.action = .setScreenSecurity
        update.screenSecurity = enabled
        await sendGroupUpdateCustom(update, group: grp)
        let line = enabled ? "You turned on screenshot protection" : "You turned off screenshot protection"
        insertSystemLine(line, inGroup: group.id)
        refreshConversations()
    }

    /// Sent regardless of the hide setting.
    func sendScreenshotAlert(conversationId: String) {
        guard let conv = conversations.first(where: { $0.id == conversationId }) else { return }
        if conv.peerAccount == noteToSelfAccount || conv.peerAccount == relayOfficialAccount { return }
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        var content = Relay_Content_Content()
        content.screenshot.timestamp = ts
        content.senderAccountID = credentials.accountId
        content.senderDeviceID = credentials.deviceId

        let recipients: [String]
        if let group = group(for: conversationId) {
            content.groupID = group.id
            recipients = group.members.filter { $0 != credentials.accountId && !isBlocked($0) }
        } else {
            recipients = conv.peerAccount.isEmpty || isBlocked(conv.peerAccount) ? [] : [conv.peerAccount]
        }
        guard let data = try? content.serializedData() else { return }
        Task {
            for peer in recipients {
                try? await sendContent(data, toPeer: peer, clientTimestamp: ts)
            }
        }
        insertSystemLine("You took a screenshot", conversationId: conversationId)
    }

    func setNotificationSound(_ conversationId: String, sound: String?) {
        try? storage.messages.setNotificationSound(conversationId, sound: sound)
        refreshConversations()
    }

    func notificationSound(for conversationId: String) -> String? {
        conversations.first { $0.id == conversationId }?.notificationSound
    }

    func isScreenSecure(_ conversationId: String) -> Bool {
        conversations.first { $0.id == conversationId }?.screenSecurity ?? false
    }

    func deleteViewOnceAttachment(_ attachment: StoredAttachment, in conversationId: String) {
        attachmentStore.delete(attachment.id)
        // Dropping the row discards the pointer and key, so the blob can't be
        // re-fetched and the bubble shows "Opened".
        try? storage.database.run("DELETE FROM attachments WHERE id = ?", [.text(attachment.id)])
        refreshActiveMessages(ifShowing: conversationId)
    }

    func setConversationArchived(_ conversationId: String, archived: Bool) {
        do {
            try storage.messages.setConversationArchived(conversationId, archived: archived)
            refreshConversations()
        } catch {
            log.error("set archived failed: \(PrivacyRedactor.error(error))")
        }
    }


    // MARK: - Block list

    func isBlocked(_ account: String) -> Bool {
        blockedAccounts.contains(account)
    }

    /// For ConversationListView's multi-select toolbar.
    func bulkArchive(_ ids: Set<String>) {
        for id in ids { try? storage.messages.setConversationArchived(id, archived: true) }
        refreshConversations()
    }

    func bulkDelete(_ ids: Set<String>) {
        // The same path as one delete: stop live location, close the chat and
        // remove the cached attachment files too.
        for id in ids { deleteConversation(id) }
    }

    func bulkMarkRead(_ ids: Set<String>) {
        for id in ids { try? storage.messages.markConversationRead(id) }
        refreshConversations()
    }

    func bulkMute(_ ids: Set<String>) {
        for id in ids { muteExpiries[id] = Int64.max }
        saveMuteExpiries()
    }

    func blockAccount(_ account: String) {
        if let convId = conversations.first(where: { !$0.isGroup && $0.peerAccount == account })?.id {
            LocationShareManager.shared.stop(in: convId)
        }
        blockedAccounts.insert(account)
        saveBlockedAccounts()
        refreshConversations()
    }

    func unblockAccount(_ account: String) {
        blockedAccounts.remove(account)
        saveBlockedAccounts()
        refreshConversations()
    }

    func loadBlockedAccounts() {
        guard let data = (try? storage.database.query(
            "SELECT value FROM kv WHERE key = 'relay.blockedAccounts'"
        ).first?.first?.data) ?? nil,
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        blockedAccounts = Set(list)
    }

    private func saveBlockedAccounts() {
        guard let data = try? JSONEncoder().encode(Array(blockedAccounts)) else { return }
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES ('relay.blockedAccounts', ?)",
            [.blob(data)]
        )
    }
}
