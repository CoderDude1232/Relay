package app.relaymsg.call

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import app.relaymsg.core.CallTransport
import app.relaymsg.core.IceCandidateJson
import app.relaymsg.core.IcePlan
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import org.webrtc.AudioTrack
import org.webrtc.CameraVideoCapturer
import org.webrtc.Camera2Enumerator
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SurfaceTextureHelper
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
) : CallTransport {

    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var connection: PeerConnection? = null
    private var audioTrack: AudioTrack? = null
    private var videoTrack: VideoTrack? = null
    private var capturer: CameraVideoCapturer? = null
    private var surfaceHelper: SurfaceTextureHelper? = null
    private var previousAudioMode: Int? = null

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

    override fun setMicrophoneEnabled(enabled: Boolean) {
        audioTrack?.setEnabled(enabled)
    }

    override fun setSpeakerphoneOn(on: Boolean) {
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val wanted = if (on) {
                    AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                } else {
                    AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
                }
                val device = audioManager.availableCommunicationDevices
                    .firstOrNull { it.type == wanted }
                // A tablet may have no earpiece at all; leaving routing alone
                // beats forcing it somewhere that does not exist.
                if (device != null) audioManager.setCommunicationDevice(device)
            } else {
                @Suppress("DEPRECATION")
                audioManager.isSpeakerphoneOn = on
            }
        }.onFailure { Log.w(TAG, "could not switch audio route", it) }
    }

    override fun close() {
        onRemoteVideo(null)
        onLocalVideo(null)
        runCatching { capturer?.stopCapture() }
        capturer?.dispose()
        surfaceHelper?.dispose()
        videoTrack?.dispose()
        audioTrack?.dispose()
        connection?.dispose()
        capturer = null
        surfaceHelper = null
        videoTrack = null
        audioTrack = null
        connection = null
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
        addAudio(pc)
        if (isVideo) addVideo(pc)
        return pc
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

    private fun addAudio(pc: PeerConnection) {
        val factory = WebRtc.factory(context)
        val source = factory.createAudioSource(MediaConstraints())
        // Track and stream ids match iOS so a capture from either side reads the
        // same; nothing depends on them protocol-wise.
        val track = factory.createAudioTrack(AUDIO_TRACK_ID, source)
        audioTrack = track
        pc.addTrack(track, listOf(STREAM_ID))
    }

    private fun addVideo(pc: PeerConnection) {
        if (!granted(Manifest.permission.CAMERA)) {
            // Downgrade to audio rather than failing the call outright: the
            // remote side negotiated video but an audio-only answer is valid.
            Log.w(TAG, "camera permission not granted; continuing audio-only")
            return
        }
        val enumerator = Camera2Enumerator(context)
        val device = enumerator.deviceNames.firstOrNull(enumerator::isFrontFacing)
            ?: enumerator.deviceNames.firstOrNull()
            ?: run {
                Log.w(TAG, "no camera available; continuing audio-only")
                return
            }

        val factory = WebRtc.factory(context)
        val source = factory.createVideoSource(false)
        val helper = SurfaceTextureHelper.create(CAPTURE_THREAD, WebRtc.eglContext())
        val camera = enumerator.createCapturer(device, null) ?: run {
            helper.dispose()
            source.dispose()
            Log.w(TAG, "could not open camera; continuing audio-only")
            return
        }

        camera.initialize(helper, context, source.capturerObserver)
        camera.startCapture(VIDEO_WIDTH, VIDEO_HEIGHT, VIDEO_FPS)

        val track = factory.createVideoTrack(VIDEO_TRACK_ID, source)
        capturer = camera
        surfaceHelper = helper
        videoTrack = track
        pc.addTrack(track, listOf(STREAM_ID))
        onLocalVideo(track)
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

    private fun constraints(isVideo: Boolean) = MediaConstraints().apply {
        mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
        mandatory.add(
            MediaConstraints.KeyValuePair("OfferToReceiveVideo", if (isVideo) "true" else "false"),
        )
    }

    private companion object {
        const val TAG = "RelayCall"

        // Matching iOS's ids, purely so a capture from either client reads alike.
        const val AUDIO_TRACK_ID = "audio0"
        const val VIDEO_TRACK_ID = "video0"
        const val STREAM_ID = "stream0"
        const val CAPTURE_THREAD = "RelayCapture"

        const val VIDEO_WIDTH = 1280
        const val VIDEO_HEIGHT = 720
        const val VIDEO_FPS = 30
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
