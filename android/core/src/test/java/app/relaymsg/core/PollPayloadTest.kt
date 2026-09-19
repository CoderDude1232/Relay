package app.relaymsg.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The poll body format.
 *
 * Pinned because a poll has no table of its own: it is a message row whose body
 * is a marker plus JSON, and a linked iOS device reads those rows directly.
 */
class PollPayloadTest {

    private val poll = PollPayload("Lunch?", listOf("Pizza", "Noodles", "Neither"), multiSelect = true)

    @Test
    fun `the body carries iOS's marker and key names`() {
        val body = poll.encodeBody()
        assertTrue(body.startsWith("__poll__:"))

        val json = JSONObject(body.removePrefix("__poll__:"))
        assertEquals("Lunch?", json.getString("question"))
        // "multiSelect", not "multi_select" -- it is Swift Codable's own spelling.
        assertTrue(json.getBoolean("multiSelect"))
        assertEquals(3, json.getJSONArray("options").length())
    }

    @Test
    fun `round-trips`() {
        assertEquals(poll, PollPayload.fromBody(poll.encodeBody()))
    }

    @Test
    fun `an ordinary message is not a poll`() {
        // The marker is the only thing that makes a row a poll, so anything
        // without it has to come back null rather than an empty poll.
        assertNull(PollPayload.fromBody("Lunch?"))
        assertNull(PollPayload.fromBody(""))
        assertNull(PollPayload.fromBody("__poll__:not json"))
    }

    @Test
    fun `a single-answer poll decodes as one`() {
        val single = PollPayload("Tea?", listOf("Yes", "No"), multiSelect = false)
        assertEquals(false, PollPayload.fromBody(single.encodeBody())?.multiSelect)
    }
}
