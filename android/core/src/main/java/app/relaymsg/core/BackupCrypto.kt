package app.relaymsg.core

import app.relaymsg.crypto.Hkdf
import java.security.SecureRandom
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Backup encryption, in the two formats iOS writes.
 *
 * **Recovery-key format** (`CloudBackupManager`): a 32-byte Recovery Key the
 * user holds, stretched with HKDF-SHA256 (salt `relay-icloud-backup`, info
 * `v1`) into an AES-256-GCM key. The blob is CryptoKit's `combined`
 * representation — `nonce(12) ‖ ciphertext ‖ tag(16)`.
 *
 * **Password format** (`BackupView`'s manual export): a random 32-byte salt is
 * written in front, the password is stretched with HKDF-SHA256 (that salt, no
 * info), and the layout is `salt(32) ‖ nonce(12) ‖ ciphertext ‖ tag(16)`.
 *
 * Both are byte-compatible with iOS in both directions. Note the password form
 * stretches with a single HKDF pass, not a password hash — it inherits iOS's
 * choice because the files have to interchange, and the UI says so by demanding
 * a long password.
 */
object BackupCrypto {

    private const val KEY_BYTES = 32
    private const val NONCE_BYTES = 12
    private const val TAG_BITS = 128
    private const val SALT_BYTES = 32

    private val RECOVERY_SALT = "relay-icloud-backup".toByteArray()
    private val RECOVERY_INFO = "v1".toByteArray()

    class WrongKeyException : Exception("That key didn't match the backup.")
    class MalformedBackupException : Exception("That file isn't a Relay backup.")

    fun randomRecoveryKey(): ByteArray = ByteArray(KEY_BYTES).also { SecureRandom().nextBytes(it) }

    // ------------------------------------------------------- recovery key form

    fun seal(plaintext: ByteArray, recoveryKey: ByteArray): ByteArray =
        gcmSeal(plaintext, Hkdf.derive(recoveryKey, RECOVERY_SALT, RECOVERY_INFO, KEY_BYTES))

    fun open(blob: ByteArray, recoveryKey: ByteArray): ByteArray =
        gcmOpen(blob, Hkdf.derive(recoveryKey, RECOVERY_SALT, RECOVERY_INFO, KEY_BYTES))

    // ---------------------------------------------------------- password form

    fun sealWithPassword(plaintext: ByteArray, password: String): ByteArray {
        val salt = ByteArray(SALT_BYTES).also { SecureRandom().nextBytes(it) }
        val key = Hkdf.derive(password.toByteArray(), salt, ByteArray(0), KEY_BYTES)
        return salt + gcmSeal(plaintext, key)
    }

    fun openWithPassword(blob: ByteArray, password: String): ByteArray {
        if (blob.size <= SALT_BYTES + NONCE_BYTES) throw MalformedBackupException()
        val salt = blob.copyOfRange(0, SALT_BYTES)
        val key = Hkdf.derive(password.toByteArray(), salt, ByteArray(0), KEY_BYTES)
        return gcmOpen(blob.copyOfRange(SALT_BYTES, blob.size), key)
    }

    // ------------------------------------------------------- recovery key text

    /** The grouped hex iOS shows and accepts: 16 blocks of four, space separated. */
    fun format(key: ByteArray): String =
        key.joinToString("") { "%02X".format(it) }.chunked(4).joinToString(" ")

    /** Parses a displayed key back to bytes, ignoring whatever spacing was typed. */
    fun parse(display: String): ByteArray {
        val hex = display.filter { it.isDigit() || it.lowercaseChar() in 'a'..'f' }
        if (hex.length != KEY_BYTES * 2) throw MalformedBackupException()
        return ByteArray(KEY_BYTES) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }

    // ------------------------------------------------------------------ AES-GCM

    private fun gcmSeal(plaintext: ByteArray, key: ByteArray): ByteArray {
        val nonce = ByteArray(NONCE_BYTES).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        return nonce + cipher.doFinal(plaintext)
    }

    private fun gcmOpen(blob: ByteArray, key: ByteArray): ByteArray {
        if (blob.size <= NONCE_BYTES + TAG_BITS / 8) throw MalformedBackupException()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(TAG_BITS, blob, 0, NONCE_BYTES),
        )
        return try {
            cipher.doFinal(blob, NONCE_BYTES, blob.size - NONCE_BYTES)
        } catch (e: AEADBadTagException) {
            // A bad tag is indistinguishable from a wrong key, and a wrong key
            // is the reason it happens in practice.
            throw WrongKeyException()
        }
    }
}
