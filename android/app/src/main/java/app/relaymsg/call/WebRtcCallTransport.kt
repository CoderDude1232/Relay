package app.relaymsg.call

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import app.relaymsg.core.AudioRoute
import app.relaymsg.core.AudioRouteKind
import app.relaymsg.core.CallTransport
import app.relaymsg.core.MediaConnectionState
import app.relaymsg.core.IceCandidateJson
import app.relaymsg.core.IcePlan
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.VideoTrack

/**
 * The real media transport: one WebRTC `PeerConnection` per call.
 *
 * Everything about *what* is signalled lives in `CallManager`; this only turns
 * those calls into SDP and ICE. The split is why the interop-critical half is
 * JVM-testable and this half is not tested at all — it needs a device with a
 * microphone.
 *
 * ICE configuration comes from [icePlan] on every call rather than being cached
 * here: TURN credentials are short-lived, and Private Call Mode can change
 * between calls.
 */
class WebRtcCallTransport(
    private val context: Context,
    private val icePlan: suspend () -> IcePlan,
    /** A locally gathered candidate, already encoded for the wire. */
    private val onLocalCandidate: (String) -> Unit,
    /** The peer's video track, once it arrives. Null when the call ends. */
    private val onRemoteVideo: (VideoTrack?) -> Unit = {},
    /** This device's camera track, for the self-preview. Null when the call ends. */
    private val onLocalVideo: (VideoTrack?) -> Unit = {},
    /** True while the front camera is selected, so the preview mirrors correctly. */
    private val onCameraFacing: (Boolean) -> Unit = {},
    /**
     * Capture shared with the other legs of a group call.
     *
     * When null this transport owns its own capture and disposes it on close;
     * when supplied it borrows and leaves disposal to the owner. Group calls must
     * share, because Camera2 only lets a process open a camera once.
     */
    private val sharedMedia: WebRtc.LocalMedia? = null,
    /** Fired when the system revokes the projection from its own UI. */
    private val onScreenShareStopped: () -> Unit = {},
    /** iOS labels group legs `grp` and 1:1 streams `stream0`. Cosmetic, matched anyway. */
    private val streamId: String = STREAM_ID,
) : CallTransport {

    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var connection: PeerConnection? = null

    /** Capture this transport opened itself, and must therefore dispose. */
    private var ownedMedia: WebRtc.LocalMedia? = null

    /** Whichever capture is in use, owned or borrowed. */
    private val media: WebRtc.LocalMedia? get() = sharedMedia ?: ownedMedia

    private var previousAudioMode: Int? = null
    private var connectionListener: ((MediaConnectionState) -> Unit)? = null

    /**
     * Candidates that arrived between `accept()` and the remote description
     * being applied.
     *
     * `CallManager` already queues candidates while a call is ringing, but it
     * releases them the moment it enters CONNECTING — which is *before* the
     * answer has been created. `addIceCandidate` with no remote description
     * fails, so the last few metres are covered here.
     */
    private val pendingRemote = mutableListOf<IceCandidate>()
    private var hasRemoteDescription = false

    override suspend fun createOffer(isVideo: Boolean): String {
        val pc = open(isVideo)
        val offer = pc.createOfferAwait(constraints(isVideo))
        pc.setLocalDescriptionAwait(offer)
        return offer.description
    }

    override suspend fun createAnswer(remoteSdp: String, isVideo: Boolean): String {
        val pc = open(isVideo)
        pc.setRemoteDescriptionAwait(SessionDescription(SessionDescription.Type.OFFER, remoteSdp))
        markRemoteReady(pc)
        val answer = pc.createAnswerAwait(constraints(isVideo))
        pc.setLocalDescriptionAwait(answer)
        return answer.description
    }

    override suspend fun acceptAnswer(remoteSdp: String) {
        val pc = connection ?: throw IOException("no peer connection")
        pc.setRemoteDescriptionAwait(SessionDescription(SessionDescription.Type.ANSWER, remoteSdp))
        markRemoteReady(pc)
    }

    override suspend fun addIceCandidate(candidateJson: String) {
        // A candidate we cannot read is dropped, not guessed at: ICE is
        // redundant by design and one lost candidate rarely costs the call.
        val parsed = IceCandidateJson.decode(candidateJson) ?: return
        val candidate = IceCandidate(parsed.sdpMid, parsed.sdpMLineIndex, parsed.sdp)
        val pc = connection ?: return
        if (hasRemoteDescription) pc.addIceCandidate(candidate) else pendingRemote += candidate
    }

    override fun onConnectionState(listener: (MediaConnectionState) -> Unit) {
        connectionListener = listener
    }

    override fun setMicrophoneEnabled(enabled: Boolean) {
        media?.setMicrophoneEnabled(enabled)
    }

    /**
     * The outputs available right now.
     *
     * Labelled by kind rather than by the device's own product name: the name
     * would be the peer's... no, the *user's* hardware, but reading it on API 31+
     * drags in Bluetooth permissions for no benefit, and "Headphones" is what a
     * picker needs to say anyway.
     */
    override fun audioRoutes(): List<AudioRoute> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            // Pre-31 there is no device list: `startBluetoothSco` is the only
            // route to a headset and it is unreliable enough that offering it
            // would promise more than it delivers.
            return listOf(
                AudioRoute(LEGACY_EARPIECE, AudioRouteKind.EARPIECE, "Phone"),
                AudioRoute(LEGACY_SPEAKER, AudioRouteKind.SPEAKER, "Speaker"),
            )
        }
        return audioManager.availableCommunicationDevices
            .mapNotNull { device ->
                kindOf(device.type)?.let { kind -> AudioRoute(device.id, kind, label(kind)) }
            }
            .distinctBy { it.kind }
    }

    override fun selectAudioRoute(route: AudioRoute) {
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val device = audioManager.availableCommunicationDevices
                    .firstOrNull { it.id == route.id }
                // The headset may have been unplugged between listing and
                // choosing; leaving routing alone beats forcing it nowhere.
                if (device != null) audioManager.setCommunicationDevice(device)
            } else {
                @Suppress("DEPRECATION")
                audioManager.isSpeakerphoneOn = route.kind == AudioRouteKind.SPEAKER
            }
        }.onFailure { Log.w(TAG, "could not switch audio route", it) }
    }

    override fun switchCamera() {
        media?.switchCamera(onCameraFacing)
    }

    override fun startScreenShare(permission: Any): Boolean {
        val intent = permission as? android.content.Intent ?: return false
        return media?.startScreenCapture(context, intent, onScreenShareStopped) ?: false
    }

    override fun stopScreenShare() {
        media?.stopScreenCapture(context)
    }

    override fun setCameraEnabled(enabled: Boolean) {
        // Track-level, like mute: the peer sees a frozen frame, and there is
        // nothing to renegotiate. Stopping the capturer would also drop the
        // track, which needs a new offer to bring back.
        media?.setCameraEnabled(enabled)
    }

    override fun close() {
        onRemoteVideo(null)
        connection?.dispose()
        connection = null
        // Only capture this transport opened. A group leg closing must not take
        // the camera away from the others.
        ownedMedia?.let {
            onLocalVideo(null)
            it.close()
        }
        ownedMedia = null
        pendingRemote.clear()
        hasRemoteDescription = false
        restoreAudio()
    }

    // ------------------------------------------------------------------- setup

    private suspend fun open(isVideo: Boolean): PeerConnection {
        connection?.let { return it }

        // Without the microphone the call would connect and carry silence, which
        // is worse than failing: the user would blame the other end.
        if (!granted(Manifest.permission.RECORD_AUDIO)) {
            throw SecurityException("microphone permission not granted")
        }

        val plan = icePlan()
        if (plan.servers.isEmpty()) {
            // Not fatal — host candidates still connect on the same network — but
            // it is the usual explanation for a call that rings and never joins.
            Log.w(TAG, "no ICE servers; relying on host candidates only")
        }

        val pc = WebRtc.factory(context)
            .createPeerConnection(configuration(plan), observer())
            ?: throw IOException("could not create peer connection")
        connection = pc

        configureAudio()
        attachLocalMedia(pc, isVideo)
        return pc
    }

    private fun attachLocalMedia(pc: PeerConnection, isVideo: Boolean) {
        val wantsCamera = isVideo && granted(Manifest.permission.CAMERA)
        if (isVideo && !wantsCamera) {
            // Downgrade rather than failing the call: the remote side offered
            // video, but an audio-only answer is a valid reply to that.
            Log.w(TAG, "camera permission not granted; continuing audio-only")
        }
        val local = sharedMedia
            ?: WebRtc.openLocalMedia(context, wantsCamera, onCameraFacing).also { ownedMedia = it }

        pc.addTrack(local.audioTrack, listOf(streamId))
        local.videoTrack?.let { pc.addTrack(it, listOf(streamId)) }
        if (ownedMedia != null) onLocalVideo(local.videoTrack)
    }

    private fun configuration(plan: IcePlan): PeerConnection.RTCConfiguration {
        val servers = plan.servers.map { spec ->
            PeerConnection.IceServer.builder(spec.urls)
                .setUsername(spec.username.orEmpty())
                .setPassword(spec.credential.orEmpty())
                .createIceServer()
        }
        return PeerConnection.RTCConfiguration(servers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy =
                PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
            // Pre-gathers a few candidates so the offer is not the first thing
            // waiting on the network. Same value as iOS.
            iceCandidatePoolSize = 4
            if (plan.forceRelay) {
                // Private Call Mode: only relayed candidates, so the peer never
                // sees this device's address.
                iceTransportsType = PeerConnection.IceTransportsType.RELAY
            }
        }
    }

    private fun markRemoteReady(pc: PeerConnection) {
        hasRemoteDescription = true
        val queued = pendingRemote.toList()
        pendingRemote.clear()
        queued.forEach { runCatching { pc.addIceCandidate(it) } }
    }

    private fun granted(permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    // ------------------------------------------------------------------- audio

    /**
     * Puts the device into call audio.
     *
     * `MODE_IN_COMMUNICATION` is what routes to the earpiece, enables the
     * hardware echo canceller and puts the volume keys on the call stream. The
     * previous mode is remembered because this process does not own it.
     */
    private fun configureAudio() {
        previousAudioMode = audioManager.mode
        runCatching {
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = false
        }.onFailure { Log.w(TAG, "could not configure call audio", it) }
    }

    private fun restoreAudio() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            runCatching { audioManager.clearCommunicationDevice() }
        }
        previousAudioMode?.let { mode -> runCatching { audioManager.mode = mode } }
        previousAudioMode = null
    }

    // --------------------------------------------------------------- observers

    private fun observer() = object : PeerConnection.Observer {
        override fun onIceCandidate(candidate: IceCandidate) {
            onLocalCandidate(
                IceCandidateJson.encode(candidate.sdp, candidate.sdpMid, candidate.sdpMLineIndex),
            )
        }

        override fun onTrack(transceiver: org.webrtc.RtpTransceiver) {
            (transceiver.receiver?.track() as? VideoTrack)?.let(onRemoteVideo)
        }

        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) {
            Log.i(TAG, "ice connection: $state")
            connectionListener?.invoke(
                when (state) {
                    PeerConnection.IceConnectionState.CONNECTED,
                    PeerConnection.IceConnectionState.COMPLETED,
                    -> MediaConnectionState.CONNECTED

                    PeerConnection.IceConnectionState.DISCONNECTED ->
                        MediaConnectionState.DISCONNECTED

                    PeerConnection.IceConnectionState.FAILED -> MediaConnectionState.FAILED
                    PeerConnection.IceConnectionState.CLOSED -> MediaConnectionState.CLOSED
                    else -> MediaConnectionState.CONNECTING
                },
            )
        }

        // The rest are required by the interface and carry nothing we act on.
        override fun onSignalingChange(state: PeerConnection.SignalingState) = Unit
        override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) = Unit
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) = Unit
        override fun onAddStream(stream: MediaStream?) = Unit
        override fun onRemoveStream(stream: MediaStream?) = Unit
        override fun onDataChannel(channel: DataChannel?) = Unit
        override fun onRenegotiationNeeded() = Unit
        override fun onAddTrack(receiver: RtpReceiver?, streams: Array<out MediaStream>?) = Unit
    }

    private fun kindOf(type: Int): AudioRouteKind? = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> AudioRouteKind.EARPIECE
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> AudioRouteKind.SPEAKER
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        -> AudioRouteKind.WIRED
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET ->
            AudioRouteKind.BLUETOOTH
        // Anything else (HDMI, an aux line, a hearing aid we cannot classify) is
        // left out rather than offered under a label that might be wrong.
        else -> null
    }

    private fun label(kind: AudioRouteKind) = when (kind) {
        AudioRouteKind.EARPIECE -> "Phone"
        AudioRouteKind.SPEAKER -> "Speaker"
        AudioRouteKind.WIRED -> "Headset"
        AudioRouteKind.BLUETOOTH -> "Bluetooth"
    }

    private fun constraints(isVideo: Boolean) = MediaConstraints().apply {
        mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
        mandatory.add(
            MediaConstraints.KeyValuePair("OfferToReceiveVideo", if (isVideo) "true" else "false"),
        )
    }

    internal companion object {
        const val TAG = "RelayCall"

        /** iOS's stream ids: `stream0` for a 1:1 call, `grp` for a mesh leg. */
        const val STREAM_ID = "stream0"
        const val GROUP_STREAM_ID = "grp"

        // Pre-31 there is no device id to use, only a boolean.
        const val LEGACY_EARPIECE = 0
        const val LEGACY_SPEAKER = 1

    }
}

// ------------------------------------------------- SdpObserver as a suspend fn

/**
 * WebRTC's SDP API is callback-based and split across two callbacks on one
 * interface, so each wrapper implements all four methods and ignores the pair it
 * did not ask for.
 */
private suspend fun PeerConnection.createOfferAwait(constraints: MediaConstraints) =
    suspendCancellableCoroutine { cont ->
        createOffer(sdpObserver(cont, "createOffer"), constraints)
    }

private suspend fun PeerConnection.createAnswerAwait(constraints: MediaConstraints) =
    suspendCancellableCoroutine { cont ->
        createAnswer(sdpObserver(cont, "createAnswer"), constraints)
    }

private suspend fun PeerConnection.setLocalDescriptionAwait(sdp: SessionDescription) =
    suspendCancellableCoroutine { cont ->
        setLocalDescription(setObserver(cont, "setLocalDescription"), sdp)
    }

private suspend fun PeerConnection.setRemoteDescriptionAwait(sdp: SessionDescription) =
    suspendCancellableCoroutine { cont ->
        setRemoteDescription(setObserver(cont, "setRemoteDescription"), sdp)
    }

private fun sdpObserver(
    cont: kotlinx.coroutines.CancellableContinuation<SessionDescription>,
    what: String,
) = object : SdpObserver {
    override fun onCreateSuccess(sdp: SessionDescription) {
        if (cont.isActive) cont.resume(sdp)
    }

    override fun onCreateFailure(error: String?) {
        if (cont.isActive) cont.resumeWithException(IOException("$what failed: $error"))
    }

    override fun onSetSuccess() = Unit
    override fun onSetFailure(error: String?) = Unit
}

private fun setObserver(
    cont: kotlinx.coroutines.CancellableContinuation<Unit>,
    what: String,
) = object : SdpObserver {
    override fun onSetSuccess() {
        if (cont.isActive) cont.resume(Unit)
    }

    override fun onSetFailure(error: String?) {
        if (cont.isActive) cont.resumeWithException(IOException("$what failed: $error"))
    }

    override fun onCreateSuccess(sdp: SessionDescription?) = Unit
    override fun onCreateFailure(error: String?) = Unit
}
