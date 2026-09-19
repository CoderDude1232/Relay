package app.relaymsg.storage

import java.util.UUID
import org.json.JSONArray

/**
 * Conversations, messages and everything hanging off them. The counterpart of
 * iOS's `MessageStore`, over the same tables and column names.
 *
 * Every read returns plain value types so nothing above this layer touches a
 * cursor or holds the database open.
 */
class MessageStore(private val db: RelayDatabase) {

    private fun now() = System.currentTimeMillis()

    // ------------------------------------------------------- conversations

    /**
     * The conversation with a peer, creating it on first use.
     *
     * For a group, [account] is the group id — a group conversation is just a
     * conversation whose `group_id` is set.
     */
    fun conversation(account: String, username: String? = null): String {
        db.query(
            "SELECT id FROM conversations WHERE peer_account = ?",
            listOf(account),
        ) { it.string(0) }.firstOrNull()?.let { existing ->
            if (username != null) {
                db.run(
                    "UPDATE conversations SET peer_username = ? WHERE id = ? AND (peer_username IS NULL OR peer_username != ?)",
                    listOf(username, existing, username),
                )
            }
            return existing
        }
        val id = UUID.randomUUID().toString()
        db.run(
            "INSERT INTO conversations (id, peer_account, peer_username, created_at) VALUES (?, ?, ?, ?)",
            listOf(id, account, username, now()),
        )
        return id
    }

    fun conversations(includeArchived: Boolean = false): List<Conversation> {
        val filter = if (includeArchived) "" else "WHERE c.archived = 0"
        return db.query(
            """
            SELECT c.id, c.peer_account, c.peer_username, c.last_message_at, c.group_id,
                   c.pinned_at, c.read_at, c.disappearing_seconds, c.media_requires_biometric,
                   c.require_biometric_chat, c.hide_previews, c.archived, c.label,
                   c.screen_security, c.notification_sound,
                   (SELECT body FROM messages m WHERE m.conversation_id = c.id
                     ORDER BY m.timestamp DESC LIMIT 1),
                   (SELECT is_outgoing FROM messages m WHERE m.conversation_id = c.id
                     ORDER BY m.timestamp DESC LIMIT 1),
                   (SELECT status FROM messages m WHERE m.conversation_id = c.id
                     ORDER BY m.timestamp DESC LIMIT 1),
                   (SELECT COUNT(*) FROM messages m WHERE m.conversation_id = c.id
                     AND m.is_outgoing = 0 AND m.timestamp > c.read_at)
            FROM conversations c
            $filter
            ORDER BY c.pinned_at IS NULL, c.pinned_at DESC, c.last_message_at DESC
            """,
        ) { row ->
            Conversation(
                id = row.string(0),
                peerAccount = row.string(1),
                peerUsername = row.stringOrNull(2),
                lastMessageAt = row.longOrNull(3),
                groupId = row.stringOrNull(4),
                pinnedAt = row.longOrNull(5),
                readAt = row.long(6),
                disappearingSeconds = row.long(7),
                mediaRequiresBiometric = row.boolean(8),
                requireBiometricChat = row.boolean(9),
                hidePreviews = row.boolean(10),
                archived = row.boolean(11),
                label = row.stringOrNull(12),
                screenSecurity = row.boolean(13),
                notificationSound = row.stringOrNull(14),
                lastMessageBody = row.stringOrNull(15),
                lastMessageIsOutgoing = !row.isNull(16) && row.boolean(16),
                lastMessageStatus = row.stringOrNull(17)?.let(MessageStatus::from),
                unreadCount = row.int(18),
            )
        }
    }

    fun peerAccount(conversationId: String): String? = db.query(
        "SELECT peer_account FROM conversations WHERE id = ?",
        listOf(conversationId),
    ) { it.string(0) }.firstOrNull()

    fun setConversationLabel(conversationId: String, label: String?) =
        db.run("UPDATE conversations SET label = ? WHERE id = ?", listOf(label, conversationId))

    fun setConversationPinned(conversationId: String, pinned: Boolean) = db.run(
        "UPDATE conversations SET pinned_at = ? WHERE id = ?",
        listOf(if (pinned) now() else null, conversationId),
    )

    fun setConversationArchived(conversationId: String, archived: Boolean) = db.run(
        "UPDATE conversations SET archived = ? WHERE id = ?",
        listOf(if (archived) 1 else 0, conversationId),
    )

    fun setDisappearingSeconds(conversationId: String, seconds: Long) = db.run(
        "UPDATE conversations SET disappearing_seconds = ? WHERE id = ?",
        listOf(seconds, conversationId),
    )

    fun markConversationRead(conversationId: String, at: Long = now()) = db.run(
        "UPDATE conversations SET read_at = ? WHERE id = ?",
        listOf(at, conversationId),
    )

    /** Forces an unread badge by rewinding the read marker behind the last message. */
    fun markConversationUnread(conversationId: String) = db.run(
        """
        UPDATE conversations SET read_at =
            COALESCE((SELECT MAX(timestamp) - 1 FROM messages
                      WHERE conversation_id = ? AND is_outgoing = 0), 0)
        WHERE id = ?
        """,
        listOf(conversationId, conversationId),
    )

    fun setConversationPrivacy(
        conversationId: String,
        mediaRequiresBiometric: Boolean? = null,
        requireBiometricChat: Boolean? = null,
        hidePreviews: Boolean? = null,
        screenSecurity: Boolean? = null,
    ) {
        mediaRequiresBiometric?.let {
            db.run("UPDATE conversations SET media_requires_biometric = ? WHERE id = ?", listOf(if (it) 1 else 0, conversationId))
        }
        requireBiometricChat?.let {
            db.run("UPDATE conversations SET require_biometric_chat = ? WHERE id = ?", listOf(if (it) 1 else 0, conversationId))
        }
        hidePreviews?.let {
            db.run("UPDATE conversations SET hide_previews = ? WHERE id = ?", listOf(if (it) 1 else 0, conversationId))
        }
        screenSecurity?.let {
            db.run("UPDATE conversations SET screen_security = ? WHERE id = ?", listOf(if (it) 1 else 0, conversationId))
        }
    }

    fun setNotificationSound(conversationId: String, sound: String?) = db.run(
        "UPDATE conversations SET notification_sound = ? WHERE id = ?",
        listOf(sound, conversationId),
    )

    fun deleteConversation(id: String) = db.transaction {
        db.run("DELETE FROM attachments WHERE message_id IN (SELECT id FROM messages WHERE conversation_id = ?)", listOf(id))
        db.run("DELETE FROM reactions WHERE conversation_id = ?", listOf(id))
        db.run("DELETE FROM message_receipts WHERE conversation_id = ?", listOf(id))
        db.run("DELETE FROM messages WHERE conversation_id = ?", listOf(id))
        db.run("DELETE FROM conversations WHERE id = ?", listOf(id))
    }

    // ------------------------------------------------------------ messages

    /**
     * Inserts a message, returning false if the id already exists.
     *
     * Incoming messages use the **envelope id** as the row id, which is what makes
     * at-least-once delivery safe: a redelivered envelope collides here and is
     * silently ignored (PROTOCOL.md §4.3).
     */
    fun insertMessage(
        id: String,
        conversationId: String,
        isOutgoing: Boolean,
        body: String,
        timestamp: Long,
        status: MessageStatus,
        replyTo: QuotedMessage? = null,
        attachments: List<StoredAttachment> = emptyList(),
        senderAccount: String? = null,
    ): Boolean = db.transaction {
        val existing = db.query("SELECT 1 FROM messages WHERE id = ?", listOf(id)) { it.int(0) }
        if (existing.isNotEmpty()) return@transaction false

        val expiresAt = db.query(
            "SELECT disappearing_seconds FROM conversations WHERE id = ?",
            listOf(conversationId),
        ) { it.long(0) }.firstOrNull()?.takeIf { it > 0 }?.let { timestamp + it * 1000 }

        db.run(
            """
            INSERT INTO messages
                (id, conversation_id, is_outgoing, body, timestamp, status, created_at,
                 reply_to_timestamp, reply_to_author, reply_to_text, sender_account, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            listOf(
                id, conversationId, if (isOutgoing) 1 else 0, body, timestamp, status.wire, now(),
                replyTo?.targetTimestamp, replyTo?.author, replyTo?.text, senderAccount, expiresAt,
            ),
        )
        attachments.forEachIndexed { ordinal, attachment ->
            db.run(
                """
                INSERT OR REPLACE INTO attachments
                    (id, message_id, key, digest, content_type, size, filename, width, height, downloaded, ordinal)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                listOf(
                    attachment.id, id, attachment.key, attachment.digest, attachment.contentType,
                    attachment.size, attachment.filename, attachment.width, attachment.height,
                    if (attachment.isDownloaded) 1 else 0, ordinal,
                ),
            )
        }
        db.run(
            "UPDATE conversations SET last_message_at = ? WHERE id = ? AND (last_message_at IS NULL OR last_message_at < ?)",
            listOf(timestamp, conversationId, timestamp),
        )
        true
    }

    fun messages(conversationId: String, limit: Int = 100): List<StoredMessage> {
        val rows = db.query(
            """
            SELECT id, conversation_id, is_outgoing, body, timestamp, status,
                   reply_to_timestamp, reply_to_author, reply_to_text, deleted,
                   sender_account, pinned, starred, edited_at
            FROM (
                SELECT * FROM messages WHERE conversation_id = ?
                ORDER BY timestamp DESC LIMIT ?
            ) ORDER BY timestamp ASC
            """,
            listOf(conversationId, limit),
        ) { row ->
            StoredMessage(
                id = row.string(0),
                conversationId = row.string(1),
                isOutgoing = row.boolean(2),
                body = row.string(3),
                timestamp = row.long(4),
                status = MessageStatus.from(row.string(5)),
                replyTo = row.longOrNull(6)?.let {
                    QuotedMessage(it, row.stringOrNull(7).orEmpty(), row.stringOrNull(8).orEmpty())
                },
                isDeleted = row.boolean(9),
                senderAccount = row.stringOrNull(10),
                isPinned = row.boolean(11),
                isStarred = row.boolean(12),
                editedAt = row.longOrNull(13),
                reactions = emptyList(),
                attachments = emptyList(),
            )
        }
        if (rows.isEmpty()) return rows
        val reactions = reactionsFor(conversationId)
        return rows.map { message ->
            message.copy(
                reactions = reactions[message.timestamp].orEmpty(),
                attachments = attachmentsFor(message.id),
            )
        }
    }

    private fun reactionsFor(conversationId: String): Map<Long, List<MessageReaction>> = db.query(
        "SELECT target_timestamp, author, emoji, is_outgoing FROM reactions WHERE conversation_id = ?",
        listOf(conversationId),
    ) { row ->
        row.long(0) to MessageReaction(row.string(1), row.string(2), row.boolean(3))
    }.groupBy({ it.first }, { it.second })

    private fun attachmentsFor(messageId: String): List<StoredAttachment> = db.query(
        """
        SELECT id, key, digest, content_type, size, filename, width, height, downloaded
        FROM attachments WHERE message_id = ? ORDER BY ordinal ASC
        """,
        listOf(messageId),
    ) { row ->
        StoredAttachment(
            id = row.string(0), key = row.blob(1), digest = row.blob(2),
            contentType = row.string(3), size = row.long(4), filename = row.stringOrNull(5),
            width = row.int(6), height = row.int(7), isDownloaded = row.boolean(8),
        )
    }

    fun updateStatus(messageId: String, status: MessageStatus) = db.run(
        "UPDATE messages SET status = ? WHERE id = ?",
        listOf(status.wire, messageId),
    )

    /**
     * Pins a message, clearing any previous pin in the same conversation.
     *
     * One per conversation because [pinnedMessage] only reads one; a list of
     * pins would be a different feature with a different query.
     */
    fun setMessagePinned(conversationId: String, id: String, pinned: Boolean) = db.transaction {
        if (pinned) {
            db.run("UPDATE messages SET pinned = 0 WHERE conversation_id = ?", listOf(conversationId))
        }
        db.run("UPDATE messages SET pinned = ? WHERE id = ?", listOf(if (pinned) 1 else 0, id))
    }

    fun setMessageStarred(id: String, starred: Boolean) =
        db.run("UPDATE messages SET starred = ? WHERE id = ?", listOf(if (starred) 1 else 0, id))

    /** Only the original author may edit; the recipient locates it by timestamp. */
    fun editMessage(conversationId: String, targetTimestamp: Long, newBody: String) = db.run(
        "UPDATE messages SET body = ?, edited_at = ? WHERE conversation_id = ? AND timestamp = ?",
        listOf(newBody, now(), conversationId, targetTimestamp),
    )

    /**
     * Unsend: keeps the row and its place in the timeline but clears the body, so
     * the UI can render a "message was deleted" tombstone.
     */
    fun markDeleted(conversationId: String, targetTimestamp: Long): Boolean {
        db.run(
            "UPDATE messages SET deleted = 1, body = '' WHERE conversation_id = ? AND timestamp = ?",
            listOf(conversationId, targetTimestamp),
        )
        return true
    }

    fun deleteMessage(id: String) = db.transaction {
        db.run("DELETE FROM attachments WHERE message_id = ?", listOf(id))
        db.run("DELETE FROM messages WHERE id = ?", listOf(id))
    }

    /** Removes messages whose disappearing timer has elapsed. */
    fun deleteExpiredMessages(now: Long = now()): Int {
        val ids = db.query(
            "SELECT id FROM messages WHERE expires_at IS NOT NULL AND expires_at <= ?",
            listOf(now),
        ) { it.string(0) }
        ids.forEach { deleteMessage(it) }
        return ids.size
    }

    fun starredMessages(conversationId: String): List<StoredMessage> =
        messages(conversationId, limit = 1000).filter { it.isStarred }

    fun pinnedMessage(conversationId: String): StoredMessage? =
        messages(conversationId, limit = 1000).lastOrNull { it.isPinned }

    fun searchMessages(query: String, limit: Int = 100): List<SearchResult> = db.query(
        """
        SELECT id, conversation_id, body, timestamp FROM messages
        WHERE deleted = 0 AND body LIKE ? ESCAPE '\'
        ORDER BY timestamp DESC LIMIT ?
        """,
        listOf("%" + query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%", limit),
    ) { SearchResult(it.string(0), it.string(1), it.string(2), it.long(3)) }

    // ------------------------------------------------------------ receipts

    /**
     * Applies a 1:1 receipt.
     *
     * A read receipt never downgrades to delivered, even if the delivery receipt
     * arrives later — at-least-once delivery makes out-of-order receipts normal.
     */
    fun applyReceipt(conversationId: String, timestamps: List<Long>, status: MessageStatus) {
        if (timestamps.isEmpty()) return
        val placeholders = timestamps.joinToString(",") { "?" }
        val guard = if (status == MessageStatus.DELIVERED) " AND status != 'read'" else ""
        db.run(
            """
            UPDATE messages SET status = ?
            WHERE conversation_id = ? AND is_outgoing = 1 AND timestamp IN ($placeholders)$guard
            """,
            listOf(status.wire, conversationId) + timestamps,
        )
    }

    /** Records one member's state for a group message the local user authored. */
    fun recordGroupReceipt(
        conversationId: String,
        member: String,
        timestamps: List<Long>,
        status: MessageStatus,
    ) {
        timestamps.forEach { timestamp ->
            val current = db.query(
                """
                SELECT status FROM message_receipts
                WHERE conversation_id = ? AND message_timestamp = ? AND member_account = ?
                """,
                listOf(conversationId, timestamp, member),
            ) { MessageStatus.from(it.string(0)) }.firstOrNull()
            if (current == MessageStatus.READ && status == MessageStatus.DELIVERED) return@forEach
            db.run(
                """
                INSERT OR REPLACE INTO message_receipts
                    (conversation_id, message_timestamp, member_account, status)
                VALUES (?, ?, ?, ?)
                """,
                listOf(conversationId, timestamp, member, status.wire),
            )
        }
    }

    fun groupReceipts(conversationId: String, messageTimestamp: Long): Map<String, MessageStatus> =
        db.query(
            """
            SELECT member_account, status FROM message_receipts
            WHERE conversation_id = ? AND message_timestamp = ?
            """,
            listOf(conversationId, messageTimestamp),
        ) { it.string(0) to MessageStatus.from(it.string(1)) }.toMap()

    // ----------------------------------------------------------- reactions

    /** One reaction per author per message; a new one replaces the previous. */
    fun setReaction(
        conversationId: String,
        targetTimestamp: Long,
        author: String,
        isOutgoing: Boolean,
        emoji: String,
        remove: Boolean,
    ) {
        if (remove) {
            db.run(
                "DELETE FROM reactions WHERE conversation_id = ? AND target_timestamp = ? AND author = ?",
                listOf(conversationId, targetTimestamp, author),
            )
            return
        }
        db.run(
            """
            INSERT OR REPLACE INTO reactions
                (conversation_id, target_timestamp, author, is_outgoing, emoji, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            listOf(conversationId, targetTimestamp, author, if (isOutgoing) 1 else 0, emoji, now()),
        )
    }

    // -------------------------------------------------------------- groups

    fun upsertGroup(
        id: String,
        name: String,
        distributionId: String,
        revision: Long,
        members: List<String>,
        admins: List<String>,
        isAnnounceOnly: Boolean = false,
    ) = db.transaction {
        db.run(
            """
            INSERT INTO group_state (id, name, distribution_id, revision, admins, is_announce_only)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET
                name = excluded.name,
                distribution_id = excluded.distribution_id,
                revision = excluded.revision,
                admins = excluded.admins,
                is_announce_only = excluded.is_announce_only
            """,
            listOf(
                id, name, distributionId, revision,
                JSONArray(admins).toString(), if (isAnnounceOnly) 1 else 0,
            ),
        )
        db.run("DELETE FROM group_members WHERE group_id = ?", listOf(id))
        members.forEach {
            db.run("INSERT OR IGNORE INTO group_members (group_id, account_id) VALUES (?, ?)", listOf(id, it))
        }
        // A group conversation is a conversation whose peer_account is the group id.
        val conversationId = conversation(account = id, username = name)
        db.run("UPDATE conversations SET group_id = ? WHERE id = ?", listOf(id, conversationId))
    }

    fun group(id: String): StoredGroup? = db.query(
        """
        SELECT id, name, distribution_id, revision, description, avatar_data, admins, is_announce_only
        FROM group_state WHERE id = ?
        """,
        listOf(id),
    ) { row ->
        StoredGroup(
            id = row.string(0),
            name = row.string(1),
            distributionId = row.string(2),
            revision = row.long(3),
            description = row.string(4),
            avatarData = row.blobOrNull(5),
            admins = row.string(6).toStringList(),
            isAnnounceOnly = row.boolean(7),
            members = emptyList(),
        )
    }.firstOrNull()?.let { group ->
        group.copy(
            members = db.query(
                "SELECT account_id FROM group_members WHERE group_id = ?",
                listOf(group.id),
            ) { it.string(0) },
        )
    }

    fun groupConversationId(groupId: String): String? = db.query(
        "SELECT id FROM conversations WHERE group_id = ?",
        listOf(groupId),
    ) { it.string(0) }.firstOrNull()

    fun setGroupAdmins(id: String, admins: List<String>) = db.run(
        "UPDATE group_state SET admins = ? WHERE id = ?",
        listOf(JSONArray(admins).toString(), id),
    )

    fun setGroupAnnounceOnly(id: String, isAnnounceOnly: Boolean) = db.run(
        "UPDATE group_state SET is_announce_only = ? WHERE id = ?",
        listOf(if (isAnnounceOnly) 1 else 0, id),
    )

    fun setGroupDescription(id: String, description: String) =
        db.run("UPDATE group_state SET description = ? WHERE id = ?", listOf(description, id))

    fun setGroupAvatar(id: String, avatarData: ByteArray?) =
        db.run("UPDATE group_state SET avatar_data = ? WHERE id = ?", listOf(avatarData, id))

    private fun String.toStringList(): List<String> = runCatching {
        JSONArray(this).let { array -> (0 until array.length()).map(array::getString) }
    }.getOrDefault(emptyList())

    // ------------------------------------------------------------ profiles

    fun peerProfile(account: String): StoredProfile? = db.query(
        """
        SELECT account_id, display_name, avatar_id, avatar_data, revision, status, bio
        FROM profiles WHERE account_id = ?
        """,
        listOf(account),
    ) { row ->
        StoredProfile(
            account = row.string(0),
            displayName = row.stringOrNull(1),
            avatarId = row.stringOrNull(2),
            avatarData = row.blobOrNull(3),
            revision = row.long(4),
            status = row.stringOrNull(5),
            bio = row.stringOrNull(6),
        )
    }.firstOrNull()

    /** Newest wins: an older profile revision is ignored. */
    /**
     * Applies a peer's published profile. Newest revision wins; an older one is
     * dropped, which is what keeps two of their devices from fighting.
     *
     * Every field is replaced, so a cleared status or bio arrives as null and
     * clears here too. The avatar *bytes* are deliberately not touched — they
     * arrive later, by download, through [setProfileAvatar].
     */
    fun upsertProfile(
        account: String,
        displayName: String?,
        avatarId: String?,
        revision: Long,
        status: String? = null,
        bio: String? = null,
    ) {
        val existing = peerProfile(account)
        if (existing != null && existing.revision >= revision) return
        db.run(
            """
            INSERT INTO profiles (account_id, display_name, avatar_id, revision, status, bio)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (account_id) DO UPDATE SET
                display_name = excluded.display_name,
                avatar_id    = excluded.avatar_id,
                revision     = excluded.revision,
                status       = excluded.status,
                bio          = excluded.bio
            """,
            listOf(account, displayName, avatarId, revision, status, bio),
        )
    }

    /**
     * Stores a downloaded avatar.
     *
     * Separate from [upsertProfile], and with no revision guard, because the
     * picture arrives *after* the profile that announced it and carries the
     * same revision — under the newest-wins rule it would be rejected as stale,
     * and every peer avatar would silently fail to save.
     */
    fun setProfileAvatar(account: String, avatarId: String?, avatarData: ByteArray?) = db.run(
        """
        INSERT INTO profiles (account_id, avatar_id, avatar_data, revision)
        VALUES (?, ?, ?, 0)
        ON CONFLICT (account_id) DO UPDATE SET
            avatar_id   = excluded.avatar_id,
            avatar_data = excluded.avatar_data
        """,
        listOf(account, avatarId, avatarData),
    )

    // --------------------------------------------------------------- calls

    fun calls(limit: Int = 100): List<StoredCall> = db.query(
        """
        SELECT id, peer_account, peer_name, direction, kind, started_at, connected_at, ended_at, outcome
        FROM calls ORDER BY started_at DESC LIMIT ?
        """,
        listOf(limit),
    ) { row ->
        StoredCall(
            id = row.string(0),
            peerAccount = row.string(1),
            peerName = row.string(2),
            direction = StoredCallDirection.entries.first { it.wire == row.string(3) },
            kind = StoredCallKind.entries.first { it.wire == row.string(4) },
            startedAt = row.long(5),
            connectedAt = row.longOrNull(6),
            endedAt = row.longOrNull(7),
            outcome = StoredCallOutcome.entries.first { it.wire == row.string(8) },
        )
    }

    fun upsertCall(call: StoredCall) = db.run(
        """
        INSERT OR REPLACE INTO calls
            (id, peer_account, peer_name, direction, kind, started_at, connected_at, ended_at, outcome)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        listOf(
            call.id, call.peerAccount, call.peerName, call.direction.wire, call.kind.wire,
            call.startedAt, call.connectedAt, call.endedAt, call.outcome.wire,
        ),
    )

    fun clearCalls() = db.run("DELETE FROM calls")

    // --------------------------------------------------------------- polls

    fun upsertPollVote(
        conversationId: String,
        pollAuthor: String,
        pollTimestamp: Long,
        voterAccount: String,
        selectedOptions: List<Int>,
        votedAt: Long,
    ) = db.run(
        """
        INSERT OR REPLACE INTO poll_votes
            (conversation_id, poll_author, poll_timestamp, voter_account, selected_options, voted_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        listOf(
            conversationId, pollAuthor, pollTimestamp, voterAccount,
            JSONArray(selectedOptions).toString(), votedAt,
        ),
    )

    fun pollVotes(conversationId: String, pollAuthor: String, pollTimestamp: Long): List<StoredPollVote> =
        db.query(
            """
            SELECT poll_author, poll_timestamp, voter_account, selected_options, voted_at
            FROM poll_votes WHERE conversation_id = ? AND poll_author = ? AND poll_timestamp = ?
            """,
            listOf(conversationId, pollAuthor, pollTimestamp),
        ) { row ->
            val options = runCatching {
                JSONArray(row.string(3)).let { a -> (0 until a.length()).map(a::getInt) }
            }.getOrDefault(emptyList())
            StoredPollVote(row.string(0), row.long(1), row.string(2), options, row.long(4))
        }

    // ------------------------------------------------- attachments and dedup

    fun markAttachmentDownloaded(id: String) =
        db.run("UPDATE attachments SET downloaded = 1 WHERE id = ?", listOf(id))

    /**
     * Claims an envelope for processing, returning false if it was already
     * claimed.
     *
     * Double Ratchet decryption is destructive, so exactly one process may
     * decrypt a given envelope. This is the dedup point required by at-least-once
     * delivery (PROTOCOL.md §4.3), and it is shared with the push path.
     */
    fun claimEnvelope(id: String): Boolean = db.transaction {
        val seen = db.query("SELECT 1 FROM processed_envelopes WHERE id = ?", listOf(id)) { it.int(0) }
        if (seen.isNotEmpty()) return@transaction false
        db.run("INSERT INTO processed_envelopes (id, processed_at) VALUES (?, ?)", listOf(id, now()))
        true
    }

    fun isEnvelopeProcessed(id: String): Boolean =
        db.query("SELECT 1 FROM processed_envelopes WHERE id = ?", listOf(id)) { it.int(0) }.isNotEmpty()

    /** Releases a claim so the envelope can be retried (used when processing aborts). */
    fun releaseEnvelope(id: String) =
        db.run("DELETE FROM processed_envelopes WHERE id = ?", listOf(id))

    // ------------------------------------------------------------------ kv

    fun kvGet(key: String): ByteArray? =
        db.query("SELECT value FROM kv WHERE key = ?", listOf(key)) { it.blob(0) }.firstOrNull()

    fun kvPut(key: String, value: ByteArray) =
        db.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", listOf(key, value))

    fun kvDelete(key: String) = db.run("DELETE FROM kv WHERE key = ?", listOf(key))

    /**
     * Every value whose key starts with [prefix].
     *
     * The kv table doubles as a small document store for things with no table
     * of their own — scheduled messages, per-conversation settings — and those
     * need to be read back as a set.
     */
    fun kvPrefix(prefix: String): List<Pair<String, ByteArray>> = db.query(
        "SELECT key, value FROM kv WHERE key LIKE ? ESCAPE '\\'",
        // Escaped, or a key containing % or _ would match far more than itself.
        listOf(prefix.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"),
    ) { row -> row.string(0) to row.blob(1) }
}
