package app.relaymsg.core

import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import relay.content.ContentOuterClass.CallMessage
import relay.content.ContentOuterClass.Content

/** One other member of a group call. */
data class GroupCallPeer(
    val account: String,
    val name: String,
    val media: MediaConnectionState = MediaConnectionState.CONNECTING,
)

/** A group call this device is ringing for, or in. */
data class ActiveGroupCall(
    val callId: String,
    val groupId: String,
    val groupName: String,
    val isVideo: Boolean,
    /** True until [GroupCallManager.join] or [GroupCallManager.decline]. */
    val isRinging: Boolean,
    /** Who started it; empty when that was us. */
    val callerAccount: String,
    val participants: List<String>,
    val peers: List<GroupCallPeer>,
    val startedAt: Long,
    val isMuted: Boolean = false,
    val isCameraOn: Boolean = true,
    val audioRoute: AudioRouteKind = AudioRouteKind.EARPIECE,
)

/**
 * Group calls: a **full mesh**, one peer connection per other participant.
 *
 * Kept apart from [CallManager] the way iOS keeps them apart, because almost
 * nothing is shared. There is no ringing/answering handshake per peer, no BUSY,
 * no single remote party, and the call ends when the last peer leaves rather
 * than when someone hangs up.
 *
 * The mesh is built by one rule: **whoever is already in the call offers to
 * whoever joins.** A new member sends one GROUP_JOIN, everyone already there
 * answers it with an OFFER addressed to them, and the mesh completes itself
 * without anyone needing to know who else is present.
 *
 * Signals ride the same fan-out transport as everything else, so every member
 * receives every signal; `target_account` is what makes a point-to-point leg
 * possible on top of that.
 */
class GroupCallManager(
    private val ownAccount: String,
    private val ownDevice: Int,
    /**
     * One transport per peer. They must share local capture — see
     * `WebRtc.LocalMedia` — and the peer is passed so the app can route that
     * leg's ICE candidates back to the right member.
     */
    private val newTransport: (peer: String) -> CallTransport,
    private val send: suspend (peer: String, content: Content, ephemeral: Boolean) -> Unit,
    private val nameOf: (account: String) -> String = { it },
    private val groupNameOf: (groupId: String) -> String = { it },
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val _call = MutableStateFlow<ActiveGroupCall?>(null)
    val call: StateFlow<ActiveGroupCall?> = _call.asStateFlow()

    private val transports = mutableMapOf<String, CallTransport>()

    /**
     * Candidates for a peer whose remote description is not set yet.
     *
     * Per peer, not global: the mesh legs negotiate independently and one slow
     * peer must not hold up anyone else's candidates.
     */
    private val pending = mutableMapOf<String, MutableList<String>>()

    /** Starts a group call and rings everyone. */
    suspend fun start(
        groupId: String,
        groupName: String,
        participants: List<String>,
        isVideo: Boolean,
    ): String? {
        if (_call.value != null) return null
        val callId = UUID.randomUUID().toString()
        val others = participants.filter { it != ownAccount }

        _call.value = ActiveGroupCall(
            callId = callId,
            groupId = groupId,
            groupName = groupName,
            isVideo = isVideo,
            isRinging = false,
            callerAccount = "",
            participants = others,
            peers = emptyList(),
            startedAt = now(),
        )

        // GROUP_RING is durable so a member whose phone is asleep still learns of
        // the call. Note it is NOT accompanied by a call push: iOS documents that
        // a VoIP push would drive the receiver into its 1:1 incoming state and
        // block the GROUP_RING path entirely.
        val ring = CallSignalling.groupRing(callId, groupId, others, isVideo, ownAccount, ownDevice)
        others.forEach { peer -> emit(peer, ring) }
        return callId
    }

    /** Joins a call we were rung for. */
    suspend fun join() {
        val current = _call.value ?: return
        if (!current.isRinging) return
        _call.value = current.copy(isRinging = false)

        // Sent to everyone listed plus whoever rang, minus ourselves. Each of
        // them replies with an OFFER, which is what builds our half of the mesh.
        val targets = (current.participants + current.callerAccount)
            .filter { it.isNotEmpty() && it != ownAccount }
            .distinct()
        val join = CallSignalling.groupJoin(current.callId, current.groupId, ownAccount, ownDevice)
        targets.forEach { peer -> emit(peer, join) }
    }

    /** Declines without joining. Nothing is sent: iOS's `declineGroupCall` is silent. */
    fun decline() {
        if (_call.value?.isRinging != true) return
        end()
    }

    /** Leaves, telling everyone still connected. */
    suspend fun leave() {
        val current = _call.value ?: return
        val leave = CallSignalling.groupLeave(current.callId, current.groupId, ownAccount, ownDevice)
        current.peers.forEach { peer -> emit(peer.account, leave) }
        end()
    }

    /** Handles a signal already classified by [CallSignalling.isGroupSignal]. */
    suspend fun onSignal(signal: CallSignal) {
        when (signal.type) {
            CallMessage.Type.GROUP_RING -> onRing(signal)
            CallMessage.Type.GROUP_JOIN -> onJoin(signal)
            CallMessage.Type.GROUP_LEAVE -> dropPeer(signal)
            CallMessage.Type.OFFER -> onPeerOffer(signal)
            CallMessage.Type.ANSWER -> onPeerAnswer(signal)
            CallMessage.Type.ICE -> onPeerIce(signal)
            // A member hanging up leaves the call; it does not end it for anyone
            // else, which is the main way a group call differs from a 1:1 one.
            CallMessage.Type.HANGUP, CallMessage.Type.BUSY -> dropPeer(signal)
            else -> Unit
        }
    }

    private fun onRing(signal: CallSignal) {
        // Already in a call: ignore rather than sending BUSY. A group ring is a
        // broadcast, and answering one with BUSY would end it for the caller.
        if (_call.value != null) return
        _call.value = ActiveGroupCall(
            callId = signal.callId,
            groupId = signal.groupId,
            groupName = groupNameOf(signal.groupId),
            isVideo = CallSignalling.isVideoOffer(signal),
            isRinging = true,
            callerAccount = signal.fromAccount,
            participants = signal.participants.filter { it != ownAccount },
            peers = emptyList(),
            startedAt = now(),
        )
    }

    private suspend fun onJoin(signal: CallSignal) {
        val current = _call.value ?: return
        if (current.callId != signal.callId) return
        // Ringing and not joined: someone else joining does not join us.
        if (current.isRinging) return
        if (current.peers.any { it.account == signal.fromAccount }) return

        addPeer(signal.fromAccount)
        offerTo(signal.fromAccount, current)
    }

    private suspend fun onPeerOffer(signal: CallSignal) {
        val current = _call.value ?: return
        if (current.callId != signal.callId) return
        // Every member sees every signal; only the addressee answers.
        if (signal.targetAccount != ownAccount) return
        if (current.isRinging) return

        addPeer(signal.fromAccount)
        val transport = openTransport(signal.fromAccount)
        val answer = runCatching { transport.createAnswer(signal.sdp, current.isVideo) }
            .getOrElse {
                closePeer(signal.fromAccount)
                return
            }
        flushPending(signal.fromAccount, transport)
        emit(
            signal.fromAccount,
            CallSignalling.groupAnswer(
                current.callId, current.groupId, answer, signal.fromAccount, ownAccount, ownDevice,
            ),
        )
    }

    private suspend fun onPeerAnswer(signal: CallSignal) {
        val current = _call.value ?: return
        if (current.callId != signal.callId) return
        val transport = transports[signal.fromAccount] ?: return
        runCatching { transport.acceptAnswer(signal.sdp) }
            .onFailure { closePeer(signal.fromAccount); return }
        flushPending(signal.fromAccount, transport)
    }

    private suspend fun onPeerIce(signal: CallSignal) {
        val current = _call.value ?: return
        if (current.callId != signal.callId) return
        val transport = transports[signal.fromAccount]
        if (transport == null) {
            // The candidate beat the offer that creates the leg. Hold it.
            pending.getOrPut(signal.fromAccount) { mutableListOf() } += signal.ice
            return
        }
        runCatching { transport.addIceCandidate(signal.ice) }
    }

    private fun dropPeer(signal: CallSignal) {
        val current = _call.value ?: return
        if (current.callId != signal.callId) return
        closePeer(signal.fromAccount)
        // The last peer leaving ends the call: sitting alone in an empty call is
        // not a state worth offering.
        if (_call.value?.peers.isNullOrEmpty()) end()
    }

    // ------------------------------------------------------------- mesh legs

    private suspend fun offerTo(peer: String, current: ActiveGroupCall) {
        val transport = openTransport(peer)
        val sdp = runCatching { transport.createOffer(current.isVideo) }
            .getOrElse {
                closePeer(peer)
                return
            }
        flushPending(peer, transport)
        emit(
            peer,
            CallSignalling.groupOffer(
                current.callId, current.groupId, sdp, peer, ownAccount, ownDevice,
            ),
        )
    }

    private fun openTransport(peer: String): CallTransport =
        transports.getOrPut(peer) {
            newTransport(peer).also { fresh ->
                fresh.onConnectionState { state -> onPeerMedia(peer, state) }
            }
        }

    private suspend fun flushPending(peer: String, transport: CallTransport) {
        val queued = pending.remove(peer) ?: return
        queued.forEach { candidate -> runCatching { transport.addIceCandidate(candidate) } }
    }

    private fun onPeerMedia(peer: String, state: MediaConnectionState) {
        if (state == MediaConnectionState.FAILED || state == MediaConnectionState.CLOSED) {
            // One leg dying is not the call dying. Drop that member and carry on;
            // there is no grace period because the others are unaffected and the
            // peer can rejoin with a fresh GROUP_JOIN.
            closePeer(peer)
            if (_call.value?.peers.isNullOrEmpty()) end()
            return
        }
        updatePeers { peers -> peers.map { if (it.account == peer) it.copy(media = state) else it } }
    }

    private fun addPeer(account: String) {
        updatePeers { peers ->
            if (peers.any { it.account == account }) peers
            else peers + GroupCallPeer(account, nameOf(account))
        }
    }

    private fun closePeer(account: String) {
        transports.remove(account)?.close()
        pending.remove(account)
        updatePeers { peers -> peers.filterNot { it.account == account } }
    }

    private fun updatePeers(transform: (List<GroupCallPeer>) -> List<GroupCallPeer>) {
        _call.value = _call.value?.let { it.copy(peers = transform(it.peers)) }
    }

    // ------------------------------------------------------------- local media

    /** Mute applies to every leg at once — they share one microphone track. */
    fun setMuted(muted: Boolean) {
        val current = _call.value ?: return
        transports.values.forEach { it.setMicrophoneEnabled(!muted) }
        _call.value = current.copy(isMuted = muted)
    }

    fun setCameraEnabled(enabled: Boolean) {
        val current = _call.value ?: return
        transports.values.forEach { it.setCameraEnabled(enabled) }
        _call.value = current.copy(isCameraOn = enabled)
    }

    fun switchCamera() {
        // One capturer behind all the legs, so one switch is enough — and doing
        // it per transport would fight over the camera.
        transports.values.firstOrNull()?.switchCamera()
    }

    fun audioRoutes(): List<AudioRoute> = transports.values.firstOrNull()?.audioRoutes().orEmpty()

    fun selectAudioRoute(route: AudioRoute) {
        val current = _call.value ?: return
        transports.values.firstOrNull()?.selectAudioRoute(route)
        _call.value = current.copy(audioRoute = route.kind)
    }

    /** Sends a local candidate to one peer. */
    suspend fun sendLocalCandidate(peer: String, candidateJson: String) {
        val current = _call.value ?: return
        emit(
            peer,
            CallSignalling.groupIce(
                current.callId, current.groupId, candidateJson, peer, ownAccount, ownDevice,
            ),
        )
    }

    private fun end() {
        transports.values.forEach { runCatching { it.close() } }
        transports.clear()
        pending.clear()
        _call.value = null
    }

    private suspend fun emit(peer: String, content: Content) {
        runCatching { send(peer, content, CallSignalling.isEphemeral(content.call.type)) }
    }
}
