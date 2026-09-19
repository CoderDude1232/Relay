package app.relaymsg.call

import android.content.Context
import android.util.Log
import org.webrtc.AudioTrack
import org.webrtc.Camera2Enumerator
import org.webrtc.CameraVideoCapturer
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.MediaConstraints
import org.webrtc.PeerConnectionFactory
import org.webrtc.ScreenCapturerAndroid
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoCapturer
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import org.webrtc.audio.JavaAudioDeviceModule

/**
 * The process-wide WebRTC factory.
 *
 * `PeerConnectionFactory.initialize` loads native code and must run exactly once
 * per process; a second call is undefined behaviour rather than an error you can
 * catch. The `EglBase` is shared for the same reason — hardware video codecs and
 * every renderer have to agree on one GL context.
 *
 * Peer connections are per-call and are **not** cached here. See
 * [app.relaymsg.core.CallTransport].
 */
object WebRtc {

    private var egl: EglBase? = null
    private var factory: PeerConnectionFactory? = null

    @Synchronized
    fun eglContext(): EglBase.Context = requireEgl().eglBaseContext

    @Synchronized
    fun factory(context: Context): PeerConnectionFactory = factory ?: build(context).also {
        factory = it
    }

    private fun requireEgl(): EglBase = egl ?: EglBase.create().also { egl = it }

    /**
     * The microphone and camera, opened once and shared by every peer connection
     * in a call.
     *
     * Required for group calls, not merely tidier: Camera2 lets one process open
     * a camera **once**, so a mesh where each leg opened its own capturer would
     * work for the first peer and fail for every other one. Sharing also means
     * mute and camera-off need applying in a single place.
     */
    class LocalMedia internal constructor(
        val audioTrack: AudioTrack,
        val videoTrack: VideoTrack?,
        private val camera: CameraVideoCapturer?,
        private val helper: SurfaceTextureHelper?,
        private val source: VideoSource?,
    ) {
        /** The screen capturer, while sharing. Null when the camera is live. */
        private var screen: VideoCapturer? = null

        val isScreenSharing: Boolean get() = screen != null

        /**
         * Swaps the camera for the screen, feeding the **same** video source.
         *
         * The track never changes, so there is nothing to renegotiate — which
         * matters, because iOS answers a mid-call offer with BUSY. It also means
         * screen share only works in a call that already carries video; adding
         * video to an audio call would need exactly that renegotiation.
         */
        fun startScreenCapture(
            context: Context,
            permission: android.content.Intent,
            onStopped: () -> Unit,
        ): Boolean {
            val source = source ?: return false
            val helper = helper ?: return false
            if (screen != null) return true

            val capturer = ScreenCapturerAndroid(
                permission,
                object : android.media.projection.MediaProjection.Callback() {
                    // The user can revoke the projection from the system UI at
                    // any moment; the call carries on with the camera.
                    override fun onStop() = onStopped()
                },
            )
            return runCatching {
                runCatching { camera?.stopCapture() }
                capturer.initialize(helper, context, source.capturerObserver)
                val metrics = context.resources.displayMetrics
                capturer.startCapture(metrics.widthPixels, metrics.heightPixels, SCREEN_FPS)
                screen = capturer
            }.isSuccess
        }

        /** Stops sharing and brings the camera back. */
        fun stopScreenCapture(context: Context) {
            val capturer = screen ?: return
            runCatching { capturer.stopCapture() }
            runCatching { capturer.dispose() }
            screen = null

            val source = source ?: return
            val helper = helper ?: return
            runCatching {
                camera?.initialize(helper, context, source.capturerObserver)
                camera?.startCapture(VIDEO_WIDTH, VIDEO_HEIGHT, VIDEO_FPS)
            }
        }

        fun setMicrophoneEnabled(enabled: Boolean) = audioTrack.setEnabled(enabled)

        fun setCameraEnabled(enabled: Boolean) {
            videoTrack?.setEnabled(enabled)
        }

        fun switchCamera(onDone: (isFront: Boolean) -> Unit) {
            camera?.switchCamera(object : CameraVideoCapturer.CameraSwitchHandler {
                override fun onCameraSwitchDone(isFrontCamera: Boolean) = onDone(isFrontCamera)
                override fun onCameraSwitchError(error: String?) {
                    Log.w(TAG, "camera switch failed: $error")
                }
            })
        }

        fun close() {
            runCatching { screen?.stopCapture() }
            screen?.dispose()
            screen = null
            runCatching { camera?.stopCapture() }
            camera?.dispose()
            helper?.dispose()
            videoTrack?.dispose()
            audioTrack.dispose()
        }
    }

    /**
     * Opens local capture.
     *
     * Audio is mandatory — the caller has already checked the permission, and a
     * call with no microphone is worse than no call. Video is best effort: no
     * permission, no camera, or a camera that will not open all downgrade to
     * audio, which is a perfectly valid thing to answer a video offer with.
     */
    fun openLocalMedia(
        context: Context,
        isVideo: Boolean,
        onCameraFacing: (Boolean) -> Unit,
    ): LocalMedia {
        val factory = factory(context)
        val audio = factory.createAudioTrack(
            AUDIO_TRACK_ID,
            factory.createAudioSource(MediaConstraints()),
        )
        if (!isVideo) return LocalMedia(audio, null, null, null, null)

        val enumerator = Camera2Enumerator(context)
        val device = enumerator.deviceNames.firstOrNull(enumerator::isFrontFacing)
            ?: enumerator.deviceNames.firstOrNull()
        if (device == null) {
            Log.w(TAG, "no camera available; continuing audio-only")
            return LocalMedia(audio, null, null, null, null)
        }

        val source = factory.createVideoSource(false)
        val helper = SurfaceTextureHelper.create(CAPTURE_THREAD, eglContext())
        val capturer = enumerator.createCapturer(device, null)
        if (capturer == null) {
            helper.dispose()
            source.dispose()
            Log.w(TAG, "could not open camera; continuing audio-only")
            return LocalMedia(audio, null, null, null, null)
        }

        capturer.initialize(helper, context, source.capturerObserver)
        capturer.startCapture(VIDEO_WIDTH, VIDEO_HEIGHT, VIDEO_FPS)
        onCameraFacing(enumerator.isFrontFacing(device))
        return LocalMedia(audio, factory.createVideoTrack(VIDEO_TRACK_ID, source), capturer, helper, source)
    }

    private fun build(context: Context): PeerConnectionFactory {
        val app = context.applicationContext
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(app)
                .createInitializationOptions(),
        )

        val audio = JavaAudioDeviceModule.builder(app)
            // Hardware AEC/NS where the device has it: the software path costs
            // noticeably more battery for a worse result.
            .setUseHardwareAcousticEchoCanceler(true)
            .setUseHardwareNoiseSuppressor(true)
            .createAudioDeviceModule()

        val eglContext = requireEgl().eglBaseContext
        return PeerConnectionFactory.builder()
            .setAudioDeviceModule(audio)
            .setVideoEncoderFactory(DefaultVideoEncoderFactory(eglContext, true, true))
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(eglContext))
            .createPeerConnectionFactory()
    }

    private const val TAG = "RelayCall"

    // Matching iOS's ids, purely so a capture from either client reads alike.
    private const val AUDIO_TRACK_ID = "audio0"
    private const val VIDEO_TRACK_ID = "video0"
    private const val CAPTURE_THREAD = "RelayCapture"

    private const val VIDEO_WIDTH = 1280
    private const val VIDEO_HEIGHT = 720
    private const val VIDEO_FPS = 30

    /** A shared screen is mostly still; 15 is plenty and halves the bitrate. */
    private const val SCREEN_FPS = 15
}
