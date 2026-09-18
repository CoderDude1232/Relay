package app.relaymsg.core

import java.util.Base64
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The linking payloads, which iOS encodes with `Codable`.
 *
 * Two Swift conventions have to hold or linking fails in ways that look like a
 * crypto problem: `Data` is base64, and nil optionals are **omitted** rather
 * than written as null.
 */
class DeviceLinkingTest {

    private val key = ByteArray(32) { it.toByte() }

    @Test
    fun `the QR payload has the field names iOS decodes`() {
        val json = JSONObject(
            DeviceLinking.LinkQrPayload("sess-1", key, "https://api.relaymsg.app").encode(),
        )

        assertEquals(1, json.getInt("version"))
        assertEquals("sess-1", json.getString("sessionId"))
        // "serverURL", not "serverUrl" -- Swift's property name is serverURL.
        assertEquals("https://api.relaymsg.app", json.getString("serverURL"))
        assertArrayEquals(key, Base64.getDecoder().decode(json.getString("ephemeralPublicKey")))
    }

    @Test
    fun `a QR payload round-trips`() {
        val payload = DeviceLinking.LinkQrPayload("sess-1", key, "https://api.relaymsg.app")
        assertEquals(payload, DeviceLinking.LinkQrPayload.decode(payload.encode()))
    }

    @Test
    fun `anything that is not one of our QR codes decodes to null`() {
        assertNull(DeviceLinking.LinkQrPayload.decode("https://example.com"))
        assertNull(DeviceLinking.LinkQrPayload.decode(""))
        // A key of the wrong length would fail later, inside the cipher, where
        // the error would be far less obvious.
        assertNull(
            DeviceLinking.LinkQrPayload.decode(
                JSONObject()
                    .put("version", 1)
                    .put("sessionId", "s")
                    .put("ephemeralPublicKey", Base64.getEncoder().encodeToString(ByteArray(31)))
                    .put("serverURL", "https://api.relaymsg.app")
                    .toString(),
            ),
        )
        // A future version is refused rather than misread.
        assertNull(
            DeviceLinking.LinkQrPayload.decode(
                JSONObject(DeviceLinking.LinkQrPayload("s", key, "u").encode())
                    .put("version", 99).toString(),
            ),
        )
    }

    @Test
    fun `the provisioning payload round-trips with everything present`() {
        val payload = DeviceLinking.LinkProvisioningPayload(
            identityKeyPair = ByteArray(64) { (it * 3).toByte() },
            accountId = "acct-1",
            username = "eth",
            deviceId = 4,
            password = "hunter2",
            serverUrl = "https://api.relaymsg.app",
            peers = listOf(
                DeviceLinking.PeerStub("peer-1", "alice"),
                DeviceLinking.PeerStub("peer-2", null),
            ),
            historyId = "hist-1",
            historyKey = ByteArray(32) { 7 },
            historyDigest = ByteArray(32) { 9 },
        )

        val decoded = DeviceLinking.LinkProvisioningPayload
            .decode(payload.encode().toByteArray())!!

        assertEquals(payload, decoded)
        assertEquals("eth", decoded.username)
        assertEquals(2, decoded.peers.size)
        assertNull("a peer with no username must stay null", decoded.peers[1].username)
        assertArrayEquals(ByteArray(32) { 7 }, decoded.historyKey)
    }

    @Test
    fun `absent optionals decode as null, the way Swift omits them`() {
        // Swift's synthesized encoder uses encodeIfPresent, so nil fields are
        // missing keys rather than nulls. Reading them as "" would give a device
        // a blank username and a history id that does not exist.
        val minimal = JSONObject()
            .put("version", 1)
            .put("identityKeyPair", Base64.getEncoder().encodeToString(ByteArray(64)))
            .put("accountId", "acct-1")
            .put("deviceId", 2)
            .put("password", "pw")
            .put("serverURL", "https://api.relaymsg.app")
            .toString()

        val decoded = DeviceLinking.LinkProvisioningPayload.decode(minimal.toByteArray())!!

        assertNull(decoded.username)
        assertNull(decoded.historyId)
        assertNull(decoded.historyKey)
        assertNull(decoded.historyDigest)
        assertTrue(decoded.peers.isEmpty())
        assertEquals(2, decoded.deviceId)
    }

    @Test
    fun `an explicit JSON null is treated as absent`() {
        val withNulls = JSONObject()
            .put("version", 1)
            .put("identityKeyPair", Base64.getEncoder().encodeToString(ByteArray(64)))
            .put("accountId", "acct-1")
            .put("deviceId", 2)
            .put("password", "pw")
            .put("serverURL", "u")
            .put("username", JSONObject.NULL)
            .put("historyKey", JSONObject.NULL)
            .toString()

        val decoded = DeviceLinking.LinkProvisioningPayload.decode(withNulls.toByteArray())!!
        assertNull(decoded.username)
        assertNull(decoded.historyKey)
    }

    @Test
    fun `a payload missing something required decodes to null, not a half device`() {
        // Half-installing a linked device would leave it with an identity it
        // cannot authenticate, which is worse than refusing outright.
        val noPassword = JSONObject()
            .put("version", 1)
            .put("identityKeyPair", Base64.getEncoder().encodeToString(ByteArray(64)))
            .put("accountId", "acct-1")
            .put("deviceId", 2)
            .put("serverURL", "u")
            .toString()

        assertNull(DeviceLinking.LinkProvisioningPayload.decode(noPassword.toByteArray()))
    }
}
