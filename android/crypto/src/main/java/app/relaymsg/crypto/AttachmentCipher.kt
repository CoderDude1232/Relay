package app.relaymsg.crypto

import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Symmetric encryption for attachment blobs (PROTOCOL.md §1.8).
 *
 * Each attachment uses a fresh random AES-256-GCM key; the sealed box
 * `nonce ‖ ciphertext ‖ tag` is what gets uploaded to the relay. The key and a
 * SHA-256 digest **of the ciphertext** travel end-to-end inside the encrypted
 * `Content`, so the relay only ever stores opaque, undecryptable bytes.
 *
 * The byte layout is the one Apple's CryptoKit calls a "combined" box, because
 * that is what the iOS client uploads. Java's GCM cipher emits `ciphertext ‖ tag`
 * and keeps the IV separate, so the nonce is prepended and stripped by hand here
 * — get this wrong and blobs are unreadable cross-platform.
 */
object AttachmentCipher {

    private const val KEY_BYTES = 32
    private const val NONCE_BYTES = 12
    private const val TAG_BITS = 128
    private const val TAG_BYTES = TAG_BITS / 8

    private val random = SecureRandom()

    /** The encrypted form of an attachment, ready to upload. */
    class Sealed(
        /** Upload this to the relay: `nonce ‖ ciphertext ‖ tag`. */
        val ciphertext: ByteArray,
        /** 32-byte AES-256-GCM key — goes in the `AttachmentPointer`. */
        val key: ByteArray,
        /** SHA-256 of [ciphertext] — goes in the `AttachmentPointer`. */
        val digest: ByteArray,
    )

    /** The downloaded blob's digest didn't match the pointer — tampering or corruption. */
    class DigestMismatchException : Exception("attachment digest did not match the pointer")

    /** The blob is too short to contain a nonce and a tag. */
    class MalformedCiphertextException : Exception("attachment ciphertext is malformed")

    /** Encrypts [plaintext] under a fresh random key. */
    fun seal(plaintext: ByteArray): Sealed {
        val key = ByteArray(KEY_BYTES).also(random::nextBytes)
        val nonce = ByteArray(NONCE_BYTES).also(random::nextBytes)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(TAG_BITS, nonce),
        )
        val body = cipher.doFinal(plaintext) // ciphertext ‖ tag
        val combined = nonce + body

        return Sealed(ciphertext = combined, key = key, digest = sha256(combined))
    }

    /** Verifies the digest, then decrypts a downloaded blob. Fails closed. */
    fun open(ciphertext: ByteArray, key: ByteArray, digest: ByteArray): ByteArray {
        // Constant-time: a digest check is not a secret comparison, but there is no
        // reason to leak position, and the cost is nil.
        if (!MessageDigest.isEqual(sha256(ciphertext), digest)) {
            throw DigestMismatchException()
        }
        if (ciphertext.size < NONCE_BYTES + TAG_BYTES) {
            throw MalformedCiphertextException()
        }
        val nonce = ciphertext.copyOfRange(0, NONCE_BYTES)
        val body = ciphertext.copyOfRange(NONCE_BYTES, ciphertext.size)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(TAG_BITS, nonce),
        )
        return cipher.doFinal(body)
    }

    private fun sha256(data: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(data)
}
