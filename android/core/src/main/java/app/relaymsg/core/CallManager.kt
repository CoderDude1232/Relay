package app.relaymsg.core

import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import relay.content.ContentOuterClass.CallMessage
import relay.content.ContentOuterClass.Content

/** Where a call is in its lifecycle. */
enum class CallState { IDLE, OUTGOING_RINGING, INCOMING_RINGING, CONNECTING, ACTIVE, ENDED }

/** Why a call finished — drives what gets written to the call log. */
enum class CallEndReason { HUNG_UP, DECLINED, BUSY, MISSED, FAILED }

data class ActiveCall(
    val callId: String,
    val peerAccount: String,
    val isOutgoing: Boolean,
    val isVideo: Boolean,
    val state: CallState,
    val startedAt: Long,
    val connectedAt: Long? = null,
)

/**
 * The media transport, abstracted so the call state machine can be tested
 * without WebRTC — the signalling is what has to interoperate with iOS, and it
 * is pure logic.
 */
interface CallTransport {
    /** Creates a local offer; the SDP is returned for signalling. */
    suspend fun createOffer(isVideo: Boolean): String

    /** Applies a remote offer and produces the answer SDP. */
    suspend fun createAnswer(remoteSdp: String, isVideo: Boolean): String

    /** Applies the remote answer to an offer we made. */
    suspend fun acceptAnswer(remoteSdp: String)

    /** Adds a remote ICE candidate (JSON-encoded RTCIceCandidate). */
    suspend fun addIceCandidate(candidateJson: String)

    /** Tears the peer connection down and releases audio/video devices. */
    fun close()
}

/**
 * Drives one call at a time: state, signalling, and the call log.
 *
 * Deliberately transport-agnostic. Everything that has to match iOS —
 * which signals are sent, in what order, which are ephemeral, and how a
 * glare/busy collision resolves — lives here and is unit-testable.
 */
class CallManager(
    private val ownAccount: String,
    private val ownDevice: Int,
    private val transport: CallTransport,
    /** Sends a signalling Content to a peer; `ephemeral` follows [CallSignalling.isEphemeral]. */
    private val send: suspend (peer: String, content: Content, ephemeral: Boolean) -> Unit,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val _call = MutableStateFlow<ActiveCall?>(null)
    val call: StateFlow<ActiveCall?> = _call.asStateFlow()

    /**
     * ICE candidates that arrived before the remote description was set.
     *
     * Unavoidable rather than defensive: the far side starts trickling
     * candidates the moment it creates its answer, and those can overtake the
     * ANSWER itself — ICE is ephemeral, the answer is too, and neither ordering
     * is guaranteed. Applying a candidate with no remote description throws.
     */
    private val pendingCandidates = mutableListOf<String>()

    suspend fun placeCall(peer: String, isVideo: Boolean): String? {
        if (_call.value != null) return null // already on a call
        val callId = UUID.randomUUID().toString()
        _call.value = ActiveCall(callId, peer, true, isVideo, CallState.OUTGOING_RINGING, now())

        return try {
            val sdp = transport.createOffer(isVideo)
            // OFFER is durable: it must survive the callee being offline, or a
            // call could never wake a sleeping phone.
            emit(peer, CallSignalling.offer(callId, sdp, ownAccount, ownDevice))
            callId
        } catch (_: Throwable) {
            end(CallEndReason.FAILED)
            null
        }
    }

    /** Handles an incoming signal. Returns the reason a call ended, if it did. */
    suspend fun onSignal(signal: CallSignal): CallEndReason? {
        val current = _call.value
        return when (signal.type) {
            CallMessage.Type.OFFER -> {
                if (current != null && current.callId != signal.callId) {
                    // Already busy: tell them rather than leaving them ringing.
                    emit(signal.fromAccount, CallSignalling.busy(signal.callId, ownAccount, ownDevice))
                    return null
                }
                _call.value = ActiveCall(
                    signal.callId, signal.fromAccount, false,
                    isVideo = signal.sdp.contains("m=video"),
                    state = CallState.INCOMING_RINGING, startedAt = now(),
                )
                pendingOffer = signal.sdp
                emit(signal.fromAccount, CallSignalling.ringing(signal.callId, ownAccount, ownDevice))
                null
            }

            CallMessage.Type.ANSWER -> {
                if (current == null || current.callId != signal.callId) return null
                runCatching {
                    transport.acceptAnswer(signal.sdp)
                    flushPendingCandidates()
                }.onFailure { return end(CallEndReason.FAILED) }
                _call.value = current.copy(state = CallState.ACTIVE, connectedAt = now())
                null
            }

            CallMessage.Type.ICE -> {
                if (current == null || current.callId != signal.callId) return null
                if (current.state == CallState.ACTIVE || current.state == CallState.CONNECTING) {
                    runCatching { transport.addIceCandidate(signal.ice) }
                } else {
                    pendingCandidates += signal.ice
                }
                null
            }

            CallMessage.Type.RINGING -> {
                if (current?.callId == signal.callId) {
                    _call.value = current.copy(state = CallState.OUTGOING_RINGING)
                }
                null
            }

            CallMessage.Type.BUSY -> {
                if (current?.callId != signal.callId) return null
                end(CallEndReason.BUSY)
            }

            CallMessage.Type.HANGUP -> {
                if (current?.callId != signal.callId) return null
                // Whether this counts as missed or hung-up depends on whether we
                // ever connected — that distinction is what the call log shows.
                val reason = if (current.state == CallState.INCOMING_RINGING) {
                    CallEndReason.MISSED
                } else {
                    CallEndReason.HUNG_UP
                }
                end(reason)
            }

            else -> null
        }
    }

    private var pendingOffer: String? = null

    /** Answers the incoming call. */
    suspend fun accept(): Boolean {
        val current = _call.value ?: return false
        val offer = pendingOffer ?: return false
        if (current.state != CallState.INCOMING_RINGING) return false

        _call.value = current.copy(state = CallState.CONNECTING)
        return try {
            val sdp = transport.createAnswer(offer, current.isVideo)
            emit(current.peerAccount, CallSignalling.answer(current.callId, sdp, ownAccount, ownDevice))
            flushPendingCandidates()
            _call.value = _call.value?.copy(state = CallState.ACTIVE, connectedAt = now())
            true
        } catch (_: Throwable) {
            end(CallEndReason.FAILED)
            false
        }
    }

    /** Declines an incoming call, or hangs up an active one. */
    suspend fun hangUp(): CallEndReason? {
        val current = _call.value ?: return null
        emit(current.peerAccount, CallSignalling.hangup(current.callId, ownAccount, ownDevice))
        return end(if (current.state == CallState.INCOMING_RINGING) CallEndReason.DECLINED else CallEndReason.HUNG_UP)
    }

    /** Sends a locally-gathered ICE candidate to the peer. */
    suspend fun sendLocalCandidate(candidateJson: String) {
        val current = _call.value ?: return
        emit(current.peerAccount, CallSignalling.ice(current.callId, candidateJson, ownAccount, ownDevice))
    }

    private suspend fun flushPendingCandidates() {
        val queued = pendingCandidates.toList()
        pendingCandidates.clear()
        queued.forEach { runCatching { transport.addIceCandidate(it) } }
    }

    private fun end(reason: CallEndReason): CallEndReason {
        transport.close()
        pendingCandidates.clear()
        pendingOffer = null
        _call.value = _call.value?.copy(state = CallState.ENDED)
        _call.value = null
        return reason
    }

    /** Sends with the ephemerality the protocol requires for that signal type. */
    private suspend fun emit(peer: String, content: Content) {
        send(peer, content, CallSignalling.isEphemeral(content.call.type))
    }
}
