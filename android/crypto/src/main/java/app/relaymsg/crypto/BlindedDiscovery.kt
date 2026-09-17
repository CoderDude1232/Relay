package app.relaymsg.crypto

import com.goterl.lazysodium.interfaces.Ristretto255
import java.security.MessageDigest
import java.util.Locale

/**
 * Client half of the ristretto255 2HashDH OPRF used for blinded contact
 * discovery (PROTOCOL.md §1.7).
 *
 * A plaintext username or email is never sent to the relay: the client blinds
 * H1(x) with a random scalar, the server evaluates it under its secret key, the
 * client unblinds and derives a lookup token.
 *
 * This MUST match `server/internal/oprf/oprf.go` byte-for-byte — same domain
 * tags, same normalization, same hashes, same ristretto encodings. The iOS
 * counterpart is `Relay/BlindedDiscovery.swift`.
 *
 * The ristretto primitives are injected as [Sodium] so the Android build can use
 * `LazySodiumAndroid` while JVM tests use `LazySodiumJava` — the interface is
 * identical, only the native loader differs.
 */
class BlindedDiscovery(private val sodium: Ristretto255.Native) {

    companion object {
        /** Domain-separation tags — identical to the Go server's. */
        private val HASH_TO_GROUP_DOMAIN = "Relay-OPRF-v1-h2g".toByteArray()
        private val TOKEN_DOMAIN = "Relay-OPRF-v1-token".toByteArray()

        private const val POINT_BYTES = 32
        private const val SCALAR_BYTES = 32
        private const val HASH_BYTES = 64

        /** Lowercase + trim, matching the server's `Normalize`. */
        fun normalize(identifier: String): ByteArray =
            identifier.trim().lowercase(Locale.ROOT).toByteArray()
    }

    /**
     * A blinded identifier ready for server evaluation, plus the private material
     * needed to unblind the result. Keep this until the server responds.
     */
    class Blinded internal constructor(
        /** B = r·H1(x) — the only thing that goes to the server. */
        val element: ByteArray,
        internal val blind: ByteArray,
        internal val normalized: ByteArray,
    )

    /** Thrown when libsodium rejects a degenerate scalar or point. */
    class OprfException(message: String) : Exception(message)

    /**
     * Blinds an identifier: picks a random scalar r and returns B = r·H1(x).
     */
    fun blind(identifier: String): Blinded {
        val x = normalize(identifier)
        val hx = hashToGroup(x)

        val r = ByteArray(SCALAR_BYTES)
        sodium.cryptoCoreRistretto255ScalarRandom(r)

        val b = ByteArray(POINT_BYTES)
        if (!sodium.cryptoScalarmultRistretto255(b, r, hx)) {
            throw OprfException("blinding produced a degenerate point")
        }
        return Blinded(element = b, blind = r, normalized = x)
    }

    /**
     * Unblinds the server's evaluation E = k·B into N = k·H1(x) and derives the
     * directory token H2(x, N) — the value sent to `POST /v1/directory/resolve`.
     */
    fun token(blinded: Blinded, evaluated: ByteArray): ByteArray {
        if (evaluated.size != POINT_BYTES) {
            throw OprfException("server evaluation must be $POINT_BYTES bytes")
        }
        val rInv = ByteArray(SCALAR_BYTES)
        if (!sodium.cryptoCoreRistretto255ScalarInvert(rInv, blinded.blind)) {
            throw OprfException("could not invert the blinding scalar")
        }
        val n = ByteArray(POINT_BYTES)
        if (!sodium.cryptoScalarmultRistretto255(n, rInv, evaluated)) {
            throw OprfException("unblinding produced a degenerate point")
        }
        return MessageDigest.getInstance("SHA-256").run {
            update(TOKEN_DOMAIN)
            update(blinded.normalized)
            update(n)
            digest()
        }
    }

    /** H1(x): domain-separated SHA-512 mapped onto the ristretto255 group. */
    private fun hashToGroup(x: ByteArray): ByteArray {
        val digest = MessageDigest.getInstance("SHA-512").run {
            update(HASH_TO_GROUP_DOMAIN)
            update(x)
            digest()
        }
        check(digest.size == HASH_BYTES) { "SHA-512 digest must be $HASH_BYTES bytes" }

        val point = ByteArray(POINT_BYTES)
        if (!sodium.cryptoCoreRistretto255FromHash(point, digest)) {
            throw OprfException("hash-to-group failed")
        }
        return point
    }
}
