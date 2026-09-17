package app.relaymsg.storage

/** Delivery state of a message. Stored as the lowercase string iOS uses. */
enum class MessageStatus(val wire: String) {
    SENDING("sending"),
    SENT("sent"),
    DELIVERED("delivered"),
    READ("read"),
    FAILED("failed"),
    RECEIVED("received"),
    ;

    companion object {
        fun from(wire: String): MessageStatus =
            entries.firstOrNull { it.wire == wire } ?: RECEIVED

        /**
         * Receipts never move backwards: a read message must not be downgraded to
         * delivered by a late-arriving delivery receipt.
         */
        fun MessageStatus.isDowngradeFrom(current: MessageStatus): Boolean =
            current == READ && this == DELIVERED
    }
}

data class Conversation(
    val id: String,
    val peerAccount: String,
    val peerUsername: String?,
    val lastMessageAt: Long?,
    val lastMessageBody: String?,
    val lastMessageIsOutgoing: Boolean,
    val lastMessageStatus: MessageStatus?,
    val groupId: String?,
    val pinnedAt: Long?,
    val readAt: Long,
    val disappearingSeconds: Long,
    val mediaRequiresBiometric: Boolean,
    val requireBiometricChat: Boolean,
    val hidePreviews: Boolean,
    val unreadCount: Int,
    val archived: Boolean,
    val label: String?,
    val screenSecurity: Boolean,
    val notificationSound: String?,
) {
    val isGroup: Boolean get() = groupId != null
    val isPinned: Boolean get() = pinnedAt != null
}

/**
 * A group's roster and metadata.
 *
 * The relay stores none of this — groups are client-authoritative and every
 * field here arrives inside an E2EE `GroupUpdate` — so this table is the only
 * source of truth (PROTOCOL.md §0.2, §7.3).
 */
data class StoredGroup(
    val id: String,
    val name: String,
    val description: String,
    val avatarData: ByteArray?,
    val distributionId: String,
    val revision: Long,
    val members: List<String>,
    val admins: List<String>,
    val isAnnounceOnly: Boolean,
) {
    override fun equals(other: Any?): Boolean = this === other || (
        other is StoredGroup && id == other.id && name == other.name &&
            description == other.description &&
            (avatarData?.contentEquals(other.avatarData ?: ByteArray(0)) ?: (other.avatarData == null)) &&
            distributionId == other.distributionId && revision == other.revision &&
            members == other.members && admins == other.admins &&
            isAnnounceOnly == other.isAnnounceOnly
        )

    override fun hashCode(): Int {
        var result = id.hashCode()
        result = 31 * result + name.hashCode()
        result = 31 * result + distributionId.hashCode()
        result = 31 * result + revision.hashCode()
        result = 31 * result + members.hashCode()
        return result
    }
}

/** A self-contained snapshot of the message being replied to. */
data class QuotedMessage(
    val targetTimestamp: Long,
    val author: String,
    val text: String,
)

data class MessageReaction(
    val author: String,
    val emoji: String,
    val isOutgoing: Boolean,
)

data class StoredAttachment(
    val id: String,
    val key: ByteArray,
    val digest: ByteArray,
    val contentType: String,
    val size: Long,
    val filename: String?,
    val width: Int,
    val height: Int,
    val isDownloaded: Boolean,
) {
    override fun equals(other: Any?): Boolean = this === other || (
        other is StoredAttachment && id == other.id &&
            key.contentEquals(other.key) && digest.contentEquals(other.digest) &&
            contentType == other.contentType && size == other.size &&
            filename == other.filename && width == other.width &&
            height == other.height && isDownloaded == other.isDownloaded
        )

    override fun hashCode(): Int = 31 * id.hashCode() + key.contentHashCode()
}

data class StoredProfile(
    val account: String,
    val displayName: String?,
    val avatarId: String?,
    val avatarData: ByteArray?,
    val revision: Long,
) {
    override fun equals(other: Any?): Boolean = this === other || (
        other is StoredProfile && account == other.account &&
            displayName == other.displayName && avatarId == other.avatarId &&
            revision == other.revision
        )

    override fun hashCode(): Int = 31 * account.hashCode() + revision.hashCode()
}

data class StoredPollVote(
    val pollAuthor: String,
    val pollTimestamp: Long,
    val voterAccount: String,
    val selectedOptions: List<Int>,
    val votedAt: Long,
)

enum class StoredCallDirection(val wire: String) { INCOMING("incoming"), OUTGOING("outgoing") }
enum class StoredCallKind(val wire: String) { AUDIO("audio"), VIDEO("video") }
enum class StoredCallOutcome(val wire: String) {
    COMPLETED("completed"), MISSED("missed"), DECLINED("declined"), FAILED("failed")
}

data class StoredCall(
    val id: String,
    val peerAccount: String,
    val peerName: String,
    val direction: StoredCallDirection,
    val kind: StoredCallKind,
    val startedAt: Long,
    val connectedAt: Long?,
    val endedAt: Long?,
    val outcome: StoredCallOutcome,
)

data class StoredMessage(
    val id: String,
    val conversationId: String,
    val isOutgoing: Boolean,
    val body: String,
    val timestamp: Long,
    val status: MessageStatus,
    val replyTo: QuotedMessage?,
    val reactions: List<MessageReaction>,
    val isDeleted: Boolean,
    val attachments: List<StoredAttachment>,
    val senderAccount: String?,
    val isPinned: Boolean,
    val isStarred: Boolean,
    val editedAt: Long?,
)

data class SearchResult(
    val messageId: String,
    val conversationId: String,
    val body: String,
    val timestamp: Long,
)
