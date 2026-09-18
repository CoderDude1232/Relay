package app.relaymsg.call

import android.content.Intent

/**
 * The metadata a call push carries (PROTOCOL.md §7.5.1).
 *
 * Deliberately thin, and deliberately no thinner than iOS's VoIP payload: enough
 * to ring with a name, and nothing else. The OFFER itself — the SDP, and
 * everything that actually describes the call — arrives as an ordinary encrypted
 * envelope over the queue, so Google's infrastructure learns only that an account
 * this device already knows is calling.
 */
data class CallWake(
    val callId: String,
    val callerAccount: String,
    val callerName: String,
    val isVideo: Boolean,
) {
    /** What to show while the caller is still just an account id. */
    val displayName: String get() = callerName.ifBlank { callerAccount.take(8) }

    fun putInto(intent: Intent): Intent = intent
        .putExtra(EXTRA_CALL_ID, callId)
        .putExtra(EXTRA_CALLER_ACCOUNT, callerAccount)
        .putExtra(EXTRA_CALLER_NAME, callerName)
        .putExtra(EXTRA_VIDEO, isVideo)

    companion object {
        /** `data.type` for a call wake, as opposed to `"wake"` / `"msg"`. */
        const val TYPE = "call"

        private const val EXTRA_CALL_ID = "app.relaymsg.call.CALL_ID"
        private const val EXTRA_CALLER_ACCOUNT = "app.relaymsg.call.CALLER_ACCOUNT"
        private const val EXTRA_CALLER_NAME = "app.relaymsg.call.CALLER_NAME"
        private const val EXTRA_VIDEO = "app.relaymsg.call.VIDEO"

        /** Reads an FCM data block. Null when the relay sent something unusable. */
        fun from(data: Map<String, String>): CallWake? {
            val callId = data["call_id"]?.takeIf { it.isNotBlank() } ?: return null
            val caller = data["caller_account"]?.takeIf { it.isNotBlank() } ?: return null
            return CallWake(
                callId = callId,
                callerAccount = caller,
                // The relay omits caller_name when it is empty, same as the VoIP
                // payload — so its absence is normal, not an error.
                callerName = data["caller_name"].orEmpty(),
                isVideo = data["kind"] == "video",
            )
        }

        fun fromIntent(intent: Intent): CallWake? {
            val callId = intent.getStringExtra(EXTRA_CALL_ID) ?: return null
            val caller = intent.getStringExtra(EXTRA_CALLER_ACCOUNT) ?: return null
            return CallWake(
                callId = callId,
                callerAccount = caller,
                callerName = intent.getStringExtra(EXTRA_CALLER_NAME).orEmpty(),
                isVideo = intent.getBooleanExtra(EXTRA_VIDEO, false),
            )
        }
    }
}
