//
//  MessageStore.swift
//  SecureStorage
//
//  Conversation and message history, encrypted at rest by SQLCipher.
//  Plaintext bodies exist only inside this database (and on screen).
//

import Foundation

public struct Conversation: Sendable, Equatable, Identifiable {
    public let id: String
    public let peerAccount: String
    public let peerUsername: String?
    public let lastMessageAt: Int64?
    public let lastMessageBody: String?
}

public enum MessageStatus: String, Sendable {
    case sending, sent, delivered, read, failed
    case received
}

/// A snapshot of the message a reply quotes — self-contained so it renders
/// without a lookup and survives the original being deleted.
public struct QuotedMessage: Sendable, Equatable {
    public let targetTimestamp: Int64
    public let author: String
    public let text: String

    public init(targetTimestamp: Int64, author: String, text: String) {
        self.targetTimestamp = targetTimestamp
        self.author = author
        self.text = text
    }
}

/// One emoji reaction on a message.
public struct MessageReaction: Sendable, Equatable {
    public let emoji: String
    public let author: String
    /// True when the local user is the reactor.
    public let isOutgoing: Bool

    public init(emoji: String, author: String, isOutgoing: Bool) {
        self.emoji = emoji
        self.author = author
        self.isOutgoing = isOutgoing
    }
}

public struct StoredMessage: Sendable, Equatable, Identifiable {
    public let id: String
    public let conversationId: String
    public let isOutgoing: Bool
    public let body: String
    /// Sender's clock (ms since epoch); receipts reference this.
    public let timestamp: Int64
    public let status: MessageStatus
    /// Set when this message replies to an earlier one.
    public let replyTo: QuotedMessage?
    /// Reactions attached to this message, oldest first.
    public let reactions: [MessageReaction]
    /// True once the message has been unsent (delete-for-everyone); the body
    /// is cleared and the UI shows a tombstone placeholder.
    public let isDeleted: Bool
}

public final class MessageStore {
    private let db: Database

    public init(database: Database) {
        self.db = database
    }

    // MARK: - Conversations

    /// Returns the conversation with this peer, creating it if needed.
    @discardableResult
    public func conversation(withPeer account: String, username: String? = nil) throws -> String {
        if let id = try db.query(
            "SELECT id FROM conversations WHERE peer_account = ?", [.text(account)]
        ).first?.first?.string {
            if let username {
                try db.run(
                    "UPDATE conversations SET peer_username = ? WHERE id = ?",
                    [.text(username), .text(id)]
                )
            }
            return id
        }
        let id = UUID().uuidString
        try db.run(
            "INSERT INTO conversations (id, peer_account, peer_username, created_at) VALUES (?, ?, ?, ?)",
            [
                .text(id), .text(account),
                username.map { .text($0) } ?? .null,
                .integer(Int64(Date().timeIntervalSince1970 * 1000)),
            ]
        )
        return id
    }

    public func conversations() throws -> [Conversation] {
        let rows = try db.query("""
            SELECT c.id, c.peer_account, c.peer_username, c.last_message_at,
                   (SELECT body FROM messages m WHERE m.conversation_id = c.id
                    ORDER BY m.timestamp DESC LIMIT 1)
            FROM conversations c
            ORDER BY c.last_message_at DESC NULLS LAST, c.created_at DESC
            """)
        return rows.map {
            Conversation(
                id: $0[0].string ?? "",
                peerAccount: $0[1].string ?? "",
                peerUsername: $0[2].string,
                lastMessageAt: $0[3].int64,
                lastMessageBody: $0[4].string
            )
        }
    }

    // MARK: - Messages

    /// Inserts a message; returns false if it already exists (dedup on id,
    /// which is the relay envelope id for incoming messages — delivery is
    /// at-least-once, so replays must be no-ops).
    @discardableResult
    public func insertMessage(
        id: String,
        conversationId: String,
        isOutgoing: Bool,
        body: String,
        timestamp: Int64,
        status: MessageStatus,
        replyTo: QuotedMessage? = nil
    ) throws -> Bool {
        let inserted = try db.transaction {
            let exists = try !db.query("SELECT 1 FROM messages WHERE id = ?", [.text(id)]).isEmpty
            if exists { return false }
            try db.run(
                """
                INSERT INTO messages
                    (id, conversation_id, is_outgoing, body, timestamp, status, created_at,
                     reply_to_timestamp, reply_to_author, reply_to_text)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(id), .text(conversationId), .integer(isOutgoing ? 1 : 0),
                    .text(body), .integer(timestamp), .text(status.rawValue),
                    .integer(Int64(Date().timeIntervalSince1970 * 1000)),
                    replyTo.map { .integer($0.targetTimestamp) } ?? .null,
                    replyTo.map { .text($0.author) } ?? .null,
                    replyTo.map { .text($0.text) } ?? .null,
                ]
            )
            try db.run(
                "UPDATE conversations SET last_message_at = MAX(COALESCE(last_message_at, 0), ?) WHERE id = ?",
                [.integer(timestamp), .text(conversationId)]
            )
            return true
        }
        return inserted
    }

    /// Newest `limit` messages, oldest first (ready for chat display), with
    /// their reply snapshots and reactions attached.
    public func messages(in conversationId: String, limit: Int = 100) throws -> [StoredMessage] {
        let reactions = try reactionsByTarget(in: conversationId)
        let rows = try db.query(
            """
            SELECT id, is_outgoing, body, timestamp, status,
                   reply_to_timestamp, reply_to_author, reply_to_text, deleted FROM (
                SELECT * FROM messages WHERE conversation_id = ?
                ORDER BY timestamp DESC LIMIT ?
            ) ORDER BY timestamp ASC
            """,
            [.text(conversationId), .integer(Int64(limit))]
        )
        return rows.map { row in
            let timestamp = row[3].int64 ?? 0
            let replyTo: QuotedMessage? = row[5].int64.map {
                QuotedMessage(targetTimestamp: $0, author: row[6].string ?? "", text: row[7].string ?? "")
            }
            return StoredMessage(
                id: row[0].string ?? "",
                conversationId: conversationId,
                isOutgoing: row[1].int64 == 1,
                body: row[2].string ?? "",
                timestamp: timestamp,
                status: MessageStatus(rawValue: row[4].string ?? "") ?? .received,
                replyTo: replyTo,
                reactions: reactions[timestamp] ?? [],
                isDeleted: row[8].int64 == 1
            )
        }
    }

    private func reactionsByTarget(in conversationId: String) throws -> [Int64: [MessageReaction]] {
        let rows = try db.query(
            """
            SELECT target_timestamp, emoji, author, is_outgoing FROM reactions
            WHERE conversation_id = ? ORDER BY created_at ASC
            """,
            [.text(conversationId)]
        )
        var result: [Int64: [MessageReaction]] = [:]
        for row in rows {
            guard let target = row[0].int64 else { continue }
            result[target, default: []].append(
                MessageReaction(
                    emoji: row[1].string ?? "",
                    author: row[2].string ?? "",
                    isOutgoing: row[3].int64 == 1
                )
            )
        }
        return result
    }

    // MARK: - Reactions

    /// Applies or retracts one author's reaction to a message. One reaction
    /// per author per message; setting a new emoji replaces the previous.
    public func setReaction(
        conversationId: String,
        targetTimestamp: Int64,
        author: String,
        isOutgoing: Bool,
        emoji: String,
        remove: Bool
    ) throws {
        if remove {
            try db.run(
                "DELETE FROM reactions WHERE conversation_id = ? AND target_timestamp = ? AND author = ?",
                [.text(conversationId), .integer(targetTimestamp), .text(author)]
            )
        } else {
            try db.run(
                """
                INSERT INTO reactions
                    (conversation_id, target_timestamp, author, is_outgoing, emoji, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (conversation_id, target_timestamp, author)
                    DO UPDATE SET emoji = excluded.emoji, created_at = excluded.created_at
                """,
                [
                    .text(conversationId), .integer(targetTimestamp), .text(author),
                    .integer(isOutgoing ? 1 : 0), .text(emoji),
                    .integer(Int64(Date().timeIntervalSince1970 * 1000)),
                ]
            )
        }
    }

    /// Applies an "unsend": clears the message's plaintext (body, quote,
    /// reactions) and marks it deleted, leaving a tombstone in place. Matches
    /// by sender clock within a conversation, so it works both for the
    /// author's own copy and the recipient's. Returns whether a row changed.
    @discardableResult
    public func markDeleted(conversationId: String, targetTimestamp: Int64) throws -> Bool {
        try db.transaction {
            let exists = try !db.query(
                "SELECT 1 FROM messages WHERE conversation_id = ? AND timestamp = ?",
                [.text(conversationId), .integer(targetTimestamp)]
            ).isEmpty
            guard exists else { return false }
            try db.run(
                """
                UPDATE messages
                SET deleted = 1, body = '',
                    reply_to_timestamp = NULL, reply_to_author = NULL, reply_to_text = NULL
                WHERE conversation_id = ? AND timestamp = ?
                """,
                [.text(conversationId), .integer(targetTimestamp)]
            )
            try db.run(
                "DELETE FROM reactions WHERE conversation_id = ? AND target_timestamp = ?",
                [.text(conversationId), .integer(targetTimestamp)]
            )
            return true
        }
    }

    /// Deletes a message locally (delete-for-me), along with any reactions
    /// on it. Does not notify the peer.
    public func deleteMessage(id: String) throws {
        try db.transaction {
            let rows = try db.query(
                "SELECT conversation_id, timestamp FROM messages WHERE id = ?", [.text(id)]
            )
            guard let row = rows.first, let conversationId = row[0].string,
                  let timestamp = row[1].int64 else { return }
            try db.run("DELETE FROM messages WHERE id = ?", [.text(id)])
            try db.run(
                "DELETE FROM reactions WHERE conversation_id = ? AND target_timestamp = ?",
                [.text(conversationId), .integer(timestamp)]
            )
        }
    }

    /// Applies a receipt: marks outgoing messages with these timestamps in
    /// this conversation as delivered/read. Read never downgrades to
    /// delivered.
    public func applyReceipt(
        conversationId: String,
        timestamps: [Int64],
        status: MessageStatus
    ) throws {
        guard status == .delivered || status == .read else { return }
        for timestamp in timestamps {
            try db.run(
                """
                UPDATE messages SET status = ?
                WHERE conversation_id = ? AND timestamp = ? AND is_outgoing = 1
                  AND NOT (status = 'read' AND ? = 'delivered')
                """,
                [.text(status.rawValue), .text(conversationId), .integer(timestamp), .text(status.rawValue)]
            )
        }
    }

    // MARK: - Envelope dedup (shared by app + NSE)

    /// Atomically claims an envelope id for processing. Returns true if this
    /// caller won the claim and should decrypt it; false if it was already
    /// claimed (by the other process, or an earlier delivery). Combined with
    /// a cross-process lock around decryption, this guarantees exactly one
    /// decrypt of each envelope despite the shared ratchet state.
    @discardableResult
    public func claimEnvelope(id: String) throws -> Bool {
        try db.transaction {
            let exists = try !db.query(
                "SELECT 1 FROM processed_envelopes WHERE id = ?", [.text(id)]
            ).isEmpty
            if exists { return false }
            try db.run(
                "INSERT INTO processed_envelopes (id, processed_at) VALUES (?, ?)",
                [.text(id), .integer(Int64(Date().timeIntervalSince1970 * 1000))]
            )
            return true
        }
    }

    public func isEnvelopeProcessed(id: String) throws -> Bool {
        try !db.query(
            "SELECT 1 FROM processed_envelopes WHERE id = ?", [.text(id)]
        ).isEmpty
    }

    /// Releases a previously claimed envelope id. Used for ephemeral content
    /// (typing) that needs no dedup, to keep the dedup table from growing.
    public func releaseEnvelope(id: String) throws {
        try db.run("DELETE FROM processed_envelopes WHERE id = ?", [.text(id)])
    }

    public func updateStatus(messageId: String, status: MessageStatus) throws {
        try db.run(
            "UPDATE messages SET status = ? WHERE id = ?",
            [.text(status.rawValue), .text(messageId)]
        )
    }
}
