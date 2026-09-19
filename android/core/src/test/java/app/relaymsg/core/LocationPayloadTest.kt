package app.relaymsg.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The location body format, which iOS reads directly. */
class LocationPayloadTest {

    private val future = System.currentTimeMillis() + 60_000

    @Test
    fun `the body carries iOS's marker and field names`() {
        val body = LocationPayload(51.5, -0.12, future, stop = false).encodeBody()
        assertTrue(body.startsWith("__relay_loc__"))

        val json = JSONObject(body.removePrefix("__relay_loc__"))
        assertEquals(51.5, json.getDouble("lat"), 0.0001)
        // "lng", not "lon" or "long" -- iOS spells it this way.
        assertEquals(-0.12, json.getDouble("lng"), 0.0001)
        assertFalse(json.getBoolean("stop"))
    }

    @Test
    fun `round-trips`() {
        val payload = LocationPayload(-33.86, 151.2, future, stop = false)
        assertEquals(payload, LocationPayload.fromBody(payload.encodeBody()))
    }

    @Test
    fun `an expired share is no longer live`() {
        val stale = LocationPayload(0.0, 0.0, System.currentTimeMillis() - 1, stop = false)
        assertTrue(stale.isExpired())
        assertFalse(stale.isLive())
    }

    @Test
    fun `an explicit stop ends it even before expiry`() {
        // Ending early has to win over the timer, or "stop sharing" would not
        // actually stop anything until the clock ran out.
        val stopped = LocationPayload(0.0, 0.0, future, stop = true)
        assertFalse(stopped.isExpired())
        assertFalse(stopped.isLive())
    }

    @Test
    fun `an ordinary message is not a location`() {
        assertNull(LocationPayload.fromBody("meet me at the pub"))
        assertNull(LocationPayload.fromBody("__relay_loc__not json"))
        assertNull(LocationPayload.fromBody(""))
    }
}
