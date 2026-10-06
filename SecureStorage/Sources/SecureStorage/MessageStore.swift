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
    /// True when the last message was sent by the local user.
    public let lastMessageIsOutgoing: Bool
    /// Status of the last message (nil when conversation has no messages).
    public let lastMessageStatus: MessageStatus?
    /// Non-nil for group conversations (equals the group id).
    public let groupId: String?
    public let pinnedAt: Int64?
    public let readAt: Int64
    public let disappearingSeconds: Int64
    public let mediaRequiresBiometric: Bool
    public let requireBiometricChat: Bool
    public let hidePreviews: Bool
    public let unreadCount: Int
    public let archived: Bool
    /// Optional user-assigned label (e.g. "Work", "Family").
    public let label: String?
    /// The local user's own screenshot-hide preference for this conversation.
    public let screenSecurity: Bool
    /// The DM peer's screenshot-hide preference (synced E2E). Effective hiding is
    /// `screenSecurity || peerScreenSecurity` — both must disable to turn it off.
    /// Unused for groups (they use the admin-controlled group flag).
    public let peerScreenSecurity: Bool
    /// Custom notification sound name, nil = system default.
    public let notificationSound: String?

    public init(
        id: String, peerAccount: String, peerUsername: String?,
        lastMessageAt: Int64?, lastMessageBody: String?,
        lastMessageIsOutgoing: Bool, lastMessageStatus: MessageStatus?,
        groupId: String?, pinnedAt: Int64?, readAt: Int64,
        disappearingSeconds: Int64, mediaRequiresBiometric: Bool,
        requireBiometricChat: Bool, hidePreviews: Bool,
        unreadCount: Int, archived: Bool, label: String?,
        screenSecurity: Bool, peerScreenSecurity: Bool, notificationSound: String?
    ) {
        self.id = id; self.peerAccount = peerAccount
        self.peerUsername = peerUsername
        self.lastMessageAt = lastMessageAt; self.lastMessageBody = lastMessageBody
        self.lastMessageIsOutgoing = lastMessageIsOutgoing
        self.lastMessageStatus = lastMessageStatus
        self.groupId = groupId; self.pinnedAt = pinnedAt; self.readAt = readAt
        self.disappearingSeconds = disappearingSeconds
        self.mediaRequiresBiometric = mediaRequiresBiometric
        self.requireBiometricChat = requireBiometricChat
        self.hidePreviews = hidePreviews; self.unreadCount = unreadCount
        self.archived = archived; self.label = label
        self.screenSecurity = screenSecurity
        self.peerScreenSecurity = peerScreenSecurity
        self.notificationSound = notificationSound
    }

    public var isGroup: Bool { groupId != nil }
    public var isPinned: Bool { pinnedAt != nil }
}

/// A group's roster + state, mirrored from the relay.
public struct StoredGroup: Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let avatarData: Data?
    public let distributionId: String
    public let revision: Int64
    public let members: [String]
    public let admins: [String]
    public let isAnnounceOnly: Bool
    /// Admin-controlled screenshot-hide flag for the whole group.
    public let screenSecurity: Bool

    public init(
        id: String, name: String, description: String = "", avatarData: Data? = nil,
        distributionId: String, revision: Int64, members: [String],
        admins: [String] = [], isAnnounceOnly: Bool = false, screenSecurity: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.avatarData = avatarData
        self.distributionId = distributionId
        self.revision = revision
        self.members = members
        self.admins = admins
        self.isAnnounceOnly = isAnnounceOnly
        self.screenSecurity = screenSecurity
    }
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

public struct StoredProfile: Sendable, Equatable {
    public let displayName: String?
    public let avatarId: String?
    public let avatarData: Data?
    public let revision: Int64
    public let status: String?
    public let bio: String?
    /// JSON array of {label,url} objects; opaque to storage (app encodes/decodes).
    public let linksJSON: String?

    public init(displayName: String?, avatarId: String?, avatarData: Data?, revision: Int64,
                status: String? = nil, bio: String? = nil, linksJSON: String? = nil) {
        self.displayName = displayName
        self.avatarId = avatarId
        self.avatarData = avatarData
        self.revision = revision
        self.status = status
        self.bio = bio
        self.linksJSON = linksJSON
    }
}

/// A vote on a poll, keyed by (pollAuthor, pollTimestamp, voterAccount).
public struct StoredPollVote: Sendable, Equatable {
    public let pollAuthor: String
    public let pollTimestamp: Int64
    public let voterAccount: String
    public let selectedOptions: [Int]
    public let votedAt: Int64

    public init(pollAuthor: String, pollTimestamp: Int64, voterAccount: String, selectedOptions: [Int], votedAt: Int64) {
        self.pollAuthor = pollAuthor
        self.pollTimestamp = pollTimestamp
        self.voterAccount = voterAccount
        self.selectedOptions = selectedOptions
        self.votedAt = votedAt
    }
}

public enum StoredCallDirection: String, Sendable, Equatable {
    case incoming, outgoing
}

public enum StoredCallKind: String, Sendable, Equatable {
    case audio, video
}

public enum StoredCallOutcome: String, Sendable, Equatable {
    case answered, missed, declined, failed
}

public struct StoredCall: Sendable, Equatable, Identifiable {
    public let id: String
    public let peerAccount: String
    public let peerName: String
    public let direction: StoredCallDirection
    public let kind: StoredCallKind
    public let startedAt: Int64
    public let connectedAt: Int64?
    public let endedAt: Int64?
    public let outcome: StoredCallOutcome

    public init(
        id: String,
        peerAccount: String,
        peerName: String,
        direction: StoredCallDirection,
        kind: StoredCallKind,
        startedAt: Int64,
        connectedAt: Int64?,
        endedAt: Int64?,
        outcome: StoredCallOutcome
    ) {
        self.id = id
        self.peerAccount = peerAccount
        self.peerName = peerName
        self.direction = direction
        self.kind = kind
        self.startedAt = startedAt
        self.connectedAt = connectedAt
        self.endedAt = endedAt
        self.outcome = outcome
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
    /// For group messages, the account id of the sender (nil for 1:1).
    public let senderAccount: String?
    /// True if the user pinned this message (shows in the chat header banner).
    public let isPinned: Bool
    /// True when the local user has starred (bookmarked) this message.
    public let isStarred: Bool
    /// Timestamp (ms since epoch) when the message was last edited; nil = unedited.
    public let editedAt: Int64?

    public init(
        id: String, conversationId: String, isOutgoing: Bool, body: String,
        timestamp: Int64, status: MessageStatus, replyTo: QuotedMessage? = nil,
        reactions: [MessageReaction] = [], isDeleted: Bool = false,
        attachments: [StoredAttachment] = [], senderAccount: String? = nil,
        isPinned: Bool = false, isStarred: Bool = false, editedAt: Int64? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.isOutgoing = isOutgoing
        self.body = body
        self.timestamp = timestamp
        self.status = status
        self.replyTo = replyTo
        self.reactions = reactions
        self.isDeleted = isDeleted
        self.attachments = attachments
        self.senderAccount = senderAccount
        self.isPinned = isPinned
        self.isStarred = isStarred
        self.editedAt = editedAt
    }
}

public final class MessageStore: @unchecked Sendable {
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
        // screen_security defaults ON for new chats (privacy-first).
        try db.run(
            "INSERT INTO conversations (id, peer_account, peer_username, created_at, screen_security) VALUES (?, ?, ?, ?, 1)",
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
                   (SELECT CASE
                        WHEN m.body LIKE '__relay_loc__%' THEN '~loc~'
                        WHEN (m.body IS NULL OR m.body = '') AND
                             EXISTS(SELECT 1 FROM attachments a WHERE a.message_id = m.id AND a.content_type LIKE 'image/%') THEN '~photo~'
                        WHEN (m.body IS NULL OR m.body = '') AND
                             EXISTS(SELECT 1 FROM attachments a WHERE a.message_id = m.id AND a.content_type LIKE 'audio/%') THEN '~audio~'
                        WHEN (m.body IS NULL OR m.body = '') AND
                             EXISTS(SELECT 1 FROM attachments a WHERE a.message_id = m.id) THEN '~file~'
                        ELSE m.body
                    END
                    FROM messages m WHERE m.conversation_id = c.id
                    ORDER BY m.timestamp DESC LIMIT 1),
                   (SELECT m.is_outgoing FROM messages m WHERE m.conversation_id = c.id
                    ORDER BY m.timestamp DESC LIMIT 1),
                   (SELECT m.status FROM messages m WHERE m.conversation_id = c.id
                    ORDER BY m.timestamp DESC LIMIT 1),
                   c.group_id, c.pinned_at, c.read_at, c.disappearing_seconds,
                   c.media_requires_biometric, c.require_biometric_chat, c.hide_previews,
                   (SELECT COUNT(*) FROM messages m
                    WHERE m.conversation_id = c.id
                      AND m.is_outgoing = 0
                      AND m.deleted = 0
                      AND m.timestamp > c.read_at),
                   c.archived, c.label,
                   c.screen_security, c.notification_sound, c.peer_screen_security
            FROM conversations c
            ORDER BY c.pinned_at DESC NULLS LAST,
                     c.last_message_at DESC NULLS LAST,
                     c.created_at DESC
            """)
        return rows.map {
            Conversation(
                id: $0[0].string ?? "",
                peerAccount: $0[1].string ?? "",
                peerUsername: $0[2].string,
                lastMessageAt: $0[3].int64,
                lastMessageBody: $0[4].string,
                lastMessageIsOutgoing: $0[5].int64 != 0,
                lastMessageStatus: $0[6].string.flatMap { MessageStatus(rawValue: $0) },
                groupId: $0[7].string,
                pinnedAt: $0[8].int64,
                readAt: $0[9].int64 ?? 0,
                disappearingSeconds: $0[10].int64 ?? 0,
                mediaRequiresBiometric: $0[11].int64 != 0,
                requireBiometricChat: $0[12].int64 != 0,
                hidePreviews: $0[13].int64 != 0,
                unreadCount: Int($0[14].int64 ?? 0),
                archived: $0[15].int64 != 0,
                label: $0[16].string,
                screenSecurity: $0[17].int64 != 0,
                peerScreenSecurity: $0[19].int64 != 0,
                notificationSound: $0[18].string
            )
        }
    }

    public func setConversationLabel(_ conversationId: String, label: String?) throws {
        let value: SQLValue = label.map { .text($0) } ?? .null
        try db.run("UPDATE conversations SET label = ? WHERE id = ?", [value, .text(conversationId)])
    }

    public func markConversationUnread(_ conversationId: String) throws {
        let latest = try db.query(
            "SELECT COALESCE(MAX(timestamp), 1) - 1 FROM messages WHERE conversation_id = ? AND is_outgoing = 0 AND deleted = 0",
            [.text(conversationId)]
        ).first?.first?.int64 ?? 0
        try db.run("UPDATE conversations SET read_at = ? WHERE id = ?", [.integer(latest), .text(conversationId)])
    }

    public func clearCalls() throws {
        try db.run("DELETE FROM calls", [])
    }

    public func markConversationRead(_ conversationId: String, at timestamp: Int64? = nil) throws {
        let readAt: Int64
        if let timestamp {
            readAt = timestamp
        } else {
            readAt = try db.query(
                "SELECT COALESCE(MAX(timestamp), 0) FROM messages WHERE conversation_id = ?", [.text(conversationId)]
            ).first?.first?.int64 ?? 0
        }
        try db.run("UPDATE conversations SET read_at = MAX(read_at, ?) WHERE id = ?", [.integer(readAt), .text(conversationId)])
    }

    public func setConversationPinned(_ conversationId: String, pinned: Bool) throws {
        let value: SQLValue = pinned ? .integer(Int64(Date().timeIntervalSince1970 * 1000)) : .null
        try db.run("UPDATE conversations SET pinned_at = ? WHERE id = ?", [value, .text(conversationId)])
    }

    public func setDisappearingSeconds(_ conversationId: String, seconds: Int64) throws {
        try db.run("UPDATE conversations SET disappearing_seconds = ? WHERE id = ?", [.integer(max(0, seconds)), .text(conversationId)])
    }

    public func setConversationArchived(_ conversationId: String, archived: Bool) throws {
        try db.run("UPDATE conversations SET archived = ? WHERE id = ?", [.integer(archived ? 1 : 0), .text(conversationId)])
    }


    public func setMessagePinned(id: String, pinned: Bool) throws {
        try db.run("UPDATE messages SET pinned = ? WHERE id = ?", [.integer(pinned ? 1 : 0), .text(id)])
    }

    /// Replaces the body of an existing message and marks it as edited.
    public func editMessage(conversationId: String, targetTimestamp: Int64, newBody: String) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try db.run(
            "UPDATE messages SET body = ?, edited_at = ? WHERE conversation_id = ? AND timestamp = ? AND deleted = 0",
            [.text(newBody), .integer(now), .text(conversationId), .integer(targetTimestamp)]
        )
    }

    public func setMessageStarred(id: String, starred: Bool) throws {
        try db.run("UPDATE messages SET starred = ? WHERE id = ?", [.integer(starred ? 1 : 0), .text(id)])
    }

    public func starredMessages(in conversationId: String) throws -> [StoredMessage] {
        let reactions = try reactionsByTarget(in: conversationId)
        let attachments = try attachmentsByMessage(in: conversationId)
        let rows = try db.query(
            """
            SELECT id, is_outgoing, body, timestamp, status,
                   reply_to_timestamp, reply_to_author, reply_to_text, deleted, sender_account, pinned, starred, edited_at
            FROM messages
            WHERE conversation_id = ? AND starred = 1 AND deleted = 0
            ORDER BY timestamp DESC
            """,
            [.text(conversationId)]
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
                attachments: attachments[row[0].string ?? ""] ?? [],
                senderAccount: row[9].string,
                isPinned: row[10].int64 == 1,
                isStarred: true,
                editedAt: row[12].int64
            )
        }
    }

    /// Returns the most-recently pinned non-deleted message in a conversation, if any.
    public func pinnedMessage(in conversationId: String) throws -> StoredMessage? {
        let reactions = try reactionsByTarget(in: conversationId)
        let rows = try db.query(
            """
            SELECT id, is_outgoing, body, timestamp, status,
                   reply_to_timestamp, reply_to_author, reply_to_text, deleted, sender_account, edited_at
            FROM messages
            WHERE conversation_id = ? AND pinned = 1 AND deleted = 0
            ORDER BY timestamp DESC LIMIT 1
            """,
            [.text(conversationId)]
        )
        guard let row = rows.first else { return nil }
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
            senderAccount: row[9].string,
            isPinned: true,
            editedAt: row[10].int64
        )
    }

    public func setConversationPrivacy(
        _ conversationId: String,
        mediaRequiresBiometric: Bool,
        requireBiometricChat: Bool,
        hidePreviews: Bool
    ) throws {
        try db.run(
            """
            UPDATE conversations
            SET media_requires_biometric = ?, require_biometric_chat = ?, hide_previews = ?
            WHERE id = ?
            """,
            [
                .integer(mediaRequiresBiometric ? 1 : 0),
                .integer(requireBiometricChat ? 1 : 0),
                .integer(hidePreviews ? 1 : 0),
                .text(conversationId),
            ]
        )
    }

    /// The local user's own screenshot-hide preference for a conversation.
    public func setConversationScreenSecurity(_ conversationId: String, enabled: Bool) throws {
        try db.run("UPDATE conversations SET screen_security = ? WHERE id = ?",
                   [.integer(enabled ? 1 : 0), .text(conversationId)])
    }

    /// The DM peer's screenshot-hide preference, synced from a ScreenSecurityUpdate.
    public func setConversationPeerScreenSecurity(_ conversationId: String, enabled: Bool) throws {
        try db.run("UPDATE conversations SET peer_screen_security = ? WHERE id = ?",
                   [.integer(enabled ? 1 : 0), .text(conversationId)])
    }

    public func setNotificationSound(_ conversationId: String, sound: String?) throws {
        let value: SQLValue = sound.map { .text($0) } ?? .null
        try db.run("UPDATE conversations SET notification_sound = ? WHERE id = ?",
                   [value, .text(conversationId)])
    }

    public struct SearchResult: Sendable, Equatable, Identifiable {
        public let id: String
        public let conversationId: String
        public let messageId: String
        public let body: String
        public let timestamp: Int64
    }

    public func searchMessages(query: String, limit: Int = 100) throws -> [SearchResult] {
        let pattern = "%\(query.lowercased())%"
        let rows = try db.query(
            """
            SELECT id, conversation_id, body, timestamp
            FROM messages
            WHERE deleted = 0 AND body != '' AND lower(body) LIKE ?
              AND (expires_at IS NULL OR expires_at > CAST(strftime('%s','now') AS INTEGER) * 1000)
            ORDER BY timestamp DESC
            LIMIT ?
            """,
            [.text(pattern), .integer(Int64(limit))]
        )
        return rows.map {
            let messageId = $0[0].string ?? ""
            return SearchResult(
                id: messageId,
                conversationId: $0[1].string ?? "",
                messageId: messageId,
                body: $0[2].string ?? "",
                timestamp: $0[3].int64 ?? 0
            )
        }
    }

    // MARK: - Groups

    /// Creates or updates a group's local state + roster, ensuring a
    /// conversation row exists for it (peer_account == group id).
    public func upsertGroup(
        id: String, name: String, distributionId: String, revision: Int64, members: [String],
        admins: [String] = [], isAnnounceOnly: Bool? = nil
    ) throws {
        let adminsJSON = (try? JSONEncoder().encode(admins)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try db.transaction {
            // Ensure the conversation exists and is tagged as a group.
            let existing = try db.query(
                "SELECT id FROM conversations WHERE peer_account = ?", [.text(id)]
            ).first?.first?.string
            if existing == nil {
                try db.run(
                    """
                    INSERT INTO conversations (id, peer_account, peer_username, created_at, group_id, screen_security)
                    VALUES (?, ?, ?, ?, ?, 1)
                    """,
                    [.text(UUID().uuidString), .text(id), .text(name),
                     .integer(Int64(Date().timeIntervalSince1970 * 1000)), .text(id)]
                )
            } else {
                try db.run(
                    "UPDATE conversations SET peer_username = ?, group_id = ? WHERE peer_account = ?",
                    [.text(name), .text(id), .text(id)]
                )
            }
            // Preserve existing description and avatar_data when upserting roster.
            // Only update admins/announce_only when explicitly provided.
            if let isAnnounceOnly {
                try db.run(
                    """
                    INSERT INTO group_state (id, name, distribution_id, revision, description, avatar_data, admins, is_announce_only)
                    VALUES (?, ?, ?, ?, '', NULL, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        distribution_id = excluded.distribution_id,
                        revision = excluded.revision,
                        admins = excluded.admins,
                        is_announce_only = excluded.is_announce_only
                    """,
                    [.text(id), .text(name), .text(distributionId), .integer(revision),
                     .text(adminsJSON), .integer(isAnnounceOnly ? 1 : 0)]
                )
            } else {
                try db.run(
                    """
                    INSERT INTO group_state (id, name, distribution_id, revision, description, avatar_data, admins)
                    VALUES (?, ?, ?, ?, '', NULL, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        distribution_id = excluded.distribution_id,
                        revision = excluded.revision,
                        admins = excluded.admins
                    """,
                    [.text(id), .text(name), .text(distributionId), .integer(revision), .text(adminsJSON)]
                )
            }
            try db.run("DELETE FROM group_members WHERE group_id = ?", [.text(id)])
            for member in members {
                try db.run(
                    "INSERT OR IGNORE INTO group_members (group_id, account_id) VALUES (?, ?)",
                    [.text(id), .text(member)]
                )
            }
        }
    }

    public func setGroupAdmins(id: String, admins: [String]) throws {
        let adminsJSON = (try? JSONEncoder().encode(admins)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try db.run("UPDATE group_state SET admins = ? WHERE id = ?", [.text(adminsJSON), .text(id)])
    }

    public func setGroupAnnounceOnly(id: String, isAnnounceOnly: Bool) throws {
        try db.run(
            "UPDATE group_state SET is_announce_only = ? WHERE id = ?",
            [.integer(isAnnounceOnly ? 1 : 0), .text(id)]
        )
    }

    public func setGroupDescription(id: String, description: String) throws {
        try db.run(
            "UPDATE group_state SET description = ? WHERE id = ?",
            [.text(description), .text(id)]
        )
    }

    public func setGroupAvatar(id: String, avatarData: Data?) throws {
        try db.run(
            "UPDATE group_state SET avatar_data = ? WHERE id = ?",
            [avatarData.map { SQLValue.blob($0) } ?? .null, .text(id)]
        )
    }

    public func setGroupScreenSecurity(id: String, enabled: Bool) throws {
        try db.run(
            "UPDATE group_state SET screen_security = ? WHERE id = ?",
            [.integer(enabled ? 1 : 0), .text(id)]
        )
    }

    public func group(id: String) throws -> StoredGroup? {
        guard let row = try db.query(
            "SELECT name, description, avatar_data, distribution_id, revision, COALESCE(admins,'[]'), COALESCE(is_announce_only,0), COALESCE(screen_security,1) FROM group_state WHERE id = ?", [.text(id)]
        ).first else { return nil }
        let members = try db.query(
            "SELECT account_id FROM group_members WHERE group_id = ? ORDER BY account_id", [.text(id)]
        ).compactMap { $0.first?.string }
        let adminsJSON = row[5].string ?? "[]"
        let admins = (try? JSONDecoder().decode([String].self, from: Data(adminsJSON.utf8))) ?? []
        return StoredGroup(
            id: id,
            name: row[0].string ?? "",
            description: row[1].string ?? "",
            avatarData: row[2].data,
            distributionId: row[3].string ?? "",
            revision: row[4].int64 ?? 0,
            members: members,
            admins: admins,
            isAnnounceOnly: (row[6].int64 ?? 0) != 0,
            screenSecurity: (row[7].int64 ?? 1) != 0
        )
    }

    /// The conversation id for a group (nil if not yet created locally).
    public func groupConversationId(groupId: String) throws -> String? {
        try db.query(
            "SELECT id FROM conversations WHERE peer_account = ?", [.text(groupId)]
        ).first?.first?.string
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
        attachments: [StoredAttachment] = [],
        senderAccount: String? = nil
    ) throws -> Bool {
        let inserted = try db.transaction {
            let exists = try !db.query("SELECT 1 FROM messages WHERE id = ?", [.text(id)]).isEmpty
            if exists { return false }
            let createdAt = Int64(Date().timeIntervalSince1970 * 1000)
            // System messages (call events, group membership lines) never disappear.
            let ttl = senderAccount == "__system__" ? 0 : try disappearingSeconds(conversationId: conversationId)
            let expiresAt: SQLValue = ttl > 0 ? .integer(createdAt + ttl * 1000) : .null
            try db.run(
                """
                INSERT INTO messages
                    (id, conversation_id, is_outgoing, body, timestamp, status, created_at,
                     reply_to_timestamp, reply_to_author, reply_to_text, sender_account, expires_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(id), .text(conversationId), .integer(isOutgoing ? 1 : 0),
                    .text(body), .integer(timestamp), .text(status.rawValue),
                    .integer(createdAt),
                    replyTo.map { .integer($0.targetTimestamp) } ?? .null,
                    replyTo.map { .text($0.author) } ?? .null,
                    replyTo.map { .text($0.text) } ?? .null,
                    senderAccount.map { .text($0) } ?? .null,
                    expiresAt,
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

    /// Inserts or updates a single "live location" message in place, keyed by a
    /// stable id (one row per sharer per conversation) so a moving share updates
    /// one bubble instead of spamming a new one on every tick. Returns true if a
    /// new row was created (vs. an in-place update). Never expires mid-share.
    @discardableResult
    public func upsertLiveLocation(
        id: String,
        conversationId: String,
        isOutgoing: Bool,
        body: String,
        timestamp: Int64,
        senderAccount: String? = nil
    ) throws -> Bool {
        let status = (isOutgoing ? MessageStatus.sent : MessageStatus.received).rawValue
        let wasInsert: Bool = try db.transaction {
            let exists = try !db.query("SELECT 1 FROM messages WHERE id = ?", [.text(id)]).isEmpty
            if exists {
                try db.run(
                    "UPDATE messages SET body = ?, timestamp = ?, status = ? WHERE id = ?",
                    [.text(body), .integer(timestamp), .text(status), .text(id)]
                )
            } else {
                try db.run(
                    """
                    INSERT INTO messages
                        (id, conversation_id, is_outgoing, body, timestamp, status, created_at, sender_account, expires_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                    [
                        .text(id), .text(conversationId), .integer(isOutgoing ? 1 : 0),
                        .text(body), .integer(timestamp), .text(status),
                        .integer(Int64(Date().timeIntervalSince1970 * 1000)),
                        senderAccount.map { .text($0) } ?? .null,
                    ]
                )
            }
            try db.run(
                "UPDATE conversations SET last_message_at = MAX(COALESCE(last_message_at, 0), ?) WHERE id = ?",
                [.integer(timestamp), .text(conversationId)]
            )
            return !exists
        }
        return wasInsert
    }

    private func disappearingSeconds(conversationId: String) throws -> Int64 {
        try db.query(
            "SELECT disappearing_seconds FROM conversations WHERE id = ?", [.text(conversationId)]
        ).first?.first?.int64 ?? 0
    }

    @discardableResult
    public func deleteExpiredMessages(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> Int {
        let rows = try db.query("SELECT id FROM messages WHERE expires_at IS NOT NULL AND expires_at <= ?", [.integer(now)])
        for row in rows {
            if let id = row.first?.string { try deleteMessage(id: id) }
        }
        return rows.count
    }

    /// Newest `limit` messages, oldest first (ready for chat display), with
    /// their reply snapshots and reactions attached.
    public func messages(in conversationId: String, limit: Int = 100) throws -> [StoredMessage] {
        let reactions = try reactionsByTarget(in: conversationId)
        let attachments = try attachmentsByMessage(in: conversationId)
        let rows = try db.query(
            """
            SELECT id, is_outgoing, body, timestamp, status,
                   reply_to_timestamp, reply_to_author, reply_to_text, deleted, sender_account, pinned, starred, edited_at FROM (
                SELECT * FROM messages
                WHERE conversation_id = ?
                  AND (expires_at IS NULL OR expires_at > CAST(strftime('%s','now') AS INTEGER) * 1000)
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
                attachments: attachments[row[0].string ?? ""] ?? [],
                senderAccount: row[9].string,
                isPinned: row[10].int64 == 1,
                isStarred: row[11].int64 == 1,
                editedAt: row[12].int64
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

    // MARK: - Profiles

    /// A peer's self-set profile (display name + decrypted avatar bytes + status/bio).
    public func peerProfile(account: String) throws -> StoredProfile? {
        let rows = try db.query(
            "SELECT display_name, avatar_id, avatar_data, revision, status, bio, links FROM profiles WHERE account_id = ?",
            [.text(account)]
        )
        guard let row = rows.first else { return nil }
        return StoredProfile(
            displayName: row[0].string,
            avatarId: row[1].string,
            avatarData: row[2].data,
            revision: row[3].int64 ?? 0,
            status: row[4].string,
            bio: row[5].string,
            linksJSON: row[6].string
        )
    }

    /// Replaces a peer's profile row wholesale (the caller resolves newest-wins
    /// and avatar reuse before calling).
    public func upsertProfile(
        account: String, displayName: String?, avatarId: String?,
        avatarData: Data?, revision: Int64, status: String?, bio: String?, linksJSON: String?
    ) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO profiles (account_id, display_name, avatar_id, avatar_data, revision, status, bio, links)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(account),
                displayName.map { SQLValue.text($0) } ?? .null,
                avatarId.map { SQLValue.text($0) } ?? .null,
                avatarData.map { SQLValue.blob($0) } ?? .null,
                .integer(revision),
                status.map { SQLValue.text($0) } ?? .null,
                bio.map { SQLValue.text($0) } ?? .null,
                linksJSON.map { SQLValue.text($0) } ?? .null,
            ]
        )
    }

    // MARK: - Calls

    public func calls(limit: Int = 100) throws -> [StoredCall] {
        let rows = try db.query(
            """
            SELECT id, peer_account, peer_name, direction, kind, started_at, connected_at, ended_at, outcome
            FROM calls
            ORDER BY started_at DESC
            LIMIT ?
            """,
            [.integer(Int64(limit))]
        )
        return rows.map { row in
            StoredCall(
                id: row[0].string ?? "",
                peerAccount: row[1].string ?? "",
                peerName: row[2].string ?? "",
                direction: StoredCallDirection(rawValue: row[3].string ?? "") ?? .incoming,
                kind: StoredCallKind(rawValue: row[4].string ?? "") ?? .audio,
                startedAt: row[5].int64 ?? 0,
                connectedAt: row[6].int64,
                endedAt: row[7].int64,
                outcome: StoredCallOutcome(rawValue: row[8].string ?? "") ?? .failed
            )
        }
    }

    public func upsertCall(_ call: StoredCall) throws {
        try db.run(
            """
            INSERT INTO calls
                (id, peer_account, peer_name, direction, kind, started_at, connected_at, ended_at, outcome)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                peer_account = excluded.peer_account,
                peer_name = excluded.peer_name,
                direction = excluded.direction,
                kind = excluded.kind,
                started_at = excluded.started_at,
                connected_at = excluded.connected_at,
                ended_at = excluded.ended_at,
                outcome = excluded.outcome
            """,
            [
                .text(call.id), .text(call.peerAccount), .text(call.peerName),
                .text(call.direction.rawValue), .text(call.kind.rawValue),
                .integer(call.startedAt),
                call.connectedAt.map { SQLValue.integer($0) } ?? .null,
                call.endedAt.map { SQLValue.integer($0) } ?? .null,
                .text(call.outcome.rawValue),
            ]
        )
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

    /// Deletes a conversation and all its messages, reactions, and attachments.
    public func deleteConversation(id: String) throws {
        try db.transaction {
            try db.run("DELETE FROM attachments WHERE message_id IN (SELECT id FROM messages WHERE conversation_id = ?)", [.text(id)])
            try db.run("DELETE FROM reactions WHERE conversation_id = ?", [.text(id)])
            try db.run("DELETE FROM messages WHERE conversation_id = ?", [.text(id)])
            try db.run("DELETE FROM conversations WHERE id = ?", [.text(id)])
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

    // MARK: - Group receipts (per-member)

    /// Records each member's delivered/read state for a group message the
    /// local user authored. Read never downgrades to delivered.
    public func recordGroupReceipt(
        conversationId: String,
        member: String,
        timestamps: [Int64],
        status: MessageStatus
    ) throws {
        guard status == .delivered || status == .read else { return }
        for timestamp in timestamps {
            try db.run(
                """
                INSERT INTO message_receipts (conversation_id, message_timestamp, member_account, status)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(conversation_id, message_timestamp, member_account) DO UPDATE SET status = excluded.status
                    WHERE NOT (message_receipts.status = 'read' AND excluded.status = 'delivered')
                """,
                [.text(conversationId), .integer(timestamp), .text(member), .text(status.rawValue)]
            )
        }
    }

    /// The per-member receipt state for one group message: member → status.
    public func groupReceipts(conversationId: String, messageTimestamp: Int64) throws -> [String: MessageStatus] {
        let rows = try db.query(
            "SELECT member_account, status FROM message_receipts WHERE conversation_id = ? AND message_timestamp = ?",
            [.text(conversationId), .integer(messageTimestamp)]
        )
        var result: [String: MessageStatus] = [:]
        for row in rows {
            if let member = row[0].string, let status = MessageStatus(rawValue: row[1].string ?? "") {
                result[member] = status
            }
        }
        return result
    }

    // MARK: - Poll votes

    public func upsertPollVote(
        conversationId: String, pollAuthor: String, pollTimestamp: Int64,
        voterAccount: String, selectedOptions: [Int], votedAt: Int64
    ) throws {
        let optJSON = (try? JSONEncoder().encode(selectedOptions)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try db.run(
            """
            INSERT INTO poll_votes (conversation_id, poll_author, poll_timestamp, voter_account, selected_options, voted_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(conversation_id, poll_author, poll_timestamp, voter_account) DO UPDATE SET
                selected_options = excluded.selected_options,
                voted_at = excluded.voted_at
            """,
            [.text(conversationId), .text(pollAuthor), .integer(pollTimestamp),
             .text(voterAccount), .text(optJSON), .integer(votedAt)]
        )
    }

    public func pollVotes(conversationId: String, pollAuthor: String, pollTimestamp: Int64) throws -> [StoredPollVote] {
        let rows = try db.query(
            """
            SELECT voter_account, selected_options, voted_at FROM poll_votes
            WHERE conversation_id = ? AND poll_author = ? AND poll_timestamp = ?
            """,
            [.text(conversationId), .text(pollAuthor), .integer(pollTimestamp)]
        )
        return rows.compactMap { row -> StoredPollVote? in
            guard let voter = row[0].string, let optJSON = row[1].string, let votedAt = row[2].int64 else { return nil }
            let opts = (try? JSONDecoder().decode([Int].self, from: Data(optJSON.utf8))) ?? []
            return StoredPollVote(pollAuthor: pollAuthor, pollTimestamp: pollTimestamp,
                                  voterAccount: voter, selectedOptions: opts, votedAt: votedAt)
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
