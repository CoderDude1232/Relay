package app.relaymsg.storage

import app.relaymsg.crypto.RelayProtocolStore
import java.util.UUID
import org.signal.libsignal.protocol.IdentityKey
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.groups.state.SenderKeyRecord
import org.signal.libsignal.protocol.state.IdentityKeyStore.IdentityChange
import org.signal.libsignal.protocol.state.KyberPreKeyRecord
import org.signal.libsignal.protocol.state.PreKeyRecord
import org.signal.libsignal.protocol.state.SessionRecord
import org.signal.libsignal.protocol.state.SignedPreKeyRecord

/**
 * The six libsignal state stores backed by the SQLCipher database, replacing the
 * in-memory stores from the crypto stage. Implements [RelayProtocolStore], so a
 * `CryptoEngine` runs unchanged on top of it.
 *
 * Identity policy is **trust on first use**: an unknown peer identity is trusted
 * and recorded; a *changed* identity is untrusted and resets any prior
 * verification, which is what drives the safety-number-changed warning.
 *
 * The device's own identity key pair and registration id come from
 * [MasterKeyStore] and never enter this database.
 */
class SqlCipherSignalStore(
    private val db: RelayDatabase,
    private val credentials: IdentityCredentials,
) : RelayProtocolStore {

    /**
     * The device's own long-lived credentials. Production wires the
     * Keystore-backed implementation; tests can supply their own. The private
     * identity key deliberately never reaches SQLCipher.
     */
    interface IdentityCredentials {
        fun identityKeyPair(): IdentityKeyPair
        fun registrationId(): Int
    }

    private fun now() = System.currentTimeMillis()

    // ------------------------------------------------------ IdentityKeyStore

    override fun getIdentityKeyPair(): IdentityKeyPair = credentials.identityKeyPair()

    override fun getLocalRegistrationId(): Int = credentials.registrationId()

    override fun saveIdentity(address: SignalProtocolAddress, identity: IdentityKey): IdentityChange {
        val existing = getIdentity(address)
        if (existing == identity) return IdentityChange.NEW_OR_UNCHANGED
        // A changed key resets verification but leaves verified_key intact, so
        // the UI can still tell "was verified, key has since changed".
        db.run(
            """
            INSERT INTO remote_identities (address, identity_key, verified, first_seen_at)
            VALUES (?, ?, 0, ?)
            ON CONFLICT (address) DO UPDATE SET identity_key = excluded.identity_key, verified = 0
            """,
            listOf(address.name, identity.serialize(), now()),
        )
        return if (existing == null) IdentityChange.NEW_OR_UNCHANGED else IdentityChange.REPLACED_EXISTING
    }

    override fun isTrustedIdentity(
        address: SignalProtocolAddress,
        identity: IdentityKey,
        direction: org.signal.libsignal.protocol.state.IdentityKeyStore.Direction,
    ): Boolean {
        val known = getIdentity(address) ?: return true // trust on first use
        return known == identity
    }

    override fun getIdentity(address: SignalProtocolAddress): IdentityKey? =
        db.query(
            "SELECT identity_key FROM remote_identities WHERE address = ?",
            listOf(address.name),
        ) { IdentityKey(it.blob(0)) }.firstOrNull()

    // ------------------------------------------------- verification state

    /** The out-of-band verification status of a peer's identity. */
    enum class VerificationState {
        /** Never verified, or verification was explicitly cleared. */
        UNVERIFIED,

        /** Verified, and the identity key is unchanged since. */
        VERIFIED,

        /** Was verified, but the key has since changed — the user should re-verify. */
        CHANGED,
    }

    fun isVerified(address: String): Boolean =
        verificationState(address) == VerificationState.VERIFIED

    /**
     * Marks a peer verified (recording the current key) or clears verification,
     * which also dismisses a pending "changed" warning.
     */
    fun setVerified(verified: Boolean, address: String) {
        if (verified) {
            db.run(
                "UPDATE remote_identities SET verified = 1, verified_key = identity_key WHERE address = ?",
                listOf(address),
            )
        } else {
            db.run(
                "UPDATE remote_identities SET verified = 0, verified_key = NULL WHERE address = ?",
                listOf(address),
            )
        }
    }

    fun verificationState(address: String): VerificationState =
        db.query(
            "SELECT verified, identity_key, verified_key FROM remote_identities WHERE address = ?",
            listOf(address),
        ) { row ->
            when {
                row.int(0) == 1 -> VerificationState.VERIFIED
                row.blobOrNull(2) == null -> VerificationState.UNVERIFIED
                !row.blob(2).contentEquals(row.blob(1)) -> VerificationState.CHANGED
                else -> VerificationState.UNVERIFIED
            }
        }.firstOrNull() ?: VerificationState.UNVERIFIED

    // ------------------------------------------------------------ PreKeyStore

    override fun loadPreKey(id: Int): PreKeyRecord =
        db.query("SELECT record FROM prekeys WHERE id = ?", listOf(id)) { PreKeyRecord(it.blob(0)) }
            .firstOrNull()
            ?: throw org.signal.libsignal.protocol.InvalidKeyIdException("no prekey $id")

    override fun storePreKey(id: Int, record: PreKeyRecord) {
        db.run(
            "INSERT OR REPLACE INTO prekeys (id, record) VALUES (?, ?)",
            listOf(id, record.serialize()),
        )
    }

    override fun containsPreKey(id: Int): Boolean =
        db.query("SELECT 1 FROM prekeys WHERE id = ?", listOf(id)) { it.int(0) }.isNotEmpty()

    /** One-time prekeys are consumed on use — that is the point of them. */
    override fun removePreKey(id: Int) {
        db.run("DELETE FROM prekeys WHERE id = ?", listOf(id))
    }

    // ------------------------------------------------------ SignedPreKeyStore

    override fun loadSignedPreKey(id: Int): SignedPreKeyRecord =
        db.query("SELECT record FROM signed_prekeys WHERE id = ?", listOf(id)) {
            SignedPreKeyRecord(it.blob(0))
        }.firstOrNull()
            ?: throw org.signal.libsignal.protocol.InvalidKeyIdException("no signed prekey $id")

    override fun loadSignedPreKeys(): List<SignedPreKeyRecord> =
        db.query("SELECT record FROM signed_prekeys") { SignedPreKeyRecord(it.blob(0)) }

    override fun storeSignedPreKey(id: Int, record: SignedPreKeyRecord) {
        db.run(
            "INSERT OR REPLACE INTO signed_prekeys (id, record) VALUES (?, ?)",
            listOf(id, record.serialize()),
        )
    }

    override fun containsSignedPreKey(id: Int): Boolean =
        db.query("SELECT 1 FROM signed_prekeys WHERE id = ?", listOf(id)) { it.int(0) }.isNotEmpty()

    override fun removeSignedPreKey(id: Int) {
        db.run("DELETE FROM signed_prekeys WHERE id = ?", listOf(id))
    }

    // ------------------------------------------------------- KyberPreKeyStore

    override fun loadKyberPreKey(id: Int): KyberPreKeyRecord =
        db.query("SELECT record FROM kyber_prekeys WHERE id = ?", listOf(id)) {
            KyberPreKeyRecord(it.blob(0))
        }.firstOrNull()
            ?: throw org.signal.libsignal.protocol.InvalidKeyIdException("no kyber prekey $id")

    override fun loadKyberPreKeys(): List<KyberPreKeyRecord> =
        db.query("SELECT record FROM kyber_prekeys") { KyberPreKeyRecord(it.blob(0)) }

    override fun storeKyberPreKey(id: Int, record: KyberPreKeyRecord) {
        db.run(
            "INSERT OR REPLACE INTO kyber_prekeys (id, record, used) VALUES (?, ?, 0)",
            listOf(id, record.serialize()),
        )
    }

    override fun containsKyberPreKey(id: Int): Boolean =
        db.query("SELECT 1 FROM kyber_prekeys WHERE id = ?", listOf(id)) { it.int(0) }.isNotEmpty()

    /**
     * Marks the Kyber prekey used, and enforces replay protection.
     *
     * Relay publishes a single **last-resort** Kyber prekey per device with no
     * one-time pool (PROTOCOL.md §1.3), so the record is marked used and kept —
     * deleting it would break every subsequent inbound PQXDH handshake.
     *
     * Because that key is reused by design, libsignal delegates replay detection
     * to the store: if this exact (kyberPreKeyId, signedPreKeyId, baseKey) tuple
     * has been seen before, the handshake is a replay of a captured
     * PreKeySignalMessage and must be refused.
     */
    override fun markKyberPreKeyUsed(
        kyberPreKeyId: Int,
        signedPreKeyId: Int,
        baseKey: org.signal.libsignal.protocol.ecc.ECPublicKey,
    ) {
        val serializedBaseKey = baseKey.serialize()
        val seen = db.query(
            """
            SELECT 1 FROM kyber_prekey_uses
            WHERE kyber_prekey_id = ? AND signed_prekey_id = ? AND base_key = ?
            """,
            listOf(kyberPreKeyId, signedPreKeyId, serializedBaseKey),
        ) { it.int(0) }.isNotEmpty()
        if (seen) {
            throw org.signal.libsignal.protocol.ReusedBaseKeyException(
                "replayed PQXDH handshake for kyber prekey $kyberPreKeyId",
            )
        }
        db.transaction {
            db.run(
                """
                INSERT INTO kyber_prekey_uses (kyber_prekey_id, signed_prekey_id, base_key, used_at)
                VALUES (?, ?, ?, ?)
                """,
                listOf(kyberPreKeyId, signedPreKeyId, serializedBaseKey, now()),
            )
            db.run("UPDATE kyber_prekeys SET used = 1 WHERE id = ?", listOf(kyberPreKeyId))
        }
    }

    // ----------------------------------------------------------- SessionStore

    override fun loadSession(address: SignalProtocolAddress): SessionRecord? =
        db.query(
            "SELECT record FROM sessions WHERE address = ? AND device_id = ?",
            listOf(address.name, address.deviceId),
        ) { SessionRecord(it.blob(0)) }.firstOrNull()

    override fun loadExistingSessions(addresses: List<SignalProtocolAddress>): List<SessionRecord> =
        addresses.map { address ->
            loadSession(address)
                ?: throw org.signal.libsignal.protocol.NoSessionException("no session for $address")
        }

    override fun getSubDeviceSessions(name: String): List<Int> =
        db.query(
            "SELECT device_id FROM sessions WHERE address = ? AND device_id != 1",
            listOf(name),
        ) { it.int(0) }

    override fun storeSession(address: SignalProtocolAddress, record: SessionRecord) {
        db.run(
            """
            INSERT INTO sessions (address, device_id, record, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT (address, device_id)
            DO UPDATE SET record = excluded.record, updated_at = excluded.updated_at
            """,
            listOf(address.name, address.deviceId, record.serialize(), now()),
        )
    }

    override fun containsSession(address: SignalProtocolAddress): Boolean =
        db.query(
            "SELECT 1 FROM sessions WHERE address = ? AND device_id = ?",
            listOf(address.name, address.deviceId),
        ) { it.int(0) }.isNotEmpty()

    override fun deleteSession(address: SignalProtocolAddress) {
        db.run(
            "DELETE FROM sessions WHERE address = ? AND device_id = ?",
            listOf(address.name, address.deviceId),
        )
    }

    /** Drops every session with a peer, forcing a fresh PQXDH handshake. */
    override fun deleteAllSessions(name: String) {
        db.run("DELETE FROM sessions WHERE address = ?", listOf(name))
    }

    // --------------------------------------------------------- SenderKeyStore

    override fun storeSenderKey(
        sender: SignalProtocolAddress,
        distributionId: UUID,
        record: SenderKeyRecord,
    ) {
        db.run(
            """
            INSERT OR REPLACE INTO sender_keys (sender, sender_device, distribution_id, record)
            VALUES (?, ?, ?, ?)
            """,
            listOf(sender.name, sender.deviceId, distributionId.toString(), record.serialize()),
        )
    }

    override fun loadSenderKey(
        sender: SignalProtocolAddress,
        distributionId: UUID,
    ): SenderKeyRecord? =
        db.query(
            """
            SELECT record FROM sender_keys
            WHERE sender = ? AND sender_device = ? AND distribution_id = ?
            """,
            listOf(sender.name, sender.deviceId, distributionId.toString()),
        ) { SenderKeyRecord(it.blob(0)) }.firstOrNull()
}
