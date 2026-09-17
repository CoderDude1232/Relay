package app.relaymsg.crypto

import org.signal.libsignal.protocol.message.CiphertextMessage
import org.signal.libsignal.protocol.state.SignalProtocolStore

/**
 * Plain value types crossing the crypto boundary.
 *
 * These mirror the relay's REST/WebSocket schema but deliberately carry no
 * networking or protobuf dependency — `:crypto` stays a pure crypto module, the
 * same rule the iOS `CryptoCore` package follows. The mapping onto the wire
 * enums lives in `:net`.
 */

/**
 * All libsignal state stores the engine needs. libsignal's `SignalProtocolStore`
 * already spans identity, pre-key, signed-pre-key, Kyber-pre-key, session and
 * sender-key storage, so this is the direct counterpart of iOS's `SignalStores`
 * typealias. Stage 2 backs it with libsignal's in-memory implementation; Stage 3
 * swaps in the SQLCipher-backed one behind the same interface.
 */
typealias RelayProtocolStore = SignalProtocolStore

/**
 * The kind of libsignal ciphertext, so the receiving side knows how to decrypt.
 * Maps 1:1 onto the relay's `CiphertextType` protobuf enum (done in `:net`).
 */
enum class MessageKind {
    /** PreKeySignalMessage: first message of a session, carrying PQXDH material. */
    PRE_KEY,

    /** SignalMessage: normal Double Ratchet message in an established session. */
    MESSAGE,

    /** SenderKeyMessage: group message encrypted with a sender key. */
    SENDER_KEY,
    ;

    internal companion object {
        fun fromCiphertextType(type: Int): MessageKind = when (type) {
            CiphertextMessage.PREKEY_TYPE -> PRE_KEY
            CiphertextMessage.SENDERKEY_TYPE -> SENDER_KEY
            else -> MESSAGE
        }
    }
}

/**
 * A ciphertext together with its kind — what [CryptoEngine.encrypt] produces and
 * [CryptoEngine.decrypt] consumes. The [data] bytes travel opaquely through the relay.
 */
data class SecureMessage(val kind: MessageKind, val data: ByteArray) {
    // ByteArray needs structural equality spelled out.
    override fun equals(other: Any?): Boolean =
        this === other ||
            (other is SecureMessage && kind == other.kind && data.contentEquals(other.data))

    override fun hashCode(): Int = 31 * kind.hashCode() + data.contentHashCode()
}

/** A public one-time pre-key as uploaded to / served by the relay. */
data class PublicPreKey(val id: Int, val publicKey: ByteArray) {
    override fun equals(other: Any?): Boolean =
        this === other ||
            (other is PublicPreKey && id == other.id && publicKey.contentEquals(other.publicKey))

    override fun hashCode(): Int = 31 * id + publicKey.contentHashCode()
}

/**
 * A public pre-key signed by the device's identity key — either the signed EC
 * pre-key or the last-resort Kyber pre-key; both share this shape.
 */
data class SignedPublicPreKey(
    val id: Int,
    val publicKey: ByteArray,
    val signature: ByteArray,
) {
    override fun equals(other: Any?): Boolean =
        this === other || (
            other is SignedPublicPreKey &&
                id == other.id &&
                publicKey.contentEquals(other.publicKey) &&
                signature.contentEquals(other.signature)
            )

    override fun hashCode(): Int =
        31 * (31 * id + publicKey.contentHashCode()) + signature.contentHashCode()
}

/**
 * Everything a device publishes (`PUT /v1/keys`) so peers can establish PQXDH
 * sessions with it. Public material only.
 */
data class PreKeyPublication(
    val registrationId: Int,
    val identityKey: ByteArray,
    val signedPreKey: SignedPublicPreKey,
    /** Last-resort Kyber pre-key; PQXDH requires one in every bundle. */
    val kyberPreKey: SignedPublicPreKey,
    val oneTimePreKeys: List<PublicPreKey>,
) {
    override fun equals(other: Any?): Boolean =
        this === other || (
            other is PreKeyPublication &&
                registrationId == other.registrationId &&
                identityKey.contentEquals(other.identityKey) &&
                signedPreKey == other.signedPreKey &&
                kyberPreKey == other.kyberPreKey &&
                oneTimePreKeys == other.oneTimePreKeys
            )

    override fun hashCode(): Int {
        var result = registrationId
        result = 31 * result + identityKey.contentHashCode()
        result = 31 * result + signedPreKey.hashCode()
        result = 31 * result + kyberPreKey.hashCode()
        result = 31 * result + oneTimePreKeys.hashCode()
        return result
    }
}

/**
 * A peer device's bundle as fetched from `GET /v1/keys/{account}`.
 *
 * [oneTimePreKey] is null when the peer's pool is exhausted — the session is then
 * established from the signed pre-key alone (degraded but valid), and both bundle
 * shapes must be handled.
 */
data class PeerPreKeyBundle(
    val deviceId: Int,
    val mailboxId: String? = null,
    val registrationId: Int,
    val identityKey: ByteArray,
    val signedPreKey: SignedPublicPreKey,
    val kyberPreKey: SignedPublicPreKey,
    val oneTimePreKey: PublicPreKey?,
) {
    override fun equals(other: Any?): Boolean =
        this === other || (
            other is PeerPreKeyBundle &&
                deviceId == other.deviceId &&
                mailboxId == other.mailboxId &&
                registrationId == other.registrationId &&
                identityKey.contentEquals(other.identityKey) &&
                signedPreKey == other.signedPreKey &&
                kyberPreKey == other.kyberPreKey &&
                oneTimePreKey == other.oneTimePreKey
            )

    override fun hashCode(): Int {
        var result = deviceId
        result = 31 * result + (mailboxId?.hashCode() ?: 0)
        result = 31 * result + registrationId
        result = 31 * result + identityKey.contentHashCode()
        result = 31 * result + signedPreKey.hashCode()
        result = 31 * result + kyberPreKey.hashCode()
        result = 31 * result + (oneTimePreKey?.hashCode() ?: 0)
        return result
    }
}

/**
 * A safety number for out-of-band identity verification: the 60-digit string
 * users compare, and the scannable encoding for QR codes.
 */
data class SafetyNumber(val numeric: String, val scannable: ByteArray) {
    override fun equals(other: Any?): Boolean =
        this === other || (
            other is SafetyNumber &&
                numeric == other.numeric &&
                scannable.contentEquals(other.scannable)
            )

    override fun hashCode(): Int = 31 * numeric.hashCode() + scannable.contentHashCode()
}
