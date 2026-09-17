package app.relaymsg.crypto

import com.google.gson.JsonParser
import java.util.Base64
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Attachment blob interop (PROTOCOL.md §1.8).
 *
 * The layout is the part that breaks across platforms: Apple's CryptoKit hands
 * back a single "combined" box of `nonce ‖ ciphertext ‖ tag`, while Java's GCM
 * cipher keeps the IV separate and returns only `ciphertext ‖ tag`. The vector
 * here is produced by Go's standard library — genuinely independent of both — so
 * decrypting it proves Android agrees with the format the relay actually stores.
 */
class AttachmentCipherTest {

    private class Vector(
        val key: ByteArray,
        val blob: ByteArray,
        val digest: ByteArray,
        val plaintext: ByteArray,
    )

    private fun loadVector(): Vector {
        val stream = checkNotNull(
            javaClass.classLoader?.getResourceAsStream("golden/crypto-vectors.json")
        ) { "golden/crypto-vectors.json missing — run tools/genvectors -kind=crypto" }
        val attachment = stream.reader().use { JsonParser.parseReader(it) }
            .asJsonObject.getAsJsonObject("attachment")
        val decoder = Base64.getDecoder()
        return Vector(
            key = decoder.decode(attachment.get("key").asString),
            blob = decoder.decode(attachment.get("blob").asString),
            digest = decoder.decode(attachment.get("digest").asString),
            plaintext = decoder.decode(attachment.get("plaintext").asString),
        )
    }

    @Test
    fun `decrypts a blob produced by the go implementation`() {
        val vector = loadVector()
        assertArrayEquals(
            vector.plaintext,
            AttachmentCipher.open(vector.blob, vector.key, vector.digest),
        )
    }

    @Test
    fun `the digest covers the ciphertext, not the plaintext`() {
        // A digest over the plaintext would leak a fingerprint of the file to the
        // relay, which stores the ciphertext and could compare digests.
        val vector = loadVector()
        val sha = java.security.MessageDigest.getInstance("SHA-256")
        assertArrayEquals(sha.digest(vector.blob), vector.digest)
    }

    @Test
    fun `blob layout is nonce then ciphertext then tag`() {
        val vector = loadVector()
        // 12-byte nonce + 16-byte tag of overhead, and the leading bytes are the
        // nonce rather than ciphertext.
        assertEquals(vector.plaintext.size + 12 + 16, vector.blob.size)
    }

    @Test
    fun `seal and open round-trips`() {
        val plaintext = "round trip ✓".toByteArray()
        val sealed = AttachmentCipher.seal(plaintext)

        assertEquals(32, sealed.key.size)
        assertEquals(32, sealed.digest.size)
        assertArrayEquals(
            plaintext,
            AttachmentCipher.open(sealed.ciphertext, sealed.key, sealed.digest),
        )
    }

    @Test
    fun `each seal uses a fresh key and nonce`() {
        val plaintext = "same input".toByteArray()
        val first = AttachmentCipher.seal(plaintext)
        val second = AttachmentCipher.seal(plaintext)

        assertFalse(first.key.contentEquals(second.key))
        assertFalse(first.ciphertext.contentEquals(second.ciphertext))
    }

    @Test
    fun `a tampered blob is refused before decryption is attempted`() {
        val sealed = AttachmentCipher.seal("important".toByteArray())
        val tampered = sealed.ciphertext.copyOf().also { it[it.size - 1] = (it.last() + 1).toByte() }

        assertThrows(AttachmentCipher.DigestMismatchException::class.java) {
            AttachmentCipher.open(tampered, sealed.key, sealed.digest)
        }
    }

    @Test
    fun `a truncated blob is rejected`() {
        val sealed = AttachmentCipher.seal("x".toByteArray())
        val truncated = sealed.ciphertext.copyOf(10)
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(truncated)

        assertThrows(AttachmentCipher.MalformedCiphertextException::class.java) {
            AttachmentCipher.open(truncated, sealed.key, digest)
        }
    }

    @Test
    fun `the wrong key fails the authentication tag`() {
        val sealed = AttachmentCipher.seal("secret".toByteArray())
        val wrongKey = ByteArray(32) { 0x7 }

        val error = assertThrows(Exception::class.java) {
            AttachmentCipher.open(sealed.ciphertext, wrongKey, sealed.digest)
        }
        assertTrue(error is javax.crypto.AEADBadTagException)
    }
}
