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

/// A media attachment on a message. The encrypted blob lives on disk; this
/// carries the metadata plus the key/digest needed to fetch and decrypt it.
public struct StoredAttachment: Sendable, Equatable, Identifiable {
    public let id: String            // relay blob id
    public let key: Data             // AES-256-GCM key
    public let digest: Data          // SHA-256 of the ciphertext
    public let contentType: String
    public let size: Int64
    public let filename: String?
    public let width: Int
    public let height: Int
    public let isDownloaded: Bool

    public init(
        id: String, key: Data, digest: Data, contentType: String, size: Int64,
        filename: String?, width: Int, height: Int, isDownloaded: Bool
    ) {
        self.id = id
        self.key = key
        self.digest = digest
        self.contentType = contentType
        self.size = size
        self.filename = filename
        self.width = width
        self.height = height
        self.isDownloaded = isDownloaded
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
    /// Media attachments, in send order.
    public let attachments: [StoredAttachment]
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
        replyTo: QuotedMessage? = nil,
        attachments: [StoredAttachment] = []
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
            for (ordinal, attachment) in attachments.enumerated() {
                try db.run(
                    """
                    INSERT INTO attachments
                        (id, message_id, key, digest, content_type, size, filename, width, height, downloaded, ordinal)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(attachment.id), .text(id), .blob(attachment.key), .blob(attachment.digest),
                        .text(attachment.contentType), .integer(attachment.size),
                        attachment.filename.map { .text($0) } ?? .null,
                        .integer(Int64(attachment.width)), .integer(Int64(attachment.height)),
                        .integer(attachment.isDownloaded ? 1 : 0), .integer(Int64(ordinal)),
                    ]
                )
            }
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
        let attachments = try attachmentsByMessage(in: conversationId)
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
                isDeleted: row[8].int64 == 1,
                attachments: attachments[row[0].string ?? ""] ?? []
            )
        }
    }

    private func attachmentsByMessage(in conversationId: String) throws -> [String: [StoredAttachment]] {
        let rows = try db.query(
            """
            SELECT a.message_id, a.id, a.key, a.digest, a.content_type, a.size,
                   a.filename, a.width, a.height, a.downloaded
            FROM attachments a
            JOIN messages m ON m.id = a.message_id
            WHERE m.conversation_id = ?
            ORDER BY a.ordinal ASC
            """,
            [.text(conversationId)]
        )
        var result: [String: [StoredAttachment]] = [:]
        for row in rows {
            guard let messageId = row[0].string else { continue }
            result[messageId, default: []].append(
                StoredAttachment(
                    id: row[1].string ?? "",
                    key: row[2].data ?? Data(),
                    digest: row[3].data ?? Data(),
                    contentType: row[4].string ?? "application/octet-stream",
                    size: row[5].int64 ?? 0,
                    filename: row[6].string,
                    width: Int(row[7].int64 ?? 0),
                    height: Int(row[8].int64 ?? 0),
                    isDownloaded: row[9].int64 == 1
                )
            )
        }
        return result
    }

    /// Marks an attachment's ciphertext as cached locally on disk.
    public func markAttachmentDownloaded(id: String) throws {
        try db.run("UPDATE attachments SET downloaded = 1 WHERE id = ?", [.text(id)])
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
            try db.run(
                """
                DELETE FROM attachments WHERE message_id IN (
                    SELECT id FROM messages WHERE conversation_id = ? AND timestamp = ?
                )
                """,
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
            try db.run("DELETE FROM attachments WHERE message_id = ?", [.text(id)])
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
