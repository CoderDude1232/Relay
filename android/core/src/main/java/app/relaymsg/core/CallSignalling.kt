package app.relaymsg.core

import relay.content.ContentOuterClass.CallMessage
import relay.content.ContentOuterClass.Content
import relay.content.callMessage
import relay.content.content

/** An incoming call signal, once decrypted. */
data class CallSignal(
    val type: CallMessage.Type,
    val callId: String,
    val sdp: String,
    val ice: String,
    val fromAccount: String,
    val groupId: String,
    val targetAccount: String,
    val participants: List<String>,
)

/**
 * Builds and classifies call signalling messages (PROTOCOL.md §6.12).
 *
 * Call signalling rides the same E2EE envelope as any other content; the relay
 * sees only ciphertext and cannot tell a call from a message.
 */
object CallSignalling {

    /**
     * Whether a signal is sent **ephemeral** — delivered only to devices that are
     * connected right now, never queued.
     *
     * This must match iOS exactly (`isEphemeralCallSignal`). The split is about
     * whether a signal is still meaningful after a delay:
     *
     *  - **Queued** (OFFER, HANGUP, GROUP_RING) must survive an offline device,
     *    or a call could never wake a sleeping phone, and a hangup could be lost
     *    leaving the far side ringing forever.
     *  - **Ephemeral** (ANSWER, ICE, RINGING, BUSY, GROUP_JOIN, GROUP_LEAVE) is
     *    worthless once stale — a late ICE candidate or a RINGING for a call that
     *    ended would only confuse the recipient, and queuing them would replay a
     *    dead call's signalling on next connect.
     */
    fun isEphemeral(type: CallMessage.Type): Boolean = when (type) {
        CallMessage.Type.ANSWER,
        CallMessage.Type.ICE,
        CallMessage.Type.BUSY,
        CallMessage.Type.RINGING,
        CallMessage.Type.GROUP_JOIN,
        CallMessage.Type.GROUP_LEAVE,
        -> true

        CallMessage.Type.OFFER,
        CallMessage.Type.HANGUP,
        CallMessage.Type.GROUP_RING,
        -> false

        // An unrecognised type from a newer client: treat as durable. Queuing
        // something that turns out to be ephemeral is recoverable; dropping
        // something that was meant to survive is not.
        else -> false
    }

    fun offer(callId: String, sdp: String, ownAccount: String, ownDevice: Int): Content =
        content {
            call = callMessage {
                // OFFER is 0, so proto3 elides the field. Set it anyway for
                // clarity; receivers must default to OFFER when `type` is absent.
                type = CallMessage.Type.OFFER
                this.callId = callId
                this.sdp = sdp
            }
            senderAccountId = ownAccount
            senderDeviceId = ownDevice
        }

    fun answer(callId: String, sdp: String, ownAccount: String, ownDevice: Int): Content =
        content {
            call = callMessage {
                type = CallMessage.Type.ANSWER
                this.callId = callId
                this.sdp = sdp
            }
            senderAccountId = ownAccount
            senderDeviceId = ownDevice
        }

    /** One ICE candidate, as the JSON encoding of an RTCIceCandidate. */
    fun ice(callId: String, candidateJson: String, ownAccount: String, ownDevice: Int): Content =
        content {
            call = callMessage {
                type = CallMessage.Type.ICE
                this.callId = callId
                ice = candidateJson
            }
            senderAccountId = ownAccount
            senderDeviceId = ownDevice
        }

    fun simple(
        type: CallMessage.Type,
        callId: String,
        ownAccount: String,
        ownDevice: Int,
    ): Content = content {
        call = callMessage {
            this.type = type
            this.callId = callId
        }
        senderAccountId = ownAccount
        senderDeviceId = ownDevice
    }

    fun ringing(callId: String, ownAccount: String, ownDevice: Int): Content =
        simple(CallMessage.Type.RINGING, callId, ownAccount, ownDevice)

    fun busy(callId: String, ownAccount: String, ownDevice: Int): Content =
        simple(CallMessage.Type.BUSY, callId, ownAccount, ownDevice)

    fun hangup(callId: String, ownAccount: String, ownDevice: Int): Content =
        simple(CallMessage.Type.HANGUP, callId, ownAccount, ownDevice)

    /** Reads a decrypted `Content` as a call signal, or null if it isn't one. */
    fun parse(content: Content, fromAccount: String): CallSignal? {
        if (content.bodyCase != Content.BodyCase.CALL) return null
        val call = content.call
        return CallSignal(
            type = call.type,
            callId = call.callId,
            sdp = call.sdp,
            ice = call.ice,
            fromAccount = fromAccount,
            groupId = call.groupId,
            targetAccount = call.targetAccount,
            participants = call.participantsList.toList(),
        )
    }
}
