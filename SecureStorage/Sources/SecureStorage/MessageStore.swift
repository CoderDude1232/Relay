//
//  MessageStore.swift
//  SecureStorage
//
//  Conversation and message history. Plaintext bodies exist only inside the
//  SQLCipher database and on screen.
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
    /// Nil when the conversation has no messages.
    public let lastMessageStatus: MessageStatus?
    /// Set for group conversations; equal to the group id.
    public let groupId: String?
    public let pinnedAt: Int64?
    public let readAt: Int64
    public let disappearingSeconds: Int64
    public let mediaRequiresBiometric: Bool
    public let requireBiometricChat: Bool
    public let hidePreviews: Bool
    public let unreadCount: Int
    public let archived: Bool
    public let label: String?
    /// Our own screenshot-hide preference for this conversation.
    public let screenSecurity: Bool
    /// The DM peer's screenshot-hide preference. Hiding applies if either side
    /// enables it. Unused for groups, which have an admin flag.
    public let peerScreenSecurity: Bool
    /// Custom notification sound; nil for the system default.
    public let notificationSound: String?
    /// False for a message request: a chat someone else started that the user
    /// hasn't accepted yet.
    public let accepted: Bool

    public init(
        id: String, peerAccount: String, peerUsername: String?,
        lastMessageAt: Int64?, lastMessageBody: String?,
        lastMessageIsOutgoing: Bool, lastMessageStatus: MessageStatus?,
        groupId: String?, pinnedAt: Int64?, readAt: Int64,
        disappearingSeconds: Int64, mediaRequiresBiometric: Bool,
        requireBiometricChat: Bool, hidePreviews: Bool,
        unreadCount: Int, archived: Bool, label: String?,
        screenSecurity: Bool, peerScreenSecurity: Bool, notificationSound: String?,
        accepted: Bool = true
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
        self.accepted = accepted
    }

    public var isGroup: Bool { groupId != nil }
    public var isRequest: Bool { !accepted }
    public var isPinned: Bool { pinnedAt != nil }
}

/// A group's roster and state.
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
    /// Admin-controlled screenshot-hide flag for the group.
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

/// Snapshot of the quoted message, so a reply renders without a lookup and
/// survives deletion of the original.
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

public struct MessageReaction: Sendable, Equatable {
    public let emoji: String
    public let author: String
    /// True when we are the reactor.
    public let isOutgoing: Bool

    public init(emoji: String, author: String, isOutgoing: Bool) {
        self.emoji = emoji
        self.author = author
        self.isOutgoing = isOutgoing
    }
}

/// A message attachment. The encrypted blob is on disk; this holds the
/// metadata and the key and digest to fetch and decrypt it.
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
    /// JSON array of {label,url}; the app encodes and decodes it.
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
    /// Sender's clock in ms; receipts reference it.
    public let timestamp: Int64
    public let status: MessageStatus
    public let replyTo: QuotedMessage?
    /// Oldest first.
    public let reactions: [MessageReaction]
    /// Unsent by the author: the body is cleared and the UI shows a tombstone.
    public let isDeleted: Bool
    /// In send order.
    public let attachments: [StoredAttachment]
    /// The sender's account id for group messages; nil for 1:1.
    public let senderAccount: String?
    /// Pinned messages appear in the chat header banner.
    public let isPinned: Bool
    public let isStarred: Bool
    /// Last edit time in ms; nil if never edited.
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
    /// `sender_account` of locally generated system lines (call events,
    /// membership, notices); matches `MessagingService.systemSender`. Stored as
    /// incoming but never unread and never receipted.
    public static let systemSender = "__system__"

    /// Longest disappearing-message timer accepted (a year).
    public static let maxDisappearingSeconds: Int64 = 365 * 24 * 60 * 60

    private let db: Database

    public init(database: Database) {
        self.db = database
    }

    // MARK: - Conversations

    /// The conversation with this peer, created if needed.
    /// The conversation with this peer, created if needed. A new one made for
    /// an incoming message passes `accepted: false`, which makes it a request.
    @discardableResult
    public func conversation(withPeer account: String, username: String? = nil, accepted: Bool = true) throws -> String {
        // 1:1 only. Groups and 1:1 chats share the peer_account key, and real
        // group ids are random UUIDs, so a group whose id equals this account id
        // is forged: a group-create meant to capture that contact's messages and
        // our replies. The account wins; drop the forged group first.
        if let forged = try db.query(
            "SELECT id FROM conversations WHERE peer_account = ? AND group_id IS NOT NULL", [.text(account)]
        ).first?.first?.string {
            try deleteConversation(id: forged)
            try db.run("DELETE FROM group_members WHERE group_id = ?", [.text(account)])
            try db.run("DELETE FROM group_state WHERE id = ?", [.text(account)])
        }
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
        // screen_security defaults on for new chats.
        try db.run(
            "INSERT INTO conversations (id, peer_account, peer_username, created_at, screen_security, accepted) VALUES (?, ?, ?, ?, 1, ?)",
            [
                .text(id), .text(account),
                username.map { .text($0) } ?? .null,
                .integer(Int64(Date().timeIntervalSince1970 * 1000)),
                .integer(accepted ? 1 : 0),
            ]
        )
        return id
    }

    public func setConversationAccepted(_ conversationId: String, accepted: Bool) throws {
        try db.run("UPDATE conversations SET accepted = ? WHERE id = ?", [.integer(accepted ? 1 : 0), .text(conversationId)])
    }

    /// Whether the 1:1 chat with `account` is a message request. False when
    /// there's no chat yet.
    public func isMessageRequest(peer account: String) throws -> Bool {
        try db.query(
            "SELECT accepted FROM conversations WHERE peer_account = ? AND group_id IS NULL", [.text(account)]
        ).first?.first?.int64 == 0
    }

    public func conversations() throws -> [Conversation] {
        let rows = try db.query("""
            SELECT c.id, c.peer_account, c.peer_username, c.last_message_at,
                   (SELECT CASE
                        WHEN m.body LIKE '__relay_loc__%' THEN '~loc~'
                        WHEN m.body = '__sticker__' THEN '~sticker~'
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
                      AND m.sender_account IS NOT '\(Self.systemSender)'
                      AND m.timestamp > c.read_at),
                   c.archived, c.label,
                   c.screen_security, c.notification_sound, c.peer_screen_security,
                   c.accepted
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
                notificationSound: $0[18].string,
                accepted: ($0[20].int64 ?? 1) != 0
            )
        }
    }

    public func setConversationLabel(_ conversationId: String, label: String?) throws {
        let value: SQLValue = label.map { .text($0) } ?? .null
        try db.run("UPDATE conversations SET label = ? WHERE id = ?", [value, .text(conversationId)])
    }

    public func markConversationUnread(_ conversationId: String) throws {
        let latest = try db.query(
            """
            SELECT COALESCE(MAX(timestamp), 1) - 1 FROM messages
            WHERE conversation_id = ? AND is_outgoing = 0 AND deleted = 0
              AND sender_account IS NOT '\(Self.systemSender)'
            """,
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
        let seconds = Swift.min(Swift.max(0, seconds), Self.maxDisappearingSeconds)
        try db.run("UPDATE conversations SET disappearing_seconds = ? WHERE id = ?", [.integer(seconds), .text(conversationId)])
    }

    public func setConversationArchived(_ conversationId: String, archived: Bool) throws {
        try db.run("UPDATE conversations SET archived = ? WHERE id = ?", [.integer(archived ? 1 : 0), .text(conversationId)])
    }


    public func setMessagePinned(id: String, pinned: Bool) throws {
        try db.run("UPDATE messages SET pinned = ? WHERE id = ?", [.integer(pinned ? 1 : 0), .text(id)])
    }

    /// Edits one message by id. Callers resolve the id from the edit's target
    /// and author: timestamps are chosen by senders and can collide.
    public func editMessage(id: String, newBody: String) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try db.run(
            "UPDATE messages SET body = ?, edited_at = ? WHERE id = ? AND deleted = 0",
            [.text(newBody), .integer(now), .text(id)]
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

    /// The most recently pinned non-deleted message in a conversation, if any.
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

    /// Our own screenshot-hide preference for a conversation.
    public func setConversationScreenSecurity(_ conversationId: String, enabled: Bool) throws {
        try db.run("UPDATE conversations SET screen_security = ? WHERE id = ?",
                   [.integer(enabled ? 1 : 0), .text(conversationId)])
    }

    /// The DM peer's screenshot-hide preference, from a ScreenSecurityUpdate.
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

    /// Creates or updates a group's state and roster, and makes sure it has a
    /// conversation row (peer_account == group id).
    public func upsertGroup(
        id: String, name: String, distributionId: String, revision: Int64, members: [String],
        admins: [String] = [], isAnnounceOnly: Bool? = nil
    ) throws {
        let adminsJSON = (try? JSONEncoder().encode(admins)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try db.transaction {
            // Group and 1:1 conversations share the peer_account key. A group id
            // equal to an existing 1:1 peer, or to our own account (Note to Self),
            // must never turn that chat into a group; otherwise a forged group-create
            // could make every later message in it fan out to the forger.
            let existingRow = try db.query(
                "SELECT id, group_id FROM conversations WHERE peer_account = ?", [.text(id)]
            ).first
            if let existingRow, existingRow[1].string == nil {
                throw StorageError.conflict("group id collides with a 1:1 conversation")
            }
            let existing = existingRow?[0].string
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
            // Keep description and avatar_data. Admins and announce_only change only
            // when passed.
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

    /// Nil if the group has no local conversation yet.
    public func groupConversationId(groupId: String) throws -> String? {
        try db.query(
            "SELECT id FROM conversations WHERE peer_account = ?", [.text(groupId)]
        ).first?.first?.string
    }

    // MARK: - Messages

    /// Inserts a message, returning false if its id already exists. Incoming ids
    /// are envelope ids and delivery is at-least-once, so replays are no-ops.
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
            // System lines (call events, membership) never disappear.
            let ttl = senderAccount == Self.systemSender ? 0 : try disappearingSeconds(conversationId: conversationId)
            // Overflow-safe: the timer comes from peers.
            let expiresAt: SQLValue = ttl > 0
                ? .integer(createdAt.addingClamped(ttl.multipliedClamped(by: 1000)))
                : .null
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

    /// Inserts or updates a live-location message keyed by a stable id (one row
    /// per sharer per conversation), so a moving share updates a single bubble.
    /// Returns true if a row was created. Never expires mid-share.
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

    /// Whether the conversation has been accepted (false for a message request).
    public func isAccepted(conversationId: String) throws -> Bool {
        try db.query(
            "SELECT accepted FROM conversations WHERE id = ?", [.text(conversationId)]
        ).first?.first?.int64 != 0
    }

    public func disappearingSeconds(conversationId: String) throws -> Int64 {
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

    /// The newest `limit` messages, oldest first, with reply snapshots and
    /// reactions attached.
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

    /// Marks an attachment's ciphertext as cached on disk.
    public func markAttachmentDownloaded(id: String) throws {
        try db.run("UPDATE attachments SET downloaded = 1 WHERE id = ?", [.text(id)])
    }

    // MARK: - Profiles

    /// A peer's profile, with the decrypted avatar.
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

    /// Replaces a peer's profile row. The caller resolves newest-wins and avatar
    /// reuse first.
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

    /// Sets or retracts one author's reaction. One reaction per author per
    /// message; a new emoji replaces the old one.
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

    /// Applies an unsend: clears body, quote and reactions and marks the message
    /// deleted, leaving a tombstone. By id, not timestamp (see editMessage(id:));
    /// quotes of it lose their copied text too. Returns whether a row existed.
    @discardableResult
    public func markDeleted(id: String) throws -> Bool {
        try db.transaction {
            guard let row = try db.query(
                "SELECT conversation_id, timestamp FROM messages WHERE id = ?", [.text(id)]
            ).first, let conversationId = row[0].string, let timestamp = row[1].int64 else { return false }
            try db.run(
                """
                UPDATE messages
                SET deleted = 1, body = '',
                    reply_to_timestamp = NULL, reply_to_author = NULL, reply_to_text = NULL
                WHERE id = ?
                """,
                [.text(id)]
            )
            try db.run(
                "UPDATE messages SET reply_to_text = '' WHERE conversation_id = ? AND reply_to_timestamp = ?",
                [.text(conversationId), .integer(timestamp)]
            )
            try db.run(
                "DELETE FROM reactions WHERE conversation_id = ? AND target_timestamp = ?",
                [.text(conversationId), .integer(timestamp)]
            )
            try db.run("DELETE FROM attachments WHERE message_id = ?", [.text(id)])
            return true
        }
    }

    /// Deletes a message and its reactions locally. The peer isn't notified.
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

    /// Deletes a conversation with its messages, reactions and attachments.
    public func deleteConversation(id: String) throws {
        try db.transaction {
            try db.run("DELETE FROM attachments WHERE message_id IN (SELECT id FROM messages WHERE conversation_id = ?)", [.text(id)])
            try db.run("DELETE FROM reactions WHERE conversation_id = ?", [.text(id)])
            try db.run("DELETE FROM messages WHERE conversation_id = ?", [.text(id)])
            try db.run("DELETE FROM conversations WHERE id = ?", [.text(id)])
        }
    }

    /// Marks outgoing messages with these timestamps as delivered or read.
    /// Read never downgrades to delivered.
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

    // MARK: - Group receipts

    /// Records each member's delivered/read state for a group message we sent.
    /// Read never downgrades to delivered.
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

    /// Member to status for one group message.
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

    // MARK: - Envelope dedup

    /// Atomically claims an envelope id. Returns false if it was already claimed
    /// by the other process or an earlier delivery. Together with the
    /// cross-process lock around decryption, each envelope is decrypted exactly
    /// once despite the shared ratchet state.
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

    /// Releases a claimed envelope id. Used for ephemeral content such as typing,
    /// which needs no dedup, so the table doesn't grow.
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

extension Int64 {
    func multipliedClamped(by other: Int64) -> Int64 {
        let (r, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? ((self < 0) != (other < 0) ? .min : .max) : r
    }

    func addingClamped(_ other: Int64) -> Int64 {
        let (r, overflow) = addingReportingOverflow(other)
        return overflow ? (other < 0 ? .min : .max) : r
    }
}
