package app.relaymsg.net

import app.relaymsg.crypto.MessageKind
import app.relaymsg.crypto.SecureMessage
import relay.v1.Relay

/**
 * Bridges `:crypto`'s transport-agnostic types to the relay's protobuf enums.
 * Kept in one place so a schema change breaks exactly here — the same reason
 * iOS keeps `WireMapping.swift`.
 */

fun MessageKind.toWire(): Relay.CiphertextType = when (this) {
    MessageKind.PRE_KEY -> Relay.CiphertextType.CIPHERTEXT_TYPE_PREKEY_MESSAGE
    MessageKind.MESSAGE -> Relay.CiphertextType.CIPHERTEXT_TYPE_MESSAGE
    MessageKind.SENDER_KEY -> Relay.CiphertextType.CIPHERTEXT_TYPE_SENDER_KEY_MESSAGE
}

fun Relay.CiphertextType.toMessageKind(): MessageKind? = when (this) {
    Relay.CiphertextType.CIPHERTEXT_TYPE_PREKEY_MESSAGE -> MessageKind.PRE_KEY
    Relay.CiphertextType.CIPHERTEXT_TYPE_MESSAGE -> MessageKind.MESSAGE
    Relay.CiphertextType.CIPHERTEXT_TYPE_SENDER_KEY_MESSAGE -> MessageKind.SENDER_KEY
    else -> null
}

/** One decrypted-ready ciphertext received from the relay. */
data class IncomingEnvelope(
    val id: String,
    /**
     * Server-stamped sender. **Empty means sealed sender** — the relay does not
     * know who sent it, and the recipient recovers the sender from the sealed
     * blob's certificate instead (PROTOCOL.md §1.6).
     */
    val senderAccount: String,
    val senderDevice: Int,
    val message: SecureMessage,
    val clientTimestamp: Long,
    val serverTimestamp: Long,
    val ephemeral: Boolean,
) {
    companion object {
        fun from(proto: Relay.Envelope): IncomingEnvelope? {
            val kind = proto.type.toMessageKind() ?: return null
            return IncomingEnvelope(
                id = proto.id,
                senderAccount = proto.senderAccount,
                senderDevice = proto.senderDevice,
                message = SecureMessage(kind, proto.content.toByteArray()),
                clientTimestamp = proto.clientTimestamp,
                serverTimestamp = proto.serverTimestamp,
                ephemeral = proto.ephemeral,
            )
        }

        /** Parses a serialized `relay.v1.Envelope` — the push and queue-poll paths. */
        fun parse(serialized: ByteArray): IncomingEnvelope? =
            runCatching { Relay.Envelope.parseFrom(serialized) }.getOrNull()?.let(::from)
    }
}

/** A ciphertext addressed to one specific device — the per-device fan-out unit. */
data class DeviceMessagePayload(
    val deviceId: Int,
    /** The recipient's registration id as our session knows it; 0 skips the check. */
    val registrationId: Int,
    val message: SecureMessage,
)

/** The relay's verdict on a send. */
sealed interface SendOutcome {
    data class Ok(val serverTimestamp: Long) : SendOutcome

    /**
     * The fan-out did not match the account's devices.
     *
     * Note the server lists **every other device** of the destination in
     * [missing] on a cross-account send — including ones an earlier frame already
     * reached. Retrying everything here duplicates messages; see the filtering
     * rule in PROTOCOL.md §4.2.
     */
    data class MismatchedDevices(
        val missing: List<Int>,
        val extra: List<Int>,
        val stale: List<Int>,
    ) : SendOutcome

    data object UnknownAccount : SendOutcome
    data object RateLimited : SendOutcome
    data object ServerError : SendOutcome

    companion object {
        fun from(proto: Relay.SendResponse): SendOutcome = when (proto.status) {
            Relay.SendStatus.SEND_STATUS_OK -> Ok(proto.serverTimestamp)
            Relay.SendStatus.SEND_STATUS_MISMATCHED_DEVICES -> MismatchedDevices(
                missing = proto.missingDevicesList,
                extra = proto.extraDevicesList,
                stale = proto.staleDevicesList,
            )
            Relay.SendStatus.SEND_STATUS_UNKNOWN_ACCOUNT -> UnknownAccount
            Relay.SendStatus.SEND_STATUS_RATE_LIMITED -> RateLimited
            else -> ServerError
        }
    }
}

/** A signed remote-wipe command. Verify the signature before wiping anything. */
data class NukeEvent(
    val accountId: String,
    val commandId: String,
    val creationTimeMs: Long,
    val initiatingDeviceId: Int,
    /** ECDSA-P256 ASN.1/DER over the canonical nuke payload. */
    val signature: ByteArray,
) {
    override fun equals(other: Any?): Boolean = this === other || (
        other is NukeEvent && accountId == other.accountId && commandId == other.commandId &&
            creationTimeMs == other.creationTimeMs &&
            initiatingDeviceId == other.initiatingDeviceId &&
            signature.contentEquals(other.signature)
        )

    override fun hashCode(): Int = 31 * commandId.hashCode() + signature.contentHashCode()
}

/** The account's device list changed; refresh bundles. Not E2EE — we own all our devices. */
data class DeviceListChangedEvent(val action: Action, val deviceId: Int) {
    enum class Action { ADDED, REMOVED, UNKNOWN }
}
