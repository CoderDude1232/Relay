package app.relaymsg.core

import app.relaymsg.storage.MessageStatus
import org.json.JSONArray
import org.json.JSONObject

/**
 * The backed-up shape of local chat state.
 *
 * Field names are iOS's `MessagingService.BackupSnapshot` Codable keys, not a
 * Kotlin-idiomatic renaming: a backup taken on one client has to restore on the
 * other, so this JSON is as much a wire contract as anything in `proto/`.
 *
 * Deliberately absent: encryption sessions. They are Keystore-bound and cannot
 * travel; restoring brings back history, and sessions re-key on next contact —
 * the same safety-number change a reinstall causes. Attachments are absent too;
 * only their messages come back.
 */
data class BackupSnapshot(
    val version: Int = VERSION,
    val conversations: List<Conversation>,
    val groups: List<Group>,
) {
    data class Message(
        val id: String,
        val body: String,
        val timestamp: Long,
        val isOutgoing: Boolean,
        val status: String,
        val senderAccount: String?,
        val replyTimestamp: Long?,
        val replyAuthor: String?,
        val replyText: String?,
    )

    data class Conversation(
        val peerAccount: String,
        val username: String?,
        val groupId: String?,
        val messages: List<Message>,
    )

    data class Group(
        val id: String,
        val name: String,
        val distributionId: String,
        val revision: Long,
        val members: List<String>,
        val admins: List<String>,
        val isAnnounceOnly: Boolean,
    )

    fun toJson(): JSONObject = JSONObject()
        .put("version", version)
        .put(
            "conversations",
            JSONArray().apply {
                conversations.forEach { conversation ->
                    put(
                        JSONObject()
                            .put("peerAccount", conversation.peerAccount)
                            // Swift's JSONEncoder omits nil optionals rather than
                            // writing null, and its decoder accepts either; we
                            // omit so the bytes match what iOS would have written.
                            .putOpt("username", conversation.username)
                            .putOpt("groupId", conversation.groupId)
                            .put(
                                "messages",
                                JSONArray().apply {
                                    conversation.messages.forEach { message ->
                                        put(
                                            JSONObject()
                                                .put("id", message.id)
                                                .put("body", message.body)
                                                .put("timestamp", message.timestamp)
                                                .put("isOutgoing", message.isOutgoing)
                                                .put("status", message.status)
                                                .putOpt("senderAccount", message.senderAccount)
                                                .putOpt("replyTimestamp", message.replyTimestamp)
                                                .putOpt("replyAuthor", message.replyAuthor)
                                                .putOpt("replyText", message.replyText),
                                        )
                                    }
                                },
                            ),
                    )
                }
            },
        )
        .put(
            "groups",
            JSONArray().apply {
                groups.forEach { group ->
                    put(
                        JSONObject()
                            .put("id", group.id)
                            .put("name", group.name)
                            .put("distributionId", group.distributionId)
                            .put("revision", group.revision)
                            .put("members", JSONArray(group.members))
                            .put("admins", JSONArray(group.admins))
                            .put("isAnnounceOnly", group.isAnnounceOnly),
                    )
                }
            },
        )

    fun encode(): ByteArray = toJson().toString().toByteArray()

    companion object {
        const val VERSION = 1

        fun decode(bytes: ByteArray): BackupSnapshot = fromJson(JSONObject(String(bytes)))

        fun fromJson(json: JSONObject): BackupSnapshot {
            val conversations = json.optJSONArray("conversations").objects().map { conversation ->
                Conversation(
                    peerAccount = conversation.optString("peerAccount"),
                    username = conversation.stringOrNull("username"),
                    groupId = conversation.stringOrNull("groupId"),
                    messages = conversation.optJSONArray("messages").objects().map { message ->
                        Message(
                            id = message.optString("id"),
                            body = message.optString("body"),
                            timestamp = message.optLong("timestamp"),
                            isOutgoing = message.optBoolean("isOutgoing"),
                            status = message.optString("status", MessageStatus.RECEIVED.wire),
                            senderAccount = message.stringOrNull("senderAccount"),
                            replyTimestamp = if (message.isNull("replyTimestamp")) {
                                null
                            } else {
                                message.optLong("replyTimestamp")
                            },
                            replyAuthor = message.stringOrNull("replyAuthor"),
                            replyText = message.stringOrNull("replyText"),
                        )
                    },
                )
            }
            val groups = json.optJSONArray("groups").objects().map { group ->
                Group(
                    id = group.optString("id"),
                    name = group.optString("name"),
                    distributionId = group.optString("distributionId"),
                    revision = group.optLong("revision"),
                    members = group.optJSONArray("members").strings(),
                    admins = group.optJSONArray("admins").strings(),
                    isAnnounceOnly = group.optBoolean("isAnnounceOnly"),
                )
            }
            return BackupSnapshot(
                version = json.optInt("version", VERSION),
                conversations = conversations,
                groups = groups,
            )
        }

        private fun JSONArray?.objects(): List<JSONObject> =
            (0 until (this?.length() ?: 0)).mapNotNull { this?.optJSONObject(it) }

        private fun JSONArray?.strings(): List<String> =
            (0 until (this?.length() ?: 0)).mapNotNull { this?.optString(it)?.takeIf(String::isNotEmpty) }

        private fun JSONObject.stringOrNull(key: String): String? =
            if (isNull(key)) null else optString(key).takeIf(String::isNotEmpty)
    }
}
