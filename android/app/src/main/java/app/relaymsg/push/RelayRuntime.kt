package app.relaymsg.push

import android.content.Context
import app.relaymsg.core.RelayService
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

    @Volatile
    private var service: RelayService? = null

    /** Registers the service the UI created, so push reuses it. */
    fun attach(service: RelayService) {
        this.service = service
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
                ?.also { service = it }
        }
    }

    fun detach() {
        service = null
    }
}
