package app.relaymsg.core

import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
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
    val isMuted: Boolean = false,
    val audioRoute: AudioRouteKind = AudioRouteKind.EARPIECE,
    val isCameraOn: Boolean = true,
)

/**
 * What the media connection is doing, as reported by ICE.
 *
 * This is the only honest answer to "is the call actually working": SDP can be
 * exchanged successfully and media still never flow.
 */
enum class MediaConnectionState { CONNECTING, CONNECTED, DISCONNECTED, FAILED, CLOSED }

/** Where call audio can go. */
enum class AudioRouteKind { EARPIECE, SPEAKER, WIRED, BLUETOOTH }

/**
 * One selectable audio output.
 *
 * [id] is the platform's own device id, opaque here — the state machine only
 * ever hands it back to the transport.
 */
data class AudioRoute(val id: Int, val kind: AudioRouteKind, val name: String)

/**
 * The media transport, abstracted so the call state machine can be tested
 * without WebRTC — the signalling is what has to interoperate with iOS, and it
 * is pure logic.
 */
interface CallTransport {

    /**
     * Registers the media-connection listener, before any offer is created.
     *
     * Called exactly once per transport; a second call replaces the first.
     */
    fun onConnectionState(listener: (MediaConnectionState) -> Unit)

    /** Creates a local offer; the SDP is returned for signalling. */
    suspend fun createOffer(isVideo: Boolean): String

    /** Applies a remote offer and produces the answer SDP. */
    suspend fun createAnswer(remoteSdp: String, isVideo: Boolean): String

    /** Applies the remote answer to an offer we made. */
    suspend fun acceptAnswer(remoteSdp: String)

    /** Adds a remote ICE candidate (JSON-encoded RTCIceCandidate). */
    suspend fun addIceCandidate(candidateJson: String)

    /**
     * Mutes or unmutes the local microphone.
     *
     * A track-level enable, not a renegotiation: the peer sees silence, not a
     * changed session, so there is nothing to signal and nothing to go wrong.
     */
    fun setMicrophoneEnabled(enabled: Boolean)

    /**
     * The outputs call audio can currently go to.
     *
     * Queried on demand rather than observed: headsets appear and disappear
     * mid-call, so the answer is only correct at the moment the user asks.
     */
    fun audioRoutes(): List<AudioRoute>

    /** Sends call audio to [route]. */
    fun selectAudioRoute(route: AudioRoute)

    /** Flips between the front and back cameras. No effect on an audio call. */
    fun switchCamera()

    /**
     * Stops or resumes sending video.
     *
     * A track-level enable, like mute: the peer sees a frozen last frame rather
     * than a renegotiated session.
     */
    fun setCameraEnabled(enabled: Boolean)

    /** Tears the peer connection down and releases audio/video devices. */
    fun close()
}

/**
 * The transport used until WebRTC is wired in (PROTOCOL.md §7.6).
 *
 * It fails loudly rather than pretending: signalling is complete and
 * interoperable, but a call placed or answered through this transport carries no
 * media, so it ends as [CallEndReason.FAILED] instead of silently connecting to
 * nothing.
 */
class NoMediaTransport : CallTransport {
    override suspend fun createOffer(isVideo: Boolean): String =
        throw UnsupportedOperationException("no media transport installed")

    override suspend fun createAnswer(remoteSdp: String, isVideo: Boolean): String =
        throw UnsupportedOperationException("no media transport installed")

    override suspend fun acceptAnswer(remoteSdp: String) = Unit
    override suspend fun addIceCandidate(candidateJson: String) = Unit
    override fun onConnectionState(listener: (MediaConnectionState) -> Unit) = Unit
    override fun setMicrophoneEnabled(enabled: Boolean) = Unit
    override fun audioRoutes(): List<AudioRoute> = emptyList()
    override fun selectAudioRoute(route: AudioRoute) = Unit
    override fun switchCamera() = Unit
    override fun setCameraEnabled(enabled: Boolean) = Unit
    override fun close() = Unit
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
    /**
     * Creates the media transport for one call.
     *
     * A factory rather than a single instance for two reasons: a WebRTC
     * `PeerConnection` is per-call and cannot be reused once closed, and the real
     * implementation lives in the app module (WebRTC is a large native
     * dependency) while this state machine has to stay JVM-testable.
     */
    private val newTransport: () -> CallTransport,
    /** Sends a signalling Content to a peer; `ephemeral` follows [CallSignalling.isEphemeral]. */
    private val send: suspend (peer: String, content: Content, ephemeral: Boolean) -> Unit,
    /** Where the ICE grace-period timers run. Outlives any one call. */
    private val scope: CoroutineScope,
    /** Called once per finished call, for the call log. */
    private val onEnded: (ActiveCall, CallEndReason) -> Unit = { _, _ -> },
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

    /** The transport for the call in progress; null whenever [call] is null. */
    private var transport: CallTransport? = null

    /** The pending "give up on this call" timer, if ICE is currently unhappy. */
    private var recovery: Job? = null

    private fun openTransport(): CallTransport = newTransport().also { fresh ->
        fresh.onConnectionState(::onMediaState)
        transport = fresh
    }

    /**
     * Reacts to the media connection coming up, wobbling, or dying.
     *
     * The grace periods are iOS's (`scheduleIceFailure`): 3 s on `failed`, 10 s
     * on `disconnected`. They exist because WebRTC recovers from both on its own
     * surprisingly often — continual gathering keeps trying new pairs — and
     * ending a call that was about to come back is worse than a few seconds of
     * silence.
     *
     * Note there is no ICE *restart* here, deliberately: a restart means sending
     * a fresh OFFER mid-call, and iOS answers an OFFER for a call it already has
     * with BUSY. See PROTOCOL.md §7.5.5.
     */
    private fun onMediaState(state: MediaConnectionState) {
        when (state) {
            MediaConnectionState.CONNECTED -> {
                recovery?.cancel()
                recovery = null
                markActive()
            }
            // Both sides stay in CONNECTING until media actually flows, so the
            // UI never claims a call is live while ICE is still negotiating.
            MediaConnectionState.FAILED -> scheduleFailure(FAILED_GRACE_MS)
            MediaConnectionState.DISCONNECTED -> scheduleFailure(DISCONNECTED_GRACE_MS)
            MediaConnectionState.CONNECTING, MediaConnectionState.CLOSED -> Unit
        }
    }

    private fun markActive() {
        val current = _call.value ?: return
        if (current.state == CallState.ACTIVE) return
        _call.value = current.copy(state = CallState.ACTIVE, connectedAt = current.connectedAt ?: now())
    }

    private fun scheduleFailure(delayMs: Long) {
        if (recovery != null) return
        recovery = scope.launch {
            delay(delayMs)
            val current = _call.value ?: return@launch
            // Tell the peer, or they sit watching a call that is already gone.
            runCatching {
                emit(current.peerAccount, CallSignalling.hangup(current.callId, ownAccount, ownDevice))
            }
            end(CallEndReason.FAILED)
        }
    }

    suspend fun placeCall(peer: String, isVideo: Boolean): String? {
        if (_call.value != null) return null // already on a call
        val callId = UUID.randomUUID().toString()
        _call.value = ActiveCall(callId, peer, true, isVideo, CallState.OUTGOING_RINGING, now())

        return try {
            val sdp = openTransport().createOffer(isVideo)
            // OFFER is durable: it must survive the callee being offline, or a
            // call could never wake a sleeping phone.
            emit(peer, CallSignalling.offer(callId, sdp, ownAccount, ownDevice, isVideo))
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
                    isVideo = CallSignalling.isVideoOffer(signal),
                    state = CallState.INCOMING_RINGING, startedAt = now(),
                )
                pendingOffer = signal.sdp
                emit(signal.fromAccount, CallSignalling.ringing(signal.callId, ownAccount, ownDevice))
                null
            }

            CallMessage.Type.ANSWER -> {
                if (current == null || current.callId != signal.callId) return null
                val media = transport ?: return end(CallEndReason.FAILED)
                runCatching {
                    media.acceptAnswer(signal.sdp)
                    flushPendingCandidates()
                }.onFailure { return end(CallEndReason.FAILED) }
                // Not ACTIVE yet: the SDP exchange succeeding says nothing about
                // whether media will flow. ICE decides that, in [onMediaState].
                _call.value = current.copy(state = CallState.CONNECTING)
                null
            }

            CallMessage.Type.ICE -> {
                if (current == null || current.callId != signal.callId) return null
                val media = transport
                if (media != null &&
                    (current.state == CallState.ACTIVE || current.state == CallState.CONNECTING)
                ) {
                    runCatching { media.addIceCandidate(signal.ice) }
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
            val sdp = openTransport().createAnswer(offer, current.isVideo)
            emit(current.peerAccount, CallSignalling.answer(current.callId, sdp, ownAccount, ownDevice))
            flushPendingCandidates()
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

    /**
     * Mutes or unmutes the microphone.
     *
     * Local only — the peer is not told, deliberately. A "they muted" indicator
     * would be a side channel about what is happening in someone's room, and iOS
     * does not send one either.
     */
    fun setMuted(muted: Boolean) {
        val current = _call.value ?: return
        transport?.setMicrophoneEnabled(!muted)
        _call.value = current.copy(isMuted = muted)
    }

    /** The outputs available right now; empty when no call is in progress. */
    fun audioRoutes(): List<AudioRoute> = transport?.audioRoutes().orEmpty()

    /** Sends call audio to [route]. */
    fun selectAudioRoute(route: AudioRoute) {
        val current = _call.value ?: return
        transport?.selectAudioRoute(route)
        _call.value = current.copy(audioRoute = route.kind)
    }

    /**
     * The big speaker button: loudspeaker, or back to wherever audio would go
     * otherwise — which is a headset if one is plugged in or paired, not the
     * earpiece. Picking the earpiece over a connected headset would be wrong.
     */
    fun setSpeakerOn(on: Boolean) {
        if (_call.value == null) return
        val routes = audioRoutes()
        val wanted = if (on) {
            routes.firstOrNull { it.kind == AudioRouteKind.SPEAKER }
        } else {
            routes.firstOrNull { it.kind == AudioRouteKind.BLUETOOTH }
                ?: routes.firstOrNull { it.kind == AudioRouteKind.WIRED }
                ?: routes.firstOrNull { it.kind == AudioRouteKind.EARPIECE }
        }
        wanted?.let(::selectAudioRoute)
    }

    /** Flips the camera. Local only — nothing is signalled. */
    fun switchCamera() {
        if (_call.value == null) return
        transport?.switchCamera()
    }

    /** Stops or resumes sending video. */
    fun setCameraEnabled(enabled: Boolean) {
        val current = _call.value ?: return
        transport?.setCameraEnabled(enabled)
        _call.value = current.copy(isCameraOn = enabled)
    }

    /** Sends a locally-gathered ICE candidate to the peer. */
    suspend fun sendLocalCandidate(candidateJson: String) {
        val current = _call.value ?: return
        emit(current.peerAccount, CallSignalling.ice(current.callId, candidateJson, ownAccount, ownDevice))
    }

    private suspend fun flushPendingCandidates() {
        val queued = pendingCandidates.toList()
        pendingCandidates.clear()
        val media = transport ?: return
        queued.forEach { runCatching { media.addIceCandidate(it) } }
    }

    private fun end(reason: CallEndReason): CallEndReason {
        recovery?.cancel()
        recovery = null
        transport?.close()
        transport = null
        pendingCandidates.clear()
        pendingOffer = null
        _call.value?.let { finished ->
            runCatching { onEnded(finished.copy(state = CallState.ENDED), reason) }
        }
        _call.value = null
        return reason
    }

    /** Sends with the ephemerality the protocol requires for that signal type. */
    private suspend fun emit(peer: String, content: Content) {
        send(peer, content, CallSignalling.isEphemeral(content.call.type))
    }

    private companion object {
        /** iOS `scheduleIceFailure` delays — keep them identical. */
        const val FAILED_GRACE_MS = 3_000L
        const val DISCONNECTED_GRACE_MS = 10_000L
    }
}
