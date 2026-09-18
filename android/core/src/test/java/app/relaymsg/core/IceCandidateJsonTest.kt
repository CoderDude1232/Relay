package app.relaymsg.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The ICE candidate wire encoding, which has to match iOS key for key. */
class IceCandidateJsonTest {

    private val candidate =
        "candidate:842163049 1 udp 1677729535 203.0.113.7 54321 typ srflx raddr 0.0.0.0 rport 0 " +
            "generation 0 ufrag Xk4t network-cost 999"

    @Test
    fun `uses the key names iOS parses`() {
        val json = JSONObject(IceCandidateJson.encode(candidate, "0", 0))

        // "candidate", not "sdp": iOS reads dict["candidate"] and drops anything
        // else, so a rename here silently kills every call.
        assertEquals(candidate, json.getString("candidate"))
        assertEquals("0", json.getString("sdpMid"))
        assertEquals(0, json.getInt("sdpMLineIndex"))
    }

    @Test
    fun `a null sdpMid is written as empty string, not omitted`() {
        // iOS requires all three keys; a missing sdpMid makes it drop the
        // candidate, which shows up as a call that rings and never connects.
        val json = JSONObject(IceCandidateJson.encode(candidate, null, 1))
        assertEquals("", json.getString("sdpMid"))
        assertEquals(1, json.getInt("sdpMLineIndex"))
    }

    @Test
    fun `round-trips`() {
        val decoded = IceCandidateJson.decode(IceCandidateJson.encode(candidate, "video", 1))

        assertEquals(candidate, decoded?.sdp)
        assertEquals("video", decoded?.sdpMid)
        assertEquals(1, decoded?.sdpMLineIndex)
    }

    @Test
    fun `decodes what iOS emits`() {
        val fromIos = """{"candidate":"$candidate","sdpMid":"0","sdpMLineIndex":0}"""
        assertEquals(candidate, IceCandidateJson.decode(fromIos)?.sdp)
    }

    @Test
    fun `unusable input decodes to null rather than a half candidate`() {
        assertNull(IceCandidateJson.decode(""))
        assertNull(IceCandidateJson.decode("not json"))
        assertNull(IceCandidateJson.decode("""{"sdpMid":"0","sdpMLineIndex":0}"""))
        assertNull(IceCandidateJson.decode("""{"candidate":""}"""))
    }
}
