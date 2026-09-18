package app.relaymsg.core

import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/**
 * Wire shapes for device linking (PROTOCOL.md §7.9).
 *
 * The **new** device shows [LinkQrPayload] in a QR code; the primary scans it,
 * seals a [LinkProvisioningPayload] to the ephemeral key inside, and leaves the
 * ciphertext on the relay. Only the QR and the sealed blob ever travel — the
 * account's identity private key is encrypted end to end.
 *
 * These are iOS's `Codable` structs, so two of its conventions have to be
 * matched: `Data` fields encode as **standard base64** (padded, unwrapped), and
 * `nil` optionals are **omitted** rather than written as null — hence the
 * absent-vs-empty care on the way in.
 *
 * `java.util.Base64` rather than `android.util.Base64`: it needs API 26, which
 * is this app's minimum anyway, and it keeps these codecs testable on the JVM.
 */
object DeviceLinking {

    const val VERSION = 1

    /** Shown by the device being linked. Deliberately tiny. */
    data class LinkQrPayload(
        val sessionId: String,
        /** Raw 32-byte X25519 public key the primary seals to. */
        val ephemeralPublicKey: ByteArray,
        val serverUrl: String,
    ) {
        fun encode(): String = JSONObject()
            .put("version", VERSION)
            .put("sessionId", sessionId)
            .put("ephemeralPublicKey", Base64.getEncoder().encodeToString(ephemeralPublicKey))
            .put("serverURL", serverUrl)
            .toString()

        // A ByteArray field means the generated equals/hashCode would compare by
        // identity, which is never what a caller wants.
        override fun equals(other: Any?): Boolean = this === other || (
            other is LinkQrPayload && sessionId == other.sessionId &&
                ephemeralPublicKey.contentEquals(other.ephemeralPublicKey) &&
                serverUrl == other.serverUrl
            )

        override fun hashCode(): Int =
            (sessionId.hashCode() * 31 + ephemeralPublicKey.contentHashCode()) * 31 +
                serverUrl.hashCode()

        companion object {
            /** Parses a scanned QR. Null for anything that is not one of ours. */
            fun decode(text: String): LinkQrPayload? = runCatching {
                val json = JSONObject(text)
                if (json.optInt("version", VERSION) != VERSION) return null
                val key = Base64.getDecoder().decode(json.getString("ephemeralPublicKey"))
                if (key.size != 32) return null
                LinkQrPayload(
                    sessionId = json.getString("sessionId"),
                    ephemeralPublicKey = key,
                    serverUrl = json.getString("serverURL"),
                )
            }.getOrNull()
        }
    }

    /** One contact the primary passes along, so a linked device is not blank. */
    data class PeerStub(val account: String, val username: String?)

    /**
     * Sealed by the primary, opened by the new device.
     *
     * [identityKeyPair] is the **account's shared identity** — the whole point of
     * linking rather than registering. Everything else is this new device's own.
     */
    data class LinkProvisioningPayload(
        val identityKeyPair: ByteArray,
        val accountId: String,
        val username: String?,
        val deviceId: Int,
        val password: String,
        val serverUrl: String,
        val peers: List<PeerStub>,
        val historyId: String?,
        val historyKey: ByteArray?,
        val historyDigest: ByteArray?,
    ) {
        override fun equals(other: Any?): Boolean = this === other || (
            other is LinkProvisioningPayload && accountId == other.accountId &&
                deviceId == other.deviceId && password == other.password &&
                identityKeyPair.contentEquals(other.identityKeyPair)
            )

        override fun hashCode(): Int =
            (accountId.hashCode() * 31 + deviceId) * 31 + identityKeyPair.contentHashCode()

        fun encode(): String {
            val json = JSONObject()
                .put("version", VERSION)
                .put("identityKeyPair", Base64.getEncoder().encodeToString(identityKeyPair))
                .put("accountId", accountId)
                .put("deviceId", deviceId)
                .put("password", password)
                .put("serverURL", serverUrl)
                .put(
                    "peers",
                    JSONArray().apply {
                        peers.forEach { peer ->
                            put(
                                JSONObject().put("account", peer.account)
                                    .apply { peer.username?.let { put("username", it) } },
                            )
                        }
                    },
                )
            // Omitted rather than null, matching Swift's encodeIfPresent.
            username?.let { json.put("username", it) }
            historyId?.let { json.put("historyId", it) }
            historyKey?.let { json.put("historyKey", Base64.getEncoder().encodeToString(it)) }
            historyDigest?.let {
                json.put("historyDigest", Base64.getEncoder().encodeToString(it))
            }
            return json.toString()
        }

        companion object {
            fun decode(plaintext: ByteArray): LinkProvisioningPayload? = runCatching {
                val json = JSONObject(plaintext.decodeToString())
                if (json.optInt("version", VERSION) != VERSION) return null
                LinkProvisioningPayload(
                    identityKeyPair = json.bytes("identityKeyPair")!!,
                    accountId = json.getString("accountId"),
                    username = json.optStringOrNull("username"),
                    deviceId = json.getInt("deviceId"),
                    password = json.getString("password"),
                    serverUrl = json.getString("serverURL"),
                    peers = json.optJSONArray("peers").stubs(),
                    historyId = json.optStringOrNull("historyId"),
                    historyKey = json.bytes("historyKey"),
                    historyDigest = json.bytes("historyDigest"),
                )
            }.getOrNull()
        }
    }

    private fun JSONObject.bytes(key: String): ByteArray? =
        optStringOrNull(key)?.let { Base64.getDecoder().decode(it) }

    /** `optString` returns `""` for a missing key, which is not the same as absent. */
    private fun JSONObject.optStringOrNull(key: String): String? =
        if (isNull(key)) null else optString(key).takeIf { it.isNotEmpty() }

    private fun JSONArray?.stubs(): List<PeerStub> {
        if (this == null) return emptyList()
        return (0 until length()).mapNotNull { index ->
            optJSONObject(index)?.let { peer ->
                PeerStub(
                    account = peer.optString("account"),
                    username = if (peer.isNull("username")) null else peer.optString("username"),
                )
            }
        }.filter { it.account.isNotEmpty() }
    }
}
