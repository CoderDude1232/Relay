package app.relaymsg.call

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import androidx.core.content.ContextCompat
import app.relaymsg.core.CallTransport
import app.relaymsg.core.RelayService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * Owns the capture shared by every leg of a group call.
 *
 * A mesh opens one peer connection per member, but a process can open the camera
 * **once** — so capture cannot live inside the per-peer transports the way it
 * does for a 1:1 call. It is opened when the first leg is built and released
 * when the call ends, which is also what makes mute and camera-off apply to
 * everyone at once instead of one leg at a time.
 */
object GroupCallCoordinator {

    private const val TAG = "RelayCall"

    private var media: WebRtc.LocalMedia? = null

    /** Installs the mesh transport factory and the release-on-end watcher. */
    fun install(context: Context, service: RelayService, scope: CoroutineScope) {
        val app = context.applicationContext
        service.groupCallTransportFactory = { peer -> transport(app, service, scope, peer) }

        scope.launch {
            service.groupCalls.call.collect { call ->
                // Null means the call is over, by leaving, declining, or the last
                // member going. Holding the camera open past that is the kind of
                // bug a user notices as a light that stays on.
                if (call == null) release()
            }
        }
    }

    private fun transport(
        context: Context,
        service: RelayService,
        scope: CoroutineScope,
        peer: String,
    ): CallTransport {
        val call = service.groupCalls.call.value
        val wantsVideo = call?.isVideo == true && granted(context, Manifest.permission.CAMERA)

        val local = media ?: open(context, wantsVideo)?.also { fresh ->
            media = fresh
            CallMedia.setLocalVideo(fresh.videoTrack)
        }

        return WebRtcCallTransport(
            context = context,
            icePlan = service::icePlan,
            onLocalCandidate = { json ->
                scope.launch { runCatching { service.groupCalls.sendLocalCandidate(peer, json) } }
            },
            // Per member, so the grid can show who is on camera.
            onRemoteVideo = { track -> CallMedia.setGroupVideo(peer, track) },
            // The self-preview belongs to the shared capture, not to one leg.
            onLocalVideo = {},
            onCameraFacing = CallMedia::setCameraFacing,
            sharedMedia = local,
            streamId = WebRtcCallTransport.GROUP_STREAM_ID,
        )
    }

    /**
     * Opens capture, or returns null with no microphone.
     *
     * Null makes each transport fall back to opening its own, where the existing
     * permission check fails the leg cleanly. Capturing silence here instead
     * would produce a call that looks fine and carries nothing.
     */
    private fun open(context: Context, wantsVideo: Boolean): WebRtc.LocalMedia? {
        if (!granted(context, Manifest.permission.RECORD_AUDIO)) {
            Log.w(TAG, "group call without microphone permission")
            return null
        }
        return WebRtc.openLocalMedia(context, wantsVideo, CallMedia::setCameraFacing)
    }

    private fun release() {
        media?.close()
        media = null
        CallMedia.setLocalVideo(null)
        CallMedia.clearGroupVideo()
    }

    private fun granted(context: Context, permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
}
