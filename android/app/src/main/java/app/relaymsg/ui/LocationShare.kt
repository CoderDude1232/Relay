package app.relaymsg.ui

import android.annotation.SuppressLint
import android.content.Context
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Looper
import app.relaymsg.core.LocationPayload

/**
 * Shares a live location for a fixed window.
 *
 * Time-boxed by construction: `start` takes a duration and every update carries
 * the expiry, so a share that is forgotten stops on its own. There is no
 * "share indefinitely", which is the one setting people regret.
 *
 * Uses the platform LocationManager rather than Play Services' fused provider —
 * it is one fewer dependency, works on a device without Play, and a bubble on a
 * map does not need metre-accurate fusion.
 */
class LocationShare(private val context: Context) {

    private val manager =
        context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager

    private var listener: LocationListener? = null
    private var expiresAt: Long = 0
    private var conversationId: String? = null

    val isSharing: Boolean get() = listener != null

    /**
     * Begins sharing. [onUpdate] receives each position to send.
     *
     * Returns false when there is no usable provider — with location switched
     * off there is nothing to share and saying so beats a bubble that never
     * moves.
     */
    @SuppressLint("MissingPermission")
    fun start(
        conversationId: String,
        durationMs: Long,
        onUpdate: (LocationPayload) -> Unit,
    ): Boolean {
        stop(onUpdate = null)
        val manager = manager ?: return false
        val provider = when {
            manager.isProviderEnabled(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
            manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER) ->
                LocationManager.NETWORK_PROVIDER
            else -> return false
        }

        expiresAt = System.currentTimeMillis() + durationMs
        this.conversationId = conversationId

        val active = LocationListener { location ->
            if (System.currentTimeMillis() > expiresAt) {
                // Expiry is enforced here as well as in the payload: a receiver
                // that ignored `exp` should still stop getting updates.
                stop(onUpdate)
                return@LocationListener
            }
            onUpdate(location.payload(expiresAt, stop = false))
        }

        return runCatching {
            manager.requestLocationUpdates(
                provider,
                UPDATE_INTERVAL_MS,
                UPDATE_DISTANCE_M,
                active,
                Looper.getMainLooper(),
            )
            listener = active
            // Send the last known fix straight away, so the bubble appears now
            // rather than whenever the radio next reports.
            manager.getLastKnownLocation(provider)
                ?.let { onUpdate(it.payload(expiresAt, stop = false)) }
            true
        }.getOrDefault(false).also { if (!it) listener = null }
    }

    /**
     * Stops sharing, sending a final `stop` update so the other side's bubble
     * goes still immediately rather than at expiry.
     */
    @SuppressLint("MissingPermission")
    fun stop(onUpdate: ((LocationPayload) -> Unit)?) {
        val active = listener ?: return
        runCatching { manager?.removeUpdates(active) }
        listener = null

        if (onUpdate != null) {
            val last = runCatching {
                manager?.getLastKnownLocation(LocationManager.GPS_PROVIDER)
                    ?: manager?.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
            }.getOrNull()
            onUpdate(
                // A stop with no fix still has to be sent, or the bubble stays
                // live until it expires. Zeroes are fine: `stop` is what counts.
                last?.payload(expiresAt, stop = true)
                    ?: LocationPayload(0.0, 0.0, expiresAt, stop = true),
            )
        }
        conversationId = null
    }

    private fun Location.payload(expiry: Long, stop: Boolean) =
        LocationPayload(latitude, longitude, expiry, stop)

    private companion object {
        const val UPDATE_INTERVAL_MS = 15_000L

        /** Ten metres: enough to look live, sparse enough not to drain a battery. */
        const val UPDATE_DISTANCE_M = 10f
    }
}
