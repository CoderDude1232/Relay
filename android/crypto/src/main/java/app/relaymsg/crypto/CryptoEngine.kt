package app.relaymsg.crypto

import java.util.Optional
import java.util.UUID
import org.signal.libsignal.metadata.SealedSessionCipher
import org.signal.libsignal.metadata.certificate.CertificateValidator
import org.signal.libsignal.metadata.certificate.SenderCertificate
import org.signal.libsignal.metadata.protocol.UnidentifiedSenderMessageContent
import org.signal.libsignal.protocol.IdentityKey
import org.signal.libsignal.protocol.SessionBuilder
import org.signal.libsignal.protocol.SessionCipher
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.ecc.ECKeyPair
import org.signal.libsignal.protocol.ecc.ECPublicKey
import org.signal.libsignal.protocol.fingerprint.Fingerprint
import org.signal.libsignal.protocol.fingerprint.NumericFingerprintGenerator
import org.signal.libsignal.protocol.groups.GroupCipher
import org.signal.libsignal.protocol.groups.GroupSessionBuilder
import org.signal.libsignal.protocol.kem.KEMKeyPair
import org.signal.libsignal.protocol.kem.KEMKeyType
import org.signal.libsignal.protocol.kem.KEMPublicKey
import org.signal.libsignal.protocol.message.CiphertextMessage
import org.signal.libsignal.protocol.message.PreKeySignalMessage
import org.signal.libsignal.protocol.message.SenderKeyDistributionMessage
import org.signal.libsignal.protocol.message.SignalMessage
import org.signal.libsignal.protocol.state.KyberPreKeyRecord
import org.signal.libsignal.protocol.state.PreKeyBundle
import org.signal.libsignal.protocol.state.PreKeyRecord
import org.signal.libsignal.protocol.state.SignedPreKeyRecord

/**
 * The single entry point for all Signal-protocol operations: identity and
 * pre-key generation, PQXDH session establishment, Double Ratchet
 * encrypt/decrypt, sender keys, sealed sender and safety numbers.
 *
 * Nothing above this layer touches libsignal types directly — the direct
 * counterpart of iOS's `CryptoCore.CryptoEngine`, and every parameter here is
 * pinned by `android/PROTOCOL.md` §1.
 */
class CryptoEngine(
    private val store: RelayProtocolStore,
    val localAddress: SignalProtocolAddress,
) {
    companion object {
        /** Signal's production parameters for safety-number generation (PROTOCOL.md §1.5). */
        private const val FINGERPRINT_ITERATIONS = 5200
        private const val FINGERPRINT_VERSION = 2

        /**
         * Computes the safety number between two identities. Both parties must pass
         * the same stable identifiers (account ids) for their halves to produce the
         * same 60-digit string.
         */
        fun safetyNumber(
            localIdentifier: String,
            localIdentityKey: ByteArray,
            remoteIdentifier: String,
            remoteIdentityKey: ByteArray,
        ): SafetyNumber {
            val fingerprint = NumericFingerprintGenerator(FINGERPRINT_ITERATIONS).createFor(
                FINGERPRINT_VERSION,
                localIdentifier.toByteArray(),
                IdentityKey(localIdentityKey),
                remoteIdentifier.toByteArray(),
                IdentityKey(remoteIdentityKey),
            )
            return fingerprint.toSafetyNumber()
        }

        private fun Fingerprint.toSafetyNumber() = SafetyNumber(
            numeric = displayableFingerprint.displayText,
            scannable = scannableFingerprint.serialized,
        )
    }

    // ---------------------------------------------------------------- identity

    fun registrationId(): Int = store.localRegistrationId

    /**
     * The serialized public identity key (33 bytes, `0x05 ‖ X`) — what peers see
     * and what safety numbers are computed from. The private half never leaves
     * the store.
     */
    fun identityKey(): ByteArray = store.identityKeyPair.publicKey.serialize()

    // ---------------------------------------------------------------- pre-keys

    /**
     * Generates and stores a signed pre-key, a last-resort Kyber pre-key and a
     * batch of one-time pre-keys, returning the public halves for upload to the
     * relay.
     *
     * Pass an empty [oneTimePreKeyIds] range to re-publish only the identity,
     * signed pre-key and Kyber pre-key — what the client does on every launch so
     * the relay can never serve a signed pre-key whose private half was lost to a
     * reinstall (PROTOCOL.md §1.3).
     */
    fun generatePreKeyPublication(
        signedPreKeyId: Int,
        kyberPreKeyId: Int,
        oneTimePreKeyIds: IntRange,
    ): PreKeyPublication {
        val identityKeyPair = store.identityKeyPair
        val now = System.currentTimeMillis()

        val signedPair = ECKeyPair.generate()
        val signedPublic = signedPair.publicKey.serialize()
        val signedSignature = identityKeyPair.privateKey.calculateSignature(signedPublic)
        store.storeSignedPreKey(
            signedPreKeyId,
            SignedPreKeyRecord(signedPreKeyId, now, signedPair, signedSignature),
        )

        val kyberPair = KEMKeyPair.generate(KEMKeyType.KYBER_1024)
        val kyberPublic = kyberPair.publicKey.serialize()
        val kyberSignature = identityKeyPair.privateKey.calculateSignature(kyberPublic)
        store.storeKyberPreKey(
            kyberPreKeyId,
            KyberPreKeyRecord(kyberPreKeyId, now, kyberPair, kyberSignature),
        )

        val oneTimeKeys = oneTimePreKeyIds.map { id ->
            val pair = ECKeyPair.generate()
            store.storePreKey(id, PreKeyRecord(id, pair))
            PublicPreKey(id = id, publicKey = pair.publicKey.serialize())
        }

        return PreKeyPublication(
            registrationId = registrationId(),
            identityKey = identityKey(),
            signedPreKey = SignedPublicPreKey(signedPreKeyId, signedPublic, signedSignature),
            kyberPreKey = SignedPublicPreKey(kyberPreKeyId, kyberPublic, kyberSignature),
            oneTimePreKeys = oneTimeKeys,
        )
    }

    // ---------------------------------------------------------------- sessions

    /**
     * Runs PQXDH against a fetched peer bundle, establishing an outbound session
     * with that device. The next [encrypt] for this address yields a
     * [MessageKind.PRE_KEY] message carrying the handshake.
     */
    fun processPeerBundle(bundle: PeerPreKeyBundle, address: SignalProtocolAddress) {
        val identity = IdentityKey(bundle.identityKey)
        val signedPreKey = ECPublicKey(bundle.signedPreKey.publicKey)
        val kyberPreKey = KEMPublicKey(bundle.kyberPreKey.publicKey)

        // A null one-time pre-key means the peer's pool is exhausted. libsignal
        // encodes "no one-time pre-key" as NULL_PRE_KEY_ID with a null key.
        val preKeyId = bundle.oneTimePreKey?.id ?: PreKeyBundle.NULL_PRE_KEY_ID
        val preKey = bundle.oneTimePreKey?.let { ECPublicKey(it.publicKey) }

        val libsignalBundle = PreKeyBundle(
            bundle.registrationId,
            bundle.deviceId,
            preKeyId,
            preKey,
            bundle.signedPreKey.id,
            signedPreKey,
            bundle.signedPreKey.signature,
            identity,
            bundle.kyberPreKey.id,
            kyberPreKey,
            bundle.kyberPreKey.signature,
        )
        SessionBuilder(store, address, localAddress).process(libsignalBundle)
    }

    fun hasSession(address: SignalProtocolAddress): Boolean =
        store.containsSession(address)

    // --------------------------------------------------------- encrypt/decrypt

    fun encrypt(plaintext: ByteArray, address: SignalProtocolAddress): SecureMessage {
        val ciphertext = sessionCipher(address).encrypt(plaintext)
        return SecureMessage(
            kind = MessageKind.fromCiphertextType(ciphertext.type),
            data = ciphertext.serialize(),
        )
    }

    /**
     * CAREFUL: `SessionBuilder` takes (remote, local) but `SessionCipher` takes
     * (local, remote) — the two libsignal classes order their addresses
     * oppositely. Getting it wrong stores the session correctly and then fails to
     * find it at encrypt time, so it is funnelled through this one helper.
     */
    private fun sessionCipher(remote: SignalProtocolAddress) =
        SessionCipher(store, localAddress, remote)

    fun decrypt(message: SecureMessage, address: SignalProtocolAddress): ByteArray {
        val cipher = sessionCipher(address)
        return when (message.kind) {
            MessageKind.PRE_KEY -> cipher.decrypt(PreKeySignalMessage(message.data))
            MessageKind.MESSAGE -> cipher.decrypt(SignalMessage(message.data))
            // Group message: libsignal finds the sender key from the distribution
            // id embedded in the ciphertext. The SKDM must have been processed first.
            MessageKind.SENDER_KEY -> GroupCipher(store, address).decrypt(message.data)
        }
    }

    // ----------------------------------------------------------- sealed sender

    /** The recovered sender identity and inner plaintext of a sealed-sender message. */
    data class SealedSenderDecryptResult(
        val senderAccountId: String,
        val senderDeviceId: Int,
        val plaintext: ByteArray,
    ) {
        override fun equals(other: Any?): Boolean =
            this === other || (
                other is SealedSenderDecryptResult &&
                    senderAccountId == other.senderAccountId &&
                    senderDeviceId == other.senderDeviceId &&
                    plaintext.contentEquals(other.plaintext)
                )

        override fun hashCode(): Int {
            var result = senderAccountId.hashCode()
            result = 31 * result + senderDeviceId
            result = 31 * result + plaintext.contentHashCode()
            return result
        }
    }

    /**
     * The sealed blob could not be trusted: the sender certificate failed to
     * validate against the trust root, it had expired at the validation
     * timestamp, or the outer envelope was malformed.
     *
     * libsignal reports all three as `InvalidMetadataMessageException` rather
     * than distinguishing them, and the client's response is identical in every
     * case — ack the envelope and drop it, per the poison-message policy — so
     * they are collapsed into one type here.
     */
    class InvalidSenderCertificateException(cause: Throwable? = null) :
        Exception("sealed sender message did not validate", cause)

    /**
     * Encrypts [plaintext] for [address] as a sealed-sender message: the normal
     * Double Ratchet ciphertext wrapped in an outer layer encrypted to the
     * recipient's identity key, carrying [senderCertificate]. The relay sees only
     * an opaque blob addressed to a mailbox — not the sender.
     *
     * [senderCertificate] is the serialized certificate from
     * `GET /v1/certificate/delivery`. [groupId] is empty even for group sends,
     * matching iOS (PROTOCOL.md §1.6).
     */
    fun sealedEncrypt(
        plaintext: ByteArray,
        address: SignalProtocolAddress,
        senderCertificate: ByteArray,
        groupId: ByteArray = ByteArray(0),
    ): ByteArray {
        val certificate = SenderCertificate(senderCertificate)
        val ciphertext = sessionCipher(address).encrypt(plaintext)
        val content = UnidentifiedSenderMessageContent(
            ciphertext,
            certificate,
            UnidentifiedSenderMessageContent.CONTENT_HINT_DEFAULT,
            if (groupId.isEmpty()) Optional.empty() else Optional.of(groupId),
        )
        return sealedCipher().encrypt(address, content)
    }

    /**
     * Decrypts a sealed-sender blob: unwraps the outer layer with our identity
     * key, validates the sender certificate against [trustRoot] (the 33-byte
     * serialized public key) at [timestampMs], then decrypts the inner message
     * from the recovered sender.
     *
     * Callers pass the envelope's `server_timestamp` as [timestampMs] so a
     * certificate that was valid when the relay accepted the message still
     * validates after a delayed delivery.
     */
    fun sealedDecrypt(
        sealed: ByteArray,
        trustRoot: ByteArray,
        timestampMs: Long,
    ): SealedSenderDecryptResult {
        val validator = CertificateValidator(ECPublicKey(trustRoot))
        val result = try {
            sealedCipher().decrypt(validator, sealed, timestampMs)
        } catch (e: org.signal.libsignal.metadata.certificate.InvalidCertificateException) {
            throw InvalidSenderCertificateException(e)
        } catch (e: org.signal.libsignal.metadata.InvalidMetadataMessageException) {
            throw InvalidSenderCertificateException(e)
        }
        return SealedSenderDecryptResult(
            senderAccountId = result.senderUuid,
            senderDeviceId = result.deviceId,
            plaintext = result.paddedMessage,
        )
    }

    /**
     * libsignal needs our own identity to detect self-sends. Relay account ids are
     * RFC 4122 v4 UUIDs (the relay's `newUUID`), so the local address name parses
     * directly; there is no separate ACI namespace in this protocol.
     */
    private fun sealedCipher() = SealedSessionCipher(
        store,
        UUID.fromString(localAddress.name),
        null,
        localAddress.deviceId,
    )

    // --------------------------------------------------------- groups / sender keys

    /**
     * Creates (or loads) this device's sender key for [distributionId] and returns
     * the Sender Key Distribution Message to hand to each group member over their
     * pairwise session, so they can decrypt our group messages. A fresh
     * [distributionId] yields a fresh sender key — how a removed member is locked
     * out (PROTOCOL.md §1.4).
     */
    fun senderKeyDistributionMessage(distributionId: UUID): ByteArray =
        GroupSessionBuilder(store).create(localAddress, distributionId).serialize()

    /** Processes a peer's SKDM so we can later decrypt their group messages. */
    fun processSenderKeyDistribution(data: ByteArray, address: SignalProtocolAddress) {
        GroupSessionBuilder(store).process(address, SenderKeyDistributionMessage(data))
    }

    /**
     * Encrypts a group message once with our sender key; the same ciphertext is
     * fanned out to every member device. Only used when sealed sender is off —
     * sealed group sends go out as individual pairwise messages.
     */
    fun groupEncrypt(plaintext: ByteArray, distributionId: UUID): SecureMessage {
        val ciphertext: CiphertextMessage =
            GroupCipher(store, localAddress).encrypt(distributionId, plaintext)
        return SecureMessage(kind = MessageKind.SENDER_KEY, data = ciphertext.serialize())
    }

    // -------------------------------------------------------------- safety numbers

    /**
     * The safety number for a peer using their currently stored identity key, or
     * null when no identity has been recorded yet (no session established).
     * Account ids are the stable identifiers, so both parties derive the same
     * 60 digits.
     */
    fun safetyNumber(remoteAccount: String): SafetyNumber? =
        fingerprintWith(remoteAccount)?.toSafetyNumber()

    /**
     * Compares a scannable encoding read from the peer's QR code against the
     * locally computed one. Returns false when we have no identity for the peer
     * yet; throws if the encoding is malformed or uses an incompatible version.
     * The comparison is order-independent.
     */
    fun verifyScannedSafetyNumber(scannedEncoding: ByteArray, remoteAccount: String): Boolean =
        fingerprintWith(remoteAccount)?.scannableFingerprint?.compareTo(scannedEncoding) ?: false

    /**
     * Builds the libsignal fingerprint between us and [remoteAccount] from stored
     * identities. The device id is irrelevant — identities are keyed by account.
     */
    private fun fingerprintWith(remoteAccount: String): Fingerprint? {
        val address = SignalProtocolAddress(remoteAccount, 1)
        val remoteIdentity = store.getIdentity(address) ?: return null
        return NumericFingerprintGenerator(FINGERPRINT_ITERATIONS).createFor(
            FINGERPRINT_VERSION,
            localAddress.name.toByteArray(),
            store.identityKeyPair.publicKey,
            remoteAccount.toByteArray(),
            remoteIdentity,
        )
    }
}
