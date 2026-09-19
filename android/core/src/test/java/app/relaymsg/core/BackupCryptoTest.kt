package app.relaymsg.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BackupCryptoTest {

    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    @Test
    fun `opens a blob built with iOS's parameters`() {
        // Key material derived independently (HKDF-SHA256, salt
        // "relay-icloud-backup", info "v1") from a recovery key of 0x00..0x1F,
        // then sealed with a fixed nonce. If the salt, the info, the nonce-first
        // layout or the 128-bit tag ever drift from CloudBackupManager's, this
        // stops decrypting.
        val recoveryKey = ByteArray(32) { it.toByte() }
        val blob = hex("000102030405060708090A0BE59F109BE17021DD3ED869C1909D5BA1C3BC7B9258B8602C1F4FD85BC0")
        assertEquals("""{"version":1}""", String(BackupCrypto.open(blob, recoveryKey)))
    }

    @Test
    fun `recovery key round-trips through the blob`() {
        val key = BackupCrypto.randomRecoveryKey()
        val plaintext = "the quick brown fox".toByteArray()
        assertArrayEquals(plaintext, BackupCrypto.open(BackupCrypto.seal(plaintext, key), key))
    }

    @Test(expected = BackupCrypto.WrongKeyException::class)
    fun `a wrong recovery key is rejected`() {
        val blob = BackupCrypto.seal("secret".toByteArray(), BackupCrypto.randomRecoveryKey())
        BackupCrypto.open(blob, BackupCrypto.randomRecoveryKey())
    }

    @Test(expected = BackupCrypto.MalformedBackupException::class)
    fun `a truncated blob is not mistaken for a wrong key`() {
        BackupCrypto.open(ByteArray(8), BackupCrypto.randomRecoveryKey())
    }

    @Test
    fun `password export puts the salt in front`() {
        val blob = BackupCrypto.sealWithPassword("hello".toByteArray(), "correct horse battery")
        // salt(32) + nonce(12) + ciphertext(5) + tag(16)
        assertEquals(65, blob.size)
        assertArrayEquals(
            "hello".toByteArray(),
            BackupCrypto.openWithPassword(blob, "correct horse battery"),
        )
    }

    @Test(expected = BackupCrypto.WrongKeyException::class)
    fun `a wrong password is rejected`() {
        val blob = BackupCrypto.sealWithPassword("hello".toByteArray(), "one")
        BackupCrypto.openWithPassword(blob, "two")
    }

    @Test
    fun `the displayed key is iOS's grouped hex`() {
        val key = ByteArray(32) { it.toByte() }
        val display = BackupCrypto.format(key)
        assertEquals("0001 0203 0405 0607 0809 0A0B 0C0D 0E0F 1011 1213 1415 1617 1819 1A1B 1C1D 1E1F", display)
        assertArrayEquals(key, BackupCrypto.parse(display))
        // Whatever spacing the user types back is ignored.
        assertArrayEquals(key, BackupCrypto.parse(display.replace(" ", "")))
        assertArrayEquals(key, BackupCrypto.parse(display.lowercase()))
    }

    @Test(expected = BackupCrypto.MalformedBackupException::class)
    fun `a short key is rejected before it can fail as a bad tag`() {
        BackupCrypto.parse("0001 0203")
    }

    @Test
    fun `every generated key is distinct`() {
        val keys = (1..16).map { BackupCrypto.format(BackupCrypto.randomRecoveryKey()) }
        assertTrue(keys.toSet().size == keys.size)
    }
}
