package app.relaymsg.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * A poll, as it is stored in a message row.
 *
 * Polls have no table of their own on either client: a poll is an ordinary
 * message whose body is the marker `__poll__:` followed by this JSON, so it
 * lands in the thread in the right place and sorts with everything else. Votes
 * are separate, in `poll_votes`, keyed by (author, timestamp) — the poll's own
 * timestamp is its id.
 *
 * The shape is iOS's `PollPayload`, key for key, because a linked device reads
 * these rows directly.
 */
data class PollPayload(
    val question: String,
    val options: List<String>,
    val multiSelect: Boolean,
) {
    fun encodeBody(): String = MARKER + JSONObject()
        .put("question", question)
        .put("options", JSONArray(options))
        .put("multiSelect", multiSelect)
        .toString()

    companion object {
        const val MARKER = "__poll__:"

        /** Null for any message that is not a poll. */
        fun fromBody(body: String): PollPayload? {
            if (!body.startsWith(MARKER)) return null
            return runCatching {
                val json = JSONObject(body.removePrefix(MARKER))
                val options = json.optJSONArray("options") ?: JSONArray()
                PollPayload(
                    question = json.getString("question"),
                    options = (0 until options.length()).map { options.getString(it) },
                    multiSelect = json.optBoolean("multiSelect"),
                )
            }.getOrNull()
        }
    }
}
