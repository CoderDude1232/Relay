package app.relaymsg.core

import org.json.JSONObject

/**
 * A live location update, as it rides in a message body.
 *
 * Like the notepad and polls, location has no message type of its own: it is an
 * ordinary encrypted message whose body carries a marker, so the relay cannot
 * tell it from chat. The newest one from a sender replaces the previous, which
 * is what makes it a single moving bubble rather than a trail of pins.
 *
 * Field names are iOS's, spelled exactly — `lat`, `lng`, `exp`, `stop`.
 */
data class LocationPayload(
    val lat: Double,
    val lng: Double,
    /** Milliseconds since epoch; after this the bubble stops moving. */
    val exp: Long,
    /** The sender ending the share early. Carries their last position. */
    val stop: Boolean,
) {
    fun isExpired(now: Long = System.currentTimeMillis()): Boolean = now > exp

    /** Whether the bubble should still be shown as live. */
    fun isLive(now: Long = System.currentTimeMillis()): Boolean = !stop && !isExpired(now)

    fun encodeBody(): String = MARKER + JSONObject()
        .put("lat", lat)
        .put("lng", lng)
        .put("exp", exp)
        .put("stop", stop)
        .toString()

    companion object {
        const val MARKER = "__relay_loc__"

        fun fromBody(body: String): LocationPayload? {
            if (!body.startsWith(MARKER)) return null
            return runCatching {
                val json = JSONObject(body.removePrefix(MARKER))
                LocationPayload(
                    lat = json.getDouble("lat"),
                    lng = json.getDouble("lng"),
                    exp = json.getLong("exp"),
                    stop = json.optBoolean("stop"),
                )
            }.getOrNull()
        }
    }
}
