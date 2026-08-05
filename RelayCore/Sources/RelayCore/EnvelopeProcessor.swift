//
//  EnvelopeProcessor.swift
//  RelayCore
//
//  The single, shared incoming pipeline. Both the app (over the WebSocket)
//  and the Notification Service Extension (from the push payload) run an
//  envelope through here: it claims the envelope exactly once, decrypts it
//  (advancing the Double Ratchet / applying sender keys in the shared store),
//  applies the content, and returns what happened. Network side-effects
//  (receipts, username lookups, group re-sync) are *returned* rather than
//  performed, so the NSE can ignore them.
//

import CryptoCore
import Foundation
import LibSignalClient
import RelayKit
import SecureStorage
import SwiftProtobuf

/// Actions the caller may perform after processing. The NSE ignores these.
public struct EnvelopeSideEffects: Sendable {
    public var deliveryReceiptTimestamp: Int64?
    public var backfillUsernameForAccount: String?

    public init(deliveryReceiptTimestamp: Int64? = nil, backfillUsernameForAccount: String? = nil) {
        self.deliveryReceiptTimestamp = deliveryReceiptTimestamp
        self.backfillUsernameForAccount = backfillUsernameForAccount
    }
}

/// A user-visible message worth surfacing as a notification.
public struct NotificationContent: Sendable {
    public let senderAccount: String
    public let conversationId: String
    public let body: String
}

public enum GroupAction: Sendable {
    case create, add, remove, leave, rename, unknown
}

/// A group membership/metadata change; the caller re-syncs the roster from
/// the relay and inserts a system line.
public struct GroupUpdateInfo: Sendable {
    public let groupId: String
    public let action: GroupAction
    public let actor: String
    public let target: String
    public let name: String
}

/// A peer's self-set profile. The caller stores it (and downloads the avatar
/// blob, if any) — kept out of the processor so it stays network-free.
public struct ProfileInfo: Sendable {
    public struct Avatar: Sendable {
        public let id: String
        public let key: Data
        public let digest: Data
    }
    public let account: String
    public let displayName: String
    public let avatar: Avatar?
    public let revision: Int64
}

public struct ProcessedEnvelope: Sendable {
    public enum Outcome: Sendable {
        case stored, applied, duplicate, ignored
    }

    public let outcome: Outcome
    public let peerAccount: String?
    public let conversationId: String?
    public let notification: NotificationContent?
    public let sideEffects: EnvelopeSideEffects
    public let typingStarted: Bool?
    public let groupUpdate: GroupUpdateInfo?
    public let profile: ProfileInfo?

    public init(
        outcome: Outcome,
        peerAccount: String? = nil,
        conversationId: String? = nil,
        notification: NotificationContent? = nil,
        sideEffects: EnvelopeSideEffects = EnvelopeSideEffects(),
        typingStarted: Bool? = nil,
        groupUpdate: GroupUpdateInfo? = nil,
        profile: ProfileInfo? = nil
    ) {
        self.outcome = outcome
        self.peerAccount = peerAccount
        self.conversationId = conversationId
        self.notification = notification
        self.sideEffects = sideEffects
        self.typingStarted = typingStarted
        self.groupUpdate = groupUpdate
        self.profile = profile
    }
}

public struct EnvelopeProcessor {
    private let storage: SecureStore
    private let engine: CryptoEngine

    public init(storage: SecureStore, engine: CryptoEngine) {
        self.storage = storage
        self.engine = engine
    }

    public func process(_ envelope: IncomingEnvelope) throws -> ProcessedEnvelope {
        guard try storage.messages.claimEnvelope(id: envelope.id) else {
            return ProcessedEnvelope(outcome: .duplicate, peerAccount: envelope.senderAccount)
        }

        let sender = try ProtocolAddress(name: envelope.senderAccount, deviceId: envelope.senderDevice)
        let plaintext = try engine.decrypt(envelope.message, from: sender)
        let content = try Relay_Content_Content(serializedBytes: plaintext)
        let groupId = content.groupID.isEmpty ? nil : content.groupID

        // A chat message lands in the group conversation (keyed by group id)
        // or the 1:1 conversation with the sender.
        func chatConversation() throws -> String {
            try storage.messages.conversation(withPeer: groupId ?? envelope.senderAccount)
        }

        switch content.body {
        case .text(let text):
            let conversationId = try chatConversation()
            let quote: QuotedMessage? = text.hasQuote
                ? QuotedMessage(targetTimestamp: text.quote.targetTimestamp, author: text.quote.author, text: text.quote.text)
                : nil
            let attachments = text.attachments.map { p in
                StoredAttachment(
                    id: p.id, key: p.key, digest: p.digest, contentType: p.contentType,
                    size: Int64(p.size), filename: p.filename.isEmpty ? nil : p.filename,
                    width: Int(p.width), height: Int(p.height), isDownloaded: false
                )
            }
            let inserted = try storage.messages.insertMessage(
                id: envelope.id, conversationId: conversationId, isOutgoing: false,
                body: text.body, timestamp: text.timestamp, status: .received,
                replyTo: quote, attachments: attachments,
                senderAccount: groupId == nil ? nil : envelope.senderAccount
            )
            var effects = EnvelopeSideEffects()
            if inserted, groupId == nil {
                // Group delivery receipts to every member are noisy; 1:1 only.
                effects.deliveryReceiptTimestamp = text.timestamp
            }
            if groupId == nil, !hasUsername(conversationId: conversationId) {
                effects.backfillUsernameForAccount = envelope.senderAccount
            }
            let preview = text.body.isEmpty && !attachments.isEmpty ? "📷 Photo" : text.body
            return ProcessedEnvelope(
                outcome: inserted ? .stored : .duplicate,
                peerAccount: envelope.senderAccount,
                conversationId: conversationId,
                notification: inserted
                    ? NotificationContent(senderAccount: envelope.senderAccount, conversationId: conversationId, body: preview)
                    : nil,
                sideEffects: effects
            )

        case .reaction(let reaction):
            let conversationId = try chatConversation()
            try storage.messages.setReaction(
                conversationId: conversationId, targetTimestamp: reaction.targetTimestamp,
                author: envelope.senderAccount, isOutgoing: false,
                emoji: reaction.emoji, remove: reaction.remove
            )
            return ProcessedEnvelope(
                outcome: .applied, peerAccount: envelope.senderAccount, conversationId: conversationId,
                notification: reaction.remove ? nil
                    : NotificationContent(senderAccount: envelope.senderAccount, conversationId: conversationId, body: "Reacted \(reaction.emoji)")
            )

        case .receipt(let receipt):
            let conversationId = try chatConversation()
            try storage.messages.applyReceipt(
                conversationId: conversationId, timestamps: receipt.messageTimestamps,
                status: receipt.type == .read ? .read : .delivered
            )
            return ProcessedEnvelope(outcome: .applied, peerAccount: envelope.senderAccount, conversationId: conversationId)

        case .delete(let deletion):
            let conversationId = try chatConversation()
            try storage.messages.markDeleted(conversationId: conversationId, targetTimestamp: deletion.targetTimestamp)
            return ProcessedEnvelope(outcome: .applied, peerAccount: envelope.senderAccount, conversationId: conversationId)

        case .senderKeyDistribution(let skd):
            // Store the sender's group sender key so their .senderKey group
            // messages decrypt from here on.
            try engine.processSenderKeyDistribution(skd.data, from: sender)
            return ProcessedEnvelope(outcome: .applied, peerAccount: envelope.senderAccount)

        case .groupUpdate(let update):
            let info = GroupUpdateInfo(
                groupId: content.groupID,
                action: Self.action(update.action),
                actor: update.actor,
                target: update.target,
                name: update.name
            )
            return ProcessedEnvelope(outcome: .applied, peerAccount: envelope.senderAccount, groupUpdate: info)

        case .profile(let profile):
            let avatar: ProfileInfo.Avatar? = profile.hasAvatar
                ? ProfileInfo.Avatar(id: profile.avatar.id, key: profile.avatar.key, digest: profile.avatar.digest)
                : nil
            let info = ProfileInfo(
                account: envelope.senderAccount,
                displayName: profile.displayName,
                avatar: avatar,
                revision: profile.timestamp
            )
            return ProcessedEnvelope(outcome: .applied, peerAccount: envelope.senderAccount, profile: info)

        case .typing(let typing):
            // Ephemeral, 1:1 only for now — release the dedup claim.
            try? storage.messages.releaseEnvelope(id: envelope.id)
            return ProcessedEnvelope(
                outcome: .ignored, peerAccount: envelope.senderAccount,
                typingStarted: groupId == nil ? (typing.action == .started) : nil
            )

        case .none:
            return ProcessedEnvelope(outcome: .ignored, peerAccount: envelope.senderAccount)
        }
    }

    private static func action(_ a: Relay_Content_GroupUpdate.Action) -> GroupAction {
        switch a {
        case .create: .create
        case .add: .add
        case .remove: .remove
        case .leave: .leave
        case .rename: .rename
        default: .unknown
        }
    }

    private func hasUsername(conversationId: String) -> Bool {
        let username = try? storage.database.query(
            "SELECT peer_username FROM conversations WHERE id = ?", [.text(conversationId)]
        ).first?.first?.string
        return (username ?? nil) != nil
    }
}
