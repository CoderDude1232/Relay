package app.relaymsg.call

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Parsing of the relay's call-push data block (PROTOCOL.md §7.5.1).
 *
 * Worth testing on its own because this is the one part of the call-wake path
 * that has to agree exactly with `server/internal/fcm/fcm.go`, and the only part
 * that can be checked without a device.
 */
class CallWakeTest {

    private val callId = "3b7d4e9a-6c21-4a5f-9b0e-1122334455ff"
    private val caller = "11112222-3333-4444-5555-666677778888"

    @Test
    fun `parses the payload the relay sends`() {
        val wake = CallWake.from(
            mapOf(
                "type" to "call",
                "call_id" to callId,
                "caller_account" to caller,
                "caller_name" to "eth",
                "kind" to "audio",
            ),
        )

        assertEquals(callId, wake?.callId)
        assertEquals(caller, wake?.callerAccount)
        assertEquals("eth", wake?.displayName)
        assertFalse(wake!!.isVideo)
    }

    @Test
    fun `caller_name is optional because the relay omits it when empty`() {
        val wake = CallWake.from(mapOf("call_id" to callId, "caller_account" to caller))

        assertEquals("", wake?.callerName)
        // Still ringable: fall back to a short id rather than showing nothing.
        assertEquals(caller.take(8), wake?.displayName)
    }

    @Test
    fun `kind video is the only thing that means video`() {
        fun kind(value: String?) = CallWake.from(
            buildMap {
                put("call_id", callId)
                put("caller_account", caller)
                value?.let { put("kind", it) }
            },
        )?.isVideo

        assertTrue(kind("video") == true)
        assertFalse(kind("audio") == true)
        assertFalse(kind(null) == true)
    }

    @Test
    fun `an unusable payload parses to null rather than a half-built call`() {
        assertNull(CallWake.from(emptyMap()))
        assertNull(CallWake.from(mapOf("call_id" to callId)))
        assertNull(CallWake.from(mapOf("caller_account" to caller)))
        assertNull(CallWake.from(mapOf("call_id" to "", "caller_account" to caller)))
    }
}
