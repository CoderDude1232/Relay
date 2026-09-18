package app.relaymsg.call

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import app.relaymsg.core.CallState
import app.relaymsg.core.RelayService
import app.relaymsg.push.RelayRuntime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Keeps the process alive and ringing for one incoming call.
 *
 * This is the Android half of the call-wake path. The relay's FCM message is
 * **high priority and data-only**, which is what buys a Doze exemption and a
 * short window to run — see PROTOCOL.md §7.5.1. That window is only long enough
 * to start this service; everything after it (fetching the OFFER, answering,
 * trickling ICE) happens here, under a foreground service so the system does not
 * freeze the process mid-call.
 *
 * The push carries no SDP. It says *that* a call is arriving and from whom; the
 * OFFER is a durable envelope sitting in the relay queue, and draining that queue
 * is what actually drives `CallManager` into `INCOMING_RINGING` and sends RINGING
 * back to the caller.
 */
class IncomingCallService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var wake: CallWake? = null
    private var ringing = false
    private var finished = false

    /**
     * Whether the OFFER has actually turned up.
     *
     * Needed because `calls.call` is null both before a call exists and after it
     * ends, and those two mean opposite things here.
     */
    private var sawCall = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DECLINE -> decline()
            ACTION_ACCEPT -> accept()
            else -> ring(intent)
        }
        // Never restart with a null intent: a call that has already been missed
        // must not start ringing again minutes later.
        return START_NOT_STICKY
    }

    private fun ring(intent: Intent?) {
        CallNotifications.ensureChannels(this)
        val incoming = intent?.let(CallWake::fromIntent)

        // startForeground is not optional: the system started this with
        // startForegroundService and kills the process if it does not happen
        // promptly — including on the path where the payload was unusable.
        if (incoming == null) {
            goForeground(CallNotifications.incoming(this, UNKNOWN_CALLER))
            Log.w(TAG, "call wake without usable metadata")
            finish(missed = false)
            return
        }

        wake = incoming
        goForeground(CallNotifications.incoming(this, incoming))
        if (!CallNotifications.canUseFullScreenIntent(this)) {
            // Not fatal — the call still rings as a heads-up notification — but
            // it is the difference between waking the screen and not.
            Log.i(TAG, "full-screen intent not permitted; ringing as heads-up only")
        }
        beginRinging(incoming)
    }

    private fun beginRinging(incoming: CallWake) {
        if (ringing) return
        ringing = true
        scope.launch {
            val relay = RelayRuntime.require(applicationContext)
            if (relay == null) {
                // Woken for an account this install no longer has.
                finish(missed = false)
                return@launch
            }

            // Everything after the OFFER — ANSWER, ICE — is ephemeral and only
            // reaches a device with a live socket, so the socket has to come up
            // even though the OFFER itself arrives over REST.
            relay.start()
            runCatching { relay.drainQueue() }
                .onFailure { Log.w(TAG, "queue drain failed for call wake", it) }

            launch { watchCall(relay) }
            launch { ringTimeout(relay, incoming) }
        }
    }

    /** Follows the call to its end, so the notification never outlives it. */
    private suspend fun watchCall(relay: RelayService) {
        relay.calls.call.collect { active ->
            when {
                active != null -> {
                    sawCall = true
                    if (active.state == CallState.ACTIVE) {
                        wake?.let {
                            NotificationManagerCompat.from(this)
                                .notify(CallNotifications.NOTIFICATION_ID, CallNotifications.ongoing(this, it))
                        }
                    }
                }
                // Null after the call existed means it ended — by hangup, by
                // decline, or because there was no media transport to connect.
                sawCall -> finish(missed = false)
            }
        }
    }

    /**
     * Stops ringing if nothing comes of the wake.
     *
     * Covers two cases with one timer: the caller gave up, and the OFFER never
     * arrived at all (a push that beat its own envelope into the queue). iOS
     * gives up at 45 s; a little longer here, since the queue drain has to
     * happen first.
     */
    private suspend fun ringTimeout(relay: RelayService, incoming: CallWake) {
        delay(RING_TIMEOUT_MS)
        if (finished) return
        val state = relay.calls.call.value?.state
        if (state == null || state == CallState.INCOMING_RINGING) {
            runCatching { relay.calls.hangUp() }
            finish(missed = true)
        }
    }

    private fun accept() {
        scope.launch {
            val relay = RelayRuntime.require(applicationContext)
            val accepted = relay?.calls?.accept() ?: false
            if (!accepted) {
                // Until the WebRTC transport lands (PROTOCOL.md §7.6) this is the
                // expected outcome: signalling is right, but there is nothing to
                // carry audio, so the call ends rather than pretending to connect.
                Log.w(TAG, "could not answer: no media transport")
                finish(missed = false)
            }
        }
    }

    private fun decline() {
        scope.launch {
            runCatching { RelayRuntime.require(applicationContext)?.calls?.hangUp() }
            finish(missed = false)
        }
    }

    /**
     * Promotes the service, falling back to a bare notification if refused.
     *
     * From Android 12 `startForeground` itself can throw when the app is not
     * allowed to hold a foreground service right now. The wake still arrived and
     * the call is still real, so the answer is to ring anyway and accept that the
     * process may be frozen sooner — not to swallow the call.
     */
    private fun goForeground(notification: Notification) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    CallNotifications.NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL,
                )
            } else {
                startForeground(CallNotifications.NOTIFICATION_ID, notification)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "could not go foreground; ringing as a plain notification", t)
            NotificationManagerCompat.from(this)
                .notify(CallNotifications.NOTIFICATION_ID, notification)
        }
    }

    private fun finish(missed: Boolean) {
        if (finished) return
        finished = true
        if (missed) wake?.let { CallNotifications.missed(applicationContext, it) }
        stopForeground(STOP_FOREGROUND_REMOVE)
        CallNotifications.cancel(applicationContext)
        stopSelf()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "RelayCall"

        const val ACTION_RING = "app.relaymsg.call.RING"
        const val ACTION_ACCEPT = "app.relaymsg.call.ACCEPT"
        const val ACTION_DECLINE = "app.relaymsg.call.DECLINE"

        private const val RING_TIMEOUT_MS = 60_000L

        private val UNKNOWN_CALLER =
            CallWake(callId = "", callerAccount = "", callerName = "Relay", isVideo = false)

        /**
         * Starts ringing for a call wake.
         *
         * A high-priority FCM message puts the app on the temporary power
         * allowlist, which is what permits starting a foreground service from the
         * background. That allowlist is not guaranteed — quota, OEM policy, or an
         * app the user has restricted — so a refusal falls back to a plain
         * notification rather than dropping the call.
         */
        fun ring(context: Context, wake: CallWake) {
            val intent = wake.putInto(Intent(context, IncomingCallService::class.java))
                .setAction(ACTION_RING)
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (t: Throwable) {
                Log.w(TAG, "foreground service refused; ringing without one", t)
                CallNotifications.ringWithoutService(context, wake)
            }
        }
    }
}
