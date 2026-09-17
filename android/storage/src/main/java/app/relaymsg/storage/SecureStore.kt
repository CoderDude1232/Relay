package app.relaymsg.storage

import android.content.Context
import app.relaymsg.crypto.CryptoEngine
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.SignalProtocolAddress

/**
 * Composition root for the encrypted local store — the counterpart of iOS's
 * `SecureStore` (named that way there because `SecureStorage` collided with the
 * module name).
 *
 * Opening it does three things in order: get the master key from the Android
 * Keystore, open the SQLCipher database with it, and expose the libsignal stores
 * and message store over that database.
 *
 * The device identity key pair and registration id come from [MasterKeyStore]
 * and never touch the database, the same split iOS keeps between the Keychain
 * and SQLCipher.
 */
class SecureStore private constructor(
    val database: RelayDatabase,
    val keys: MasterKeyStore,
    val signalStore: SqlCipherSignalStore,
    val messages: MessageStore,
) {
    companion object {
        /**
         * Opens the store for [context], creating the key material and database on
         * first run.
         */
        fun open(context: Context): SecureStore {
            val keys = MasterKeyStore(context)
            val masterKey = keys.databaseKey()
            val database = try {
                RelayDatabase.open(context, masterKey)
            } finally {
                // SQLCipher copies the passphrase; don't leave ours in the heap.
                masterKey.fill(0)
            }
            return build(database, keys)
        }

        /** Opens an in-memory store against the given key material. For tests. */
        fun openInMemory(keys: MasterKeyStore): SecureStore {
            val masterKey = keys.databaseKey()
            val database = try {
                RelayDatabase.openInMemory(masterKey)
            } finally {
                masterKey.fill(0)
            }
            return build(database, keys)
        }

        private fun build(database: RelayDatabase, keys: MasterKeyStore): SecureStore {
            val credentials = KeystoreIdentityCredentials(keys)
            return SecureStore(
                database = database,
                keys = keys,
                signalStore = SqlCipherSignalStore(database, credentials),
                messages = MessageStore(database),
            )
        }
    }

    /**
     * A [CryptoEngine] bound to this device's identity and backed by the
     * encrypted stores — what every crypto operation above this layer runs on.
     */
    fun makeCryptoEngine(accountId: String, deviceId: Int): CryptoEngine =
        CryptoEngine(signalStore, SignalProtocolAddress(accountId, deviceId))

    fun close() = database.close()

    /**
     * Destroys every local secret: the database contents and the Keystore-held
     * identity and wrapping key. This is the local half of a remote wipe, and it
     * is irreversible — the wrapping key cannot be recovered, so any surviving
     * copy of the database file is permanently undecryptable.
     */
    fun wipe() {
        database.transaction {
            listOf(
                "messages", "conversations", "reactions", "message_receipts", "attachments",
                "sessions", "remote_identities", "prekeys", "signed_prekeys", "kyber_prekeys",
                "kyber_prekey_uses", "sender_keys", "group_state", "group_members", "profiles",
                "calls", "poll_votes", "processed_envelopes", "kv",
            ).forEach { database.run("DELETE FROM $it") }
        }
        keys.wipe()
    }

    /**
     * Supplies the device's own identity from the Keystore, generating it on
     * first use. The private half never reaches SQLCipher.
     */
    private class KeystoreIdentityCredentials(
        private val keys: MasterKeyStore,
    ) : SqlCipherSignalStore.IdentityCredentials {

        override fun identityKeyPair(): IdentityKeyPair {
            keys.identityKeyPair()?.let { return IdentityKeyPair(it) }
            val generated = IdentityKeyPair.generate()
            keys.storeIdentityKeyPair(generated.serialize())
            return generated
        }

        override fun registrationId(): Int = keys.registrationId()
    }
}
