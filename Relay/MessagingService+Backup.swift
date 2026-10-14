//
//  MessagingService+Backup.swift
//  Relay
//
//  The local backup snapshot.
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
    // MARK: - Backup snapshot

    /// Local chat state; CloudBackupManager encrypts it before it leaves the device.
    struct BackupSnapshot: Codable {
        struct Message: Codable {
            let id: String
            let body: String
            let timestamp: Int64
            let isOutgoing: Bool
            let status: String
            let senderAccount: String?
            let replyTimestamp: Int64?
            let replyAuthor: String?
            let replyText: String?
        }
        struct Conversation: Codable {
            let peerAccount: String
            let username: String?
            let groupId: String?
            let messages: [Message]
            /// Nil in older backups (treated as accepted).
            var accepted: Bool?
            var disappearingSeconds: Int64?
            var mediaRequiresBiometric: Bool?
            var requireBiometricChat: Bool?
            var hidePreviews: Bool?
        }
        struct Group: Codable {
            let id: String
            let name: String
            let distributionId: String
            let revision: Int64
            let members: [String]
            let admins: [String]
            let isAnnounceOnly: Bool
        }
        var version: Int = 1
        var conversations: [Conversation]
        var groups: [Group]
    }

    /// Leaves out what the user expects not to outlive this device: chats
    /// hidden by Panic Mode, disappearing messages and view-once media.
    func exportBackupSnapshot() -> BackupSnapshot {
        var convs: [BackupSnapshot.Conversation] = []
        var groups: [BackupSnapshot.Group] = []
        let hidden = PanicModeManager.hiddenConversationIdsSnapshot()
        for conv in (try? storage.messages.conversations()) ?? [] where !hidden.contains(conv.id) {
            let expiring = Set(((try? storage.database.query(
                "SELECT id FROM messages WHERE conversation_id = ? AND expires_at IS NOT NULL", [.text(conv.id)]
            )) ?? []).compactMap { $0.first?.string })
            let kept = ((try? storage.messages.messages(in: conv.id, limit: 100_000)) ?? []).filter {
                !expiring.contains($0.id) && !$0.body.hasPrefix("~once~") && !$0.isDeleted
            }
            let msgs = kept.map { m in
                BackupSnapshot.Message(
                    id: m.id, body: m.body, timestamp: m.timestamp,
                    isOutgoing: m.isOutgoing, status: m.status.rawValue, senderAccount: m.senderAccount,
                    replyTimestamp: m.replyTo?.targetTimestamp,
                    replyAuthor: m.replyTo?.author, replyText: m.replyTo?.text
                )
            }
            convs.append(BackupSnapshot.Conversation(
                peerAccount: conv.peerAccount, username: conv.peerUsername,
                groupId: conv.groupId, messages: msgs,
                accepted: conv.accepted, disappearingSeconds: conv.disappearingSeconds,
                mediaRequiresBiometric: conv.mediaRequiresBiometric,
                requireBiometricChat: conv.requireBiometricChat, hidePreviews: conv.hidePreviews
            ))
            if let gid = conv.groupId, let g = try? storage.messages.group(id: gid) {
                groups.append(BackupSnapshot.Group(
                    id: g.id, name: g.name, distributionId: g.distributionId, revision: g.revision,
                    members: g.members, admins: g.admins, isAnnounceOnly: g.isAnnounceOnly
                ))
            }
        }
        return BackupSnapshot(conversations: convs, groups: groups)
    }

    /// Idempotent: existing message ids are skipped.
    func importBackupSnapshot(_ snapshot: BackupSnapshot) {
        for g in snapshot.groups {
            try? storage.messages.upsertGroup(
                id: g.id, name: g.name, distributionId: g.distributionId, revision: g.revision,
                members: g.members, admins: g.admins, isAnnounceOnly: g.isAnnounceOnly
            )
        }
        for c in snapshot.conversations {
            let convId: String
            if let gid = c.groupId {
                // The group was upserted above; never create it via the
                // 1:1-only conversation(withPeer:).
                convId = ((try? storage.messages.groupConversationId(groupId: gid)) ?? nil) ?? ""
            } else {
                convId = (try? storage.messages.conversation(
                    withPeer: c.peerAccount, username: c.username, accepted: c.accepted ?? true)) ?? ""
            }
            guard !convId.isEmpty else { continue }
            // The restored chat keeps its request state and locks.
            if c.accepted == false { try? storage.messages.setConversationAccepted(convId, accepted: false) }
            if c.mediaRequiresBiometric != nil || c.requireBiometricChat != nil || c.hidePreviews != nil {
                try? storage.messages.setConversationPrivacy(
                    convId,
                    mediaRequiresBiometric: c.mediaRequiresBiometric ?? false,
                    requireBiometricChat: c.requireBiometricChat ?? false,
                    hidePreviews: c.hidePreviews ?? false
                )
            }
            for m in c.messages {
                let replyTo = m.replyTimestamp.map {
                    QuotedMessage(targetTimestamp: $0, author: m.replyAuthor ?? "", text: m.replyText ?? "")
                }
                _ = try? storage.messages.insertMessage(
                    id: m.id, conversationId: convId, isOutgoing: m.isOutgoing,
                    body: m.body, timestamp: m.timestamp,
                    status: MessageStatus(rawValue: m.status) ?? .received,
                    replyTo: replyTo, senderAccount: m.senderAccount
                )
            }
            // After the inserts: restored messages predate the timer and must
            // not start expiring now.
            if let secs = c.disappearingSeconds, secs > 0 {
                try? storage.messages.setDisappearingSeconds(convId, seconds: secs)
            }
            try? storage.messages.markConversationRead(convId)
        }
        refreshConversations()
    }

    /// Empty conversations for a newly linked device's synced chat list.
    func importConversationStubs(_ peers: [(account: String, username: String?)]) {
        for (account, uname) in peers {
            guard !account.isEmpty else { continue }
            _ = try? storage.messages.conversation(withPeer: account, username: uname)
        }
        refreshConversations()
    }

    func listLinkedDevices() async throws -> [RelayKit.LinkedDevice] {
        try await api.listDevices()
    }
}
