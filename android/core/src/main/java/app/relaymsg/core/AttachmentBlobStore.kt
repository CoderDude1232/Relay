package app.relaymsg.core

import android.content.Context
import java.io.File

/**
 * On-disk cache of attachment **ciphertext**.
 *
 * Only the encrypted blob is cached, exactly as downloaded. Decryption happens
 * on demand and the plaintext is never written to disk — so an attacker with the
 * files but not the database (where the per-attachment key lives, encrypted
 * under SQLCipher) gets nothing. iOS keeps the same split.
 */
class AttachmentBlobStore(context: Context) {

    private val directory: File =
        File(context.filesDir, "attachments").apply { mkdirs() }

    fun write(id: String, ciphertext: ByteArray) {
        file(id).writeBytes(ciphertext)
    }

    fun read(id: String): ByteArray? = file(id).takeIf { it.exists() }?.readBytes()

    fun contains(id: String): Boolean = file(id).exists()

    fun delete(id: String) {
        file(id).delete()
    }

    /** Removes every cached blob. Part of a local wipe. */
    fun clear() {
        directory.listFiles()?.forEach { it.delete() }
    }

    /**
     * Blob ids come from the relay, so they are never interpolated into a path
     * without sanitising: a crafted id containing path separators would
     * otherwise let a peer write outside this directory.
     */
    private fun file(id: String): File = File(directory, id.replace(Regex("[^A-Za-z0-9._-]"), "_"))
}
