//
//  EnvelopeProcessor.swift
//  RelayCore
//
//  The single, shared incoming pipeline. Both the app (over the WebSocket)
//  and the Notification Service Extension (from the push payload) run an
//  envelope through here: it claims the envelope exactly once, decrypts it
//  (advancing the Double Ratchet in the shared store), applies the content,
//  and returns what happened. Network side-effects (receipts, username
//  lookups) are *returned* rather than performed, so the NSE can ignore them.
//

import CryptoCore
import Foundation
import LibSignalClient
import RelayKit
import SecureStorage
import SwiftProtobuf

/// Actions the caller may perform after processing. The NSE ignores these;
/// the app sends the receipt and does the username backfill.
public struct EnvelopeSideEffects: Sendable {
    /// Send a delivery receipt for this sender timestamp to the peer.
    public var deliveryReceiptTimestamp: Int64?
    /// The conversation has no username yet; resolve it from the relay.
    public var backfillUsernameForAccount: String?
}

/// A user-visible message worth surfacing as a notification.
public struct NotificationContent: Sendable {
    public let senderAccount: String
    public let conversationId: String
    public let body: String
}

public struct ProcessedEnvelope: Sendable {
    public enum Outcome: Sendable {
        case stored      // a new message row was inserted
        case applied     // reaction/receipt/delete applied to existing state
        case duplicate   // already processed (or replayed) — nothing to do
        case ignored     // nothing persistent (e.g. typing)
    }

    public let outcome: Outcome
    public let peerAccount: String?
    public let conversationId: String?
    public let notification: NotificationContent?
    public let sideEffects: EnvelopeSideEffects
    /// Non-nil when the envelope was a typing indicator (true = started).
    public let typingStarted: Bool?
}

public struct EnvelopeProcessor {
    private let storage: SecureStore
    private let engine: CryptoEngine

    public init(storage: SecureStore, engine: CryptoEngine) {
        self.storage = storage
        self.engine = engine
    }

    /// Claims, decrypts and applies one envelope. Throws only on unexpected
    /// storage failures; decrypt failures are surfaced by rethrowing (callers
    /// still ack, per poison-message handling).
    public func process(_ envelope: IncomingEnvelope) throws -> ProcessedEnvelope {
        // Exactly-once: destructive decryption must run in one process only.
        guard try storage.messages.claimEnvelope(id: envelope.id) else {
            return ProcessedEnvelope(
                outcome: .duplicate, peerAccount: envelope.senderAccount,
                conversationId: nil, notification: nil,
                sideEffects: EnvelopeSideEffects(), typingStarted: nil
            )
        }

        let sender = try ProtocolAddress(name: envelope.senderAccount, deviceId: envelope.senderDevice)
        let plaintext = try engine.decrypt(envelope.message, from: sender)
        let content = try Relay_Content_Content(serializedBytes: plaintext)
        var effects = EnvelopeSideEffects()

        switch content.body {
        case .text(let text):
            let conversationId = try storage.messages.conversation(withPeer: envelope.senderAccount)
            let quote: QuotedMessage? = text.hasQuote
                ? QuotedMessage(
                    targetTimestamp: text.quote.targetTimestamp,
                    author: text.quote.author,
                    text: text.quote.text
                )
                : nil
            let attachments = text.attachments.map { pointer in
                StoredAttachment(
                    id: pointer.id,
                    key: pointer.key,
                    digest: pointer.digest,
                    contentType: pointer.contentType,
                    size: Int64(pointer.size),
                    filename: pointer.filename.isEmpty ? nil : pointer.filename,
                    width: Int(pointer.width),
                    height: Int(pointer.height),
                    isDownloaded: false
                )
            }
            let inserted = try storage.messages.insertMessage(
                id: envelope.id,
                conversationId: conversationId,
                isOutgoing: false,
                body: text.body,
                timestamp: text.timestamp,
                status: .received,
                replyTo: quote,
                attachments: attachments
            )
            if inserted {
                effects.deliveryReceiptTimestamp = text.timestamp
            }
            if !hasUsername(conversationId: conversationId) {
                effects.backfillUsernameForAccount = envelope.senderAccount
            }
            return ProcessedEnvelope(
                outcome: inserted ? .stored : .duplicate,
                peerAccount: envelope.senderAccount,
                conversationId: conversationId,
                notification: inserted
                    ? NotificationContent(
                        senderAccount: envelope.senderAccount,
                        conversationId: conversationId,
                        body: text.body.isEmpty && !attachments.isEmpty ? "📷 Photo" : text.body
                    )
                    : nil,
                sideEffects: effects,
                typingStarted: nil
            )

        case .reaction(let reaction):
            let conversationId = try storage.messages.conversation(withPeer: envelope.senderAccount)
            try storage.messages.setReaction(
                conversationId: conversationId,
                targetTimestamp: reaction.targetTimestamp,
                author: envelope.senderAccount,
                isOutgoing: false,
                emoji: reaction.emoji,
                remove: reaction.remove
            )
            return ProcessedEnvelope(
                outcome: .applied,
                peerAccount: envelope.senderAccount,
                conversationId: conversationId,
                notification: reaction.remove
                    ? nil
                    : NotificationContent(senderAccount: envelope.senderAccount, conversationId: conversationId, body: "Reacted \(reaction.emoji)"),
                sideEffects: effects,
                typingStarted: nil
            )

        case .receipt(let receipt):
            let conversationId = try storage.messages.conversation(withPeer: envelope.senderAccount)
            try storage.messages.applyReceipt(
                conversationId: conversationId,
                timestamps: receipt.messageTimestamps,
                status: receipt.type == .read ? .read : .delivered
            )
            return ProcessedEnvelope(
                outcome: .applied, peerAccount: envelope.senderAccount,
                conversationId: conversationId, notification: nil,
                sideEffects: effects, typingStarted: nil
            )

        case .delete(let deletion):
            let conversationId = try storage.messages.conversation(withPeer: envelope.senderAccount)
            try storage.messages.markDeleted(
                conversationId: conversationId,
                targetTimestamp: deletion.targetTimestamp
            )
            return ProcessedEnvelope(
                outcome: .applied, peerAccount: envelope.senderAccount,
                conversationId: conversationId, notification: nil,
                sideEffects: effects, typingStarted: nil
            )

        case .typing(let typing):
            // Ephemeral: nothing to store, and it's never pushed, so it needs
            // no dedup — release the claim to keep the table from growing.
            try? storage.messages.releaseEnvelope(id: envelope.id)
            return ProcessedEnvelope(
                outcome: .ignored, peerAccount: envelope.senderAccount,
                conversationId: nil, notification: nil,
                sideEffects: effects, typingStarted: typing.action == .started
            )

        case .none:
            return ProcessedEnvelope(
                outcome: .ignored, peerAccount: envelope.senderAccount,
                conversationId: nil, notification: nil,
                sideEffects: effects, typingStarted: nil
            )
        }
    }

    private func hasUsername(conversationId: String) -> Bool {
        let username = try? storage.database.query(
            "SELECT peer_username FROM conversations WHERE id = ?", [.text(conversationId)]
        ).first?.first?.string
        return (username ?? nil) != nil
    }
}
