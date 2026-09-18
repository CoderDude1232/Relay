package app.relaymsg.core

import org.json.JSONObject

/** An ICE candidate as it travels between clients. */
data class ParsedIceCandidate(
    val sdp: String,
    val sdpMid: String,
    val sdpMLineIndex: Int,
)

/**
 * The wire encoding of an ICE candidate (PROTOCOL.md §6.12).
 *
 * `CallMessage.ice` is a JSON object, not an SDP line, and its shape is iOS's
 * (`CallManager.iceJSON` / `parseIce`):
 *
 * ```json
 * {"candidate": "candidate:1 1 udp ...", "sdpMid": "0", "sdpMLineIndex": 0}
 * ```
 *
 * Two things must not drift. The key is **`candidate`**, not `sdp` — it follows
 * the browser `RTCIceCandidate` field name rather than WebRTC's native one. And
 * `sdpMid` is always written, as `""` when absent, because iOS's parser requires
 * all three keys and drops the candidate if any is missing.
 */
object IceCandidateJson {

    fun encode(sdp: String, sdpMid: String?, sdpMLineIndex: Int): String =
        JSONObject()
            .put("candidate", sdp)
            .put("sdpMid", sdpMid.orEmpty())
            .put("sdpMLineIndex", sdpMLineIndex)
            .toString()

    /** Null for anything unusable — a bad candidate is dropped, never guessed at. */
    fun decode(json: String): ParsedIceCandidate? = runCatching {
        val obj = JSONObject(json)
        val sdp = obj.optString("candidate")
        if (sdp.isEmpty()) return null
        ParsedIceCandidate(
            sdp = sdp,
            sdpMid = obj.optString("sdpMid"),
            sdpMLineIndex = obj.optInt("sdpMLineIndex", 0),
        )
    }.getOrNull()
}
