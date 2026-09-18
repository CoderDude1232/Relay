package app.relaymsg.push

import android.content.Context
import app.relaymsg.call.CallMedia
import app.relaymsg.call.GroupCallCoordinator
import app.relaymsg.call.WebRtcCallTransport
import app.relaymsg.core.RelayService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The single [RelayService] for this process.
 *
 * There must never be two: the encrypted store, the libsignal session state and
 * the WebSocket are all single-instance, and a second copy would advance the
 * Double Ratchet concurrently and corrupt sessions. The UI and the push service
 * live in the same process, so both go through here.
 *
 * iOS has the harder version of this problem — its Notification Service
 * Extension is a *separate process* — which is why envelope claiming lives in
 * the shared database rather than in memory. That claim still protects us here;
 * this is just the cheaper first line of defence.
 */
object RelayRuntime {
    private val lock = Mutex()

    /** Outlives any one call: local candidates keep arriving after connect. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    private var service: RelayService? = null

    /** Registers the service the UI created, so push reuses it. */
    fun attach(context: Context, service: RelayService) {
        install(context, service)
        this.service = service
    }

    /**
     * Gives the service its media transport.
     *
     * WebRTC lives in the app module, so `:core` ships a `NoMediaTransport` and
     * the real factory is installed here — the one place every [RelayService] in
     * this process passes through, whether it was created by the UI or restored
     * by a push.
     */
    private fun install(context: Context, service: RelayService) {
        val app = context.applicationContext
        service.callTransportFactory = {
            WebRtcCallTransport(
                context = app,
                icePlan = service::icePlan,
                // Trickle ICE: candidates are gathered continuously and each one
                // is signalled as it appears, rather than waiting for gathering
                // to finish before sending the offer.
                onLocalCandidate = { json ->
                    scope.launch { runCatching { service.calls.sendLocalCandidate(json) } }
                },
                onRemoteVideo = CallMedia::setRemoteVideo,
                onLocalVideo = CallMedia::setLocalVideo,
                onCameraFacing = CallMedia::setCameraFacing,
            )
        }
        GroupCallCoordinator.install(app, service, scope)
    }

    /**
     * The live service, restoring one from disk if the process was started by a
     * push rather than by the user opening the app. Returns null when this
     * install has no account yet.
     */
    suspend fun require(context: Context): RelayService? {
        service?.let { return it }
        return lock.withLock {
            service ?: runCatching { RelayService.restore(context.applicationContext) }
                .getOrNull()
                ?.also { restored ->
                    install(context, restored)
                    service = restored
                }
        }
    }

    fun detach() {
        service = null
    }
}
