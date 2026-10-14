//
//  MessagingService+MessageActions.swift
//  Relay
//
//  Polls, pinned messages, reactions and deleting messages.
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
    // MARK: - Polls

    func sendPoll(question: String, options: [String], multiSelect: Bool, in conversationId: String) async {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let localId = UUID().uuidString
        var poll = Relay_Content_PollMessage()
        poll.question = question
        poll.options = options
        poll.multiSelect = multiSelect
        poll.timestamp = timestamp
        var content = Relay_Content_Content()
        content.poll = poll
        content.senderAccountID = credentials.accountId
        content.senderDeviceID = credentials.deviceId
        refreshActiveMessages(ifShowing: conversationId)
        do {
            let pollPayload = PollPayload(question: question, options: options, multiSelect: multiSelect)
            let pollBody = "__poll__:" + (pollPayload.encode() ?? question)
            try storage.messages.insertMessage(
                id: localId, conversationId: conversationId, isOutgoing: true,
                body: pollBody, timestamp: timestamp, status: .sending
            )
            guard let data = try? content.serializedData() else { return }
            let targets = pollTargets(for: conversationId, content: &content)
            for peer in targets {
                try await sendContent(data, toPeer: peer, clientTimestamp: timestamp)
            }
            try? storage.messages.updateStatus(messageId: localId, status: .sent)
        } catch {
            log.warning("poll send failed: \(PrivacyRedactor.error(error))")
            try? storage.messages.updateStatus(messageId: localId, status: .failed)
        }
    }

    func sendPollVote(pollAuthor: String, pollTimestamp: Int64, selectedOptions: [Int], in conversationId: String) async {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        try? storage.messages.upsertPollVote(
            conversationId: conversationId, pollAuthor: pollAuthor, pollTimestamp: pollTimestamp,
            voterAccount: credentials.accountId, selectedOptions: selectedOptions, votedAt: timestamp
        )
        refreshActiveMessages(ifShowing: conversationId)
        var vote = Relay_Content_PollVote()
        vote.pollAuthor = pollAuthor
        vote.pollTimestamp = pollTimestamp
        vote.selectedOptions = selectedOptions.map { UInt32($0) }
        vote.timestamp = timestamp
        var content = Relay_Content_Content()
        content.pollVote = vote
        content.senderAccountID = credentials.accountId
        content.senderDeviceID = credentials.deviceId
        guard let data = try? content.serializedData() else { return }
        let targets = pollTargets(for: conversationId, content: &content)
        for peer in targets {
            try? await sendContent(data, toPeer: peer, clientTimestamp: timestamp)
        }
    }

    private func pollTargets(for conversationId: String, content: inout Relay_Content_Content) -> [String] {
        if let grp = group(for: conversationId) {
            content.groupID = grp.id
            return grp.members.filter { $0 != credentials.accountId }
        }
        if let peer = try? peerAccount(for: conversationId) {
            return [peer]
        }
        return []
    }

    func pollVotes(conversationId: String, pollAuthor: String, pollTimestamp: Int64) -> [StoredPollVote] {
        (try? storage.messages.pollVotes(conversationId: conversationId, pollAuthor: pollAuthor, pollTimestamp: pollTimestamp)) ?? []
    }

    func loadStringArray(_ key: String) -> [String] {
        guard let data = try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text(key)]
        ).first?.first?.data else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func saveStringArray(_ key: String, _ value: [String]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [.text(key), .blob(data)]
        )
    }

    /// Invite capability for link self-joins, stored in kv.
    func groupInviteKey(_ groupId: String) -> Data? {
        try? storage.database.query(
            "SELECT value FROM kv WHERE key = ?", [.text("ginvkey:\(groupId)")]
        ).first?.first?.data
    }

    func setGroupInviteKey(_ groupId: String, _ key: Data) {
        try? storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text("ginvkey:\(groupId)"), .blob(key)]
        )
    }

    // MARK: - Pinned messages

    func pinMessage(_ messageId: String, pinned: Bool, in conversationId: String) {
        do {
            try storage.messages.setMessagePinned(id: messageId, pinned: pinned)
            refreshConversations()
            refreshActiveMessages(ifShowing: conversationId)
        } catch {
            log.error("pin message failed: \(PrivacyRedactor.error(error))")
        }
    }

    func pinnedMessage(for conversationId: String) -> StoredMessage? {
        try? storage.messages.pinnedMessage(in: conversationId)
    }

    // MARK: - Reactions

    /// Sends a control message to the 1:1 peer or every other group member.
    /// Non-ephemeral content is mirrored to our own devices.
    func sendToConversation(
        _ content: Relay_Content_Content, conversationId: String,
        timestamp: Int64, ephemeral: Bool = false
    ) async {
        var content = content
        let recipients: [String]
        let syncPeer: String
        if let group = group(for: conversationId) {
            content.groupID = group.id
            recipients = group.members.filter { $0 != credentials.accountId && !isBlocked($0) }
            syncPeer = group.id
        } else if let peer = resolvedPeerAccount(for: conversationId),
                  peer != noteToSelfAccount, peer != relayOfficialAccount,
                  !(ephemeral && isBlocked(peer)) {
            recipients = [peer]
            syncPeer = peer
        } else {
            return
        }
        guard let data = try? content.serializedData() else { return }
        for recipient in recipients {
            do {
                try await sendContent(data, toPeer: recipient, clientTimestamp: timestamp, ephemeral: ephemeral)
            } catch {
                log.debug("control send skipped: \(PrivacyRedactor.error(error))")
            }
        }
        if !ephemeral {
            await sendSyncToOwnDevices(content: content, peer: syncPeer, timestamp: timestamp)
        }
    }

    func toggleReaction(_ emoji: String, on message: StoredMessage) {
        let conversationId = message.conversationId
        guard let peer = resolvedPeerAccount(for: conversationId) else { return }
        // In a group the conversation's peer is the group id, not the author.
        let targetAuthor = message.isOutgoing ? credentials.accountId : (message.senderAccount ?? peer)
        let remove = message.reactions.first(where: \.isOutgoing)?.emoji == emoji

        do {
            try storage.messages.setReaction(
                conversationId: conversationId,
                targetTimestamp: message.timestamp,
                author: credentials.accountId,
                isOutgoing: true,
                emoji: emoji,
                remove: remove
            )
            refreshActiveMessages(ifShowing: conversationId)
        } catch {
            log.error("store reaction failed: \(PrivacyRedactor.error(error))")
        }

        Task {
            var content = Relay_Content_Content()
            content.reaction.emoji = emoji
            content.reaction.targetAuthor = targetAuthor
            content.reaction.targetTimestamp = message.timestamp
            content.reaction.remove = remove
            content.reaction.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            await sendToConversation(content, conversationId: conversationId, timestamp: content.reaction.timestamp)
        }
    }

    // MARK: - Delete

    /// This device only; no tombstone is sent.
    func deleteMessage(_ messageId: String, in conversationId: String) {
        do {
            reapAttachmentBlobs(messageId: messageId)
            try storage.messages.deleteMessage(id: messageId)
            refreshConversations()
            refreshActiveMessages(ifShowing: conversationId)
        } catch {
            log.error("delete message failed: \(PrivacyRedactor.error(error))")
        }
    }

    /// Blob files live in the App Group container; the DB tracks only metadata.
    /// Removes ciphertext files whose messages are gone (expired, deleted
    /// chats). Rows are the source of truth; see `AttachmentBlobStore`.
    func sweepAttachmentFiles() {
        // A failed query must skip the sweep: an empty keep-list would delete
        // every cached file, including unsent ones.
        guard let rows = try? storage.database.query("SELECT id FROM attachments") else { return }
        attachmentStore.sweepOrphans(keeping: Set(rows.compactMap { $0.first?.string }))
    }

    private func reapAttachmentBlobs(messageId: String) {
        let ids = (try? storage.database.query(
            "SELECT id FROM attachments WHERE message_id = ?", [.text(messageId)]
        )) ?? []
        for row in ids {
            if let id = row.first?.string { attachmentStore.delete(id) }
        }
    }

    static let unsendWindow: TimeInterval = 24 * 60 * 60

    /// Own, non-deleted messages within the unsend window.
    func canUnsend(_ message: StoredMessage) -> Bool {
        guard message.isOutgoing, !message.isDeleted else { return false }
        let sentAt = Date(timeIntervalSince1970: Double(message.timestamp) / 1000)
        return Date().timeIntervalSince(sentAt) < Self.unsendWindow
    }

    /// Leaves a tombstone locally and on the peer. Queued like a normal message
    /// so it reaches an offline peer.
    func unsend(_ message: StoredMessage) {
        let conversationId = message.conversationId
        guard canUnsend(message) else { return }
        do {
            reapAttachmentBlobs(messageId: message.id)
            try storage.messages.markDeleted(id: message.id)
            refreshConversations()
            refreshActiveMessages(ifShowing: conversationId)
        } catch {
            log.error("local unsend failed: \(PrivacyRedactor.error(error))")
        }
        Task {
            var content = Relay_Content_Content()
            content.delete.targetTimestamp = message.timestamp
            content.delete.targetAuthor = credentials.accountId
            let ts = Int64(Date().timeIntervalSince1970 * 1000)
            await sendToConversation(content, conversationId: conversationId, timestamp: ts)
        }
    }

    func editMessage(_ message: StoredMessage, newBody: String) {
        let conversationId = message.conversationId
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try storage.messages.editMessage(id: message.id, newBody: newBody)
            refreshConversations()
            refreshActiveMessages(ifShowing: conversationId)
        } catch {
            log.error("local message edit failed: \(PrivacyRedactor.error(error))")
            return
        }
        Task {
            var content = Relay_Content_Content()
            content.edit.targetTimestamp = message.timestamp
            content.edit.newBody = newBody
            await sendToConversation(content, conversationId: conversationId, timestamp: now)
        }
    }
}
