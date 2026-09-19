package app.relaymsg.core

/**
 * Backup settings and the Recovery Key.
 *
 * iOS keeps the Recovery Key in the Keychain and the flags in UserDefaults;
 * here both live in the SQLCipher-encrypted kv table, which is the Keystore-
 * wrapped equivalent. Either way the local copy is a convenience for repeat
 * backups — the copy that matters is the one the user wrote down, because a
 * device that loses its storage loses this one too. That is the whole point:
 * nobody but the user can decrypt the blob, Relay included.
 */
class BackupManager(private val kv: KeyValueStore) {

    var isEnabled: Boolean
        get() = kv.get(KV_ENABLED)?.decodeToString() == "1"
        set(value) = kv.put(KV_ENABLED, (if (value) "1" else "0").toByteArray())

    var lastBackupAt: Long?
        get() = kv.get(KV_LAST_AT)?.decodeToString()?.toLongOrNull()?.takeIf { it > 0 }
        set(value) = kv.put(KV_LAST_AT, (value ?: 0L).toString().toByteArray())

    /** The stored key, or null if none has been generated on this device. */
    fun recoveryKey(): ByteArray? = kv.get(KV_RECOVERY_KEY)?.takeIf { it.size == 32 }

    /** The key as the user sees it, generating one on first use. */
    fun ensureRecoveryKey(): String {
        recoveryKey()?.let { return BackupCrypto.format(it) }
        val fresh = BackupCrypto.randomRecoveryKey()
        kv.put(KV_RECOVERY_KEY, fresh)
        return BackupCrypto.format(fresh)
    }

    /** Adopts a key entered during a restore, so backups continue from here. */
    fun adoptRecoveryKey(key: ByteArray) {
        require(key.size == 32) { "a recovery key is 32 bytes" }
        kv.put(KV_RECOVERY_KEY, key)
    }

    fun forget() {
        kv.delete(KV_RECOVERY_KEY)
        kv.delete(KV_ENABLED)
        kv.delete(KV_LAST_AT)
    }

    private companion object {
        // iOS's UserDefaults/Keychain names, kept so the two clients' settings
        // read the same in a support conversation.
        const val KV_ENABLED = "relay.icloudBackup.enabled"
        const val KV_LAST_AT = "relay.icloudBackup.lastAt"
        const val KV_RECOVERY_KEY = "relay.icloudBackup.recoveryKey"
    }
}
