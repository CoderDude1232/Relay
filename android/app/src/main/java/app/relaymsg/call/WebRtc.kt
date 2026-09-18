package app.relaymsg.call

import android.content.Context
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.PeerConnectionFactory
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
internal object WebRtc {

    private var egl: EglBase? = null
    private var factory: PeerConnectionFactory? = null

    @Synchronized
    fun eglContext(): EglBase.Context = requireEgl().eglBaseContext

    @Synchronized
    fun factory(context: Context): PeerConnectionFactory = factory ?: build(context).also {
        factory = it
    }

    private fun requireEgl(): EglBase = egl ?: EglBase.create().also { egl = it }

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
}
