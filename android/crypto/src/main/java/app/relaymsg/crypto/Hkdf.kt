package app.relaymsg.crypto

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * HKDF-SHA256 (RFC 5869).
 *
 * Written out rather than taken from libsignal because it has to line up with
 * CryptoKit's `hkdfDerivedSymmetricKey` on the iOS side, and the one thing that
 * differs between implementations is what an **empty salt** means: RFC 5869 says
 * substitute HashLen zero bytes, and that is what CryptoKit does.
 */
object Hkdf {

    private const val ALGORITHM = "HmacSHA256"
    private const val HASH_LENGTH = 32

    fun derive(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length > 0 && length <= 255 * HASH_LENGTH) { "invalid HKDF output length" }
        val prk = hmac(if (salt.isEmpty()) ByteArray(HASH_LENGTH) else salt, ikm)

        val output = ByteArray(length)
        var previous = ByteArray(0)
        var filled = 0
        var counter = 1
        while (filled < length) {
            val block = hmac(prk, previous + info + byteArrayOf(counter.toByte()))
            val take = minOf(block.size, length - filled)
            block.copyInto(output, filled, 0, take)
            filled += take
            previous = block
            counter++
        }
        return output
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray =
        Mac.getInstance(ALGORITHM).run {
            init(SecretKeySpec(key, ALGORITHM))
            doFinal(data)
        }
}
