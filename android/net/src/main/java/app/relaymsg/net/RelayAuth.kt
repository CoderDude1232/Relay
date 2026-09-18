package app.relaymsg.net

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/** Device credentials for the relay: who we are, plus the legacy device password. */
data class RelayCredentials(
    val accountId: String,
    val deviceId: Int,
    /** Device password. Legacy HTTP Basic auth; see [RelayAuthenticator]. */
    val password: String,
)

/**
 * Signs the canonical string for `Relay-Sig` request authentication.
 *
 * Implemented over the device's P-256 auth key, whose private half never leaves
 * the Android Keystore. The same key signs nuke commands and device-list
 * mutations, matching the server's single `devices.auth_public_key`.
 */
interface RequestSigner {
    /**
     * Returns an **ECDSA-P256 ASN.1/DER** signature over SHA-256 of [message].
     * `Signature.getInstance("SHA256withECDSA")` produces exactly this form,
     * which is what the server's `ecdsa.VerifyASN1` expects.
     */
    fun sign(message: ByteArray): ByteArray

    /** The public key as an **uncompressed** P-256 point: `0x04 ‖ X ‖ Y`, 65 bytes. */
    fun publicKey(): ByteArray
}

/**
 * Builds the `Authorization` header for a request.
 *
 * Two schemes exist (PROTOCOL.md §2). Signature auth is preferred and is what
 * this client uses for everything; Basic exists solely to break the bootstrap
 * cycle described below.
 */
class RelayAuthenticator(
    private val credentials: RelayCredentials,
    private val signer: RequestSigner?,
) {
    companion object {
        const val SCHEME = "Relay-Sig"
        const val HEADER_TIMESTAMP = "X-Relay-Timestamp"
        const val HEADER_NONCE = "X-Relay-Nonce"

        /**
         * The exact string the server reconstructs and verifies.
         *
         * [path] is the URL path **without the query string** — the server signs
         * `r.URL.Path`, so `GET /v1/keys/{id}?device=3` signs `/v1/keys/{id}`.
         * Getting this wrong fails every request with a 401 and no other clue.
         */
        fun canonicalString(method: String, path: String, timestampMs: Long, nonce: String): String =
            "$method\n$path\n$timestampMs\n$nonce"
    }

    private val random = SecureRandom()

    /** Headers for one request. Empty when neither scheme is available. */
    fun headers(method: String, path: String): Map<String, String> {
        val signer = signer ?: return basicHeaders()
        val timestampMs = System.currentTimeMillis()
        val nonce = Base64.getEncoder()
            .encodeToString(ByteArray(16).also(random::nextBytes))
        val canonical = canonicalString(method, path, timestampMs, nonce)
        val signature = signer.sign(canonical.toByteArray())
        return mapOf(
            "Authorization" to
                "$SCHEME ${credentials.accountId}.${credentials.deviceId}:" +
                Base64.getEncoder().encodeToString(signature),
            HEADER_TIMESTAMP to timestampMs.toString(),
            HEADER_NONCE to nonce,
        )
    }

    /**
     * HTTP Basic, the legacy scheme.
     *
     * Kept for exactly one purpose: a brand-new device has no `auth_public_key`
     * on file, and the endpoint that uploads it is itself authenticated. So the
     * bootstrap is `POST /v1/accounts` (unauthenticated) → generate the Keystore
     * key → `PUT /v1/devices/auth-key` **with Basic** → signatures from then on
     * (PROTOCOL.md §2.3).
     */
    fun basicHeaders(): Map<String, String> {
        val raw = "${credentials.accountId}.${credentials.deviceId}:${credentials.password}"
        return mapOf(
            "Authorization" to "Basic " + Base64.getEncoder().encodeToString(raw.toByteArray()),
        )
    }
}

/**
 * Canonical payloads for the two other things the device auth key signs. Both
 * are plain strings joined by newlines, hashed with SHA-256 and signed
 * ECDSA-P256/ASN.1 — the same treatment as [RelayAuthenticator.canonicalString].
 */
object SignedPayloads {

    /** `POST /v1/accounts/me/nuke`, and re-verified on the received broadcast. */
    fun nuke(accountId: String, commandId: String, creationTimeMs: Long, initiatingDeviceId: Int): ByteArray =
        listOf("relay-nuke-v1", accountId, commandId, "$creationTimeMs", "$initiatingDeviceId")
            .joinToString("\n").toByteArray()

    /**
     * Device-list mutations. [action] is `add`, `link` or `remove`;
     * [targetDeviceId] is 0 for add/link. [password] is the new device's password
     * for **both** `add` and `link` (the server signs `req.Password` on each) and
     * empty for `remove`.
     */
    fun deviceMutation(
        accountId: String,
        expectedVersion: Long,
        action: String,
        targetDeviceId: Int,
        password: String,
    ): ByteArray =
        listOf("relay-device-list-v1", accountId, "$expectedVersion", action, "$targetDeviceId", password)
            .joinToString("\n").toByteArray()

    fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)
}
