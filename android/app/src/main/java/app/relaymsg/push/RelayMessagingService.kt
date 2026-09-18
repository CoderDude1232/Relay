package app.relaymsg.push

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Base64
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import app.relaymsg.MainActivity
import app.relaymsg.call.CallWake
import app.relaymsg.call.CallService
import app.relaymsg.R
import app.relaymsg.core.EnvelopePipeline
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.runBlocking

/**
 * Handles Firebase wakes.
 *
 * The relay's payload is deliberately **data-only with no `notification` block**
 * (`internal/fcm/fcm.go`), which is what keeps the contentless model intact: the
 * OS cannot render anything by itself, so the app decides what to show — and in
 * the default mode the payload carries no message content at all. This service
 * fetches the envelope from the relay, decrypts it on-device and acks it, so
 * Google's infrastructure only ever learns that *something* arrived.
 *
 * `data.type` is `"wake"` for the contentless default, or `"msg"` with the
 * base64 envelope in `data.e` when the device has opted in to
 * ciphertext-in-push. The relay silently degrades `msg` to `wake` when the
 * envelope exceeds FCM's payload budget, so both must be handled.
 *
 * `"call"` is the third kind and takes a different path entirely: it is what
 * stands in for iOS's PushKit, it is latency-critical, and it must ring rather
 * than notify. See [CallService] and PROTOCOL.md §7.5.1.
 */
class RelayMessagingService : FirebaseMessagingService() {

    companion object {
        private const val CHANNEL_ID = "relay.messages"
        const val TYPE_WAKE = "wake"
        const val TYPE_MESSAGE = "msg"
        const val KEY_ENVELOPE = "e"
    }

    /**
     * FCM rotates tokens; the relay must be told, or the device stops being
     * wakeable with no visible symptom.
     */
    override fun onNewToken(token: String) {
        runBlocking {
            RelayRuntime.require(applicationContext)?.registerPushToken(token)
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        // A call is handled without blocking: the point of the high-priority wake
        // is to ring in the next few hundred milliseconds, and the fetch it needs
        // is far longer than that. The foreground service it starts is what keeps
        // the process alive to do the rest.
        if (message.data["type"] == CallWake.TYPE) {
            CallWake.from(message.data)?.let { CallService.ring(this, it) }
            return
        }

        // FCM allows roughly 10-20s here. Blocking is acceptable and simpler than
        // handing off to WorkManager, since the work is one fetch and a decrypt.
        runBlocking {
            val service = RelayRuntime.require(applicationContext) ?: return@runBlocking
            val outcomes: List<EnvelopePipeline.Outcome> =
                when (message.data["type"]) {
                    TYPE_MESSAGE -> {
                        val encoded = message.data[KEY_ENVELOPE]
                        val envelope = encoded?.let { Base64.decode(it, Base64.DEFAULT) }
                        // Fall back to a queue drain if the payload is unusable —
                        // the envelope is still sitting on the relay either way.
                        envelope?.let { service.applyPushedEnvelope(it) }?.let(::listOf)
                            ?: service.drainQueue()
                    }
                    // "wake", and anything unrecognised: ask the relay what we missed.
                    else -> service.drainQueue()
                }

            outcomes.mapNotNull { outcome ->
                outcome.notificationBody?.let { body ->
                    val sender = outcome.peerAccount?.let(service::displayName) ?: "New message"
                    sender to body
                }
            }.forEach { (sender, body) -> notify(sender, body) }
        }
    }

    private fun notify(sender: String, body: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ActivityCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            // The user declined notifications. The message is already stored and
            // will be visible when they open the app; nothing else to do.
            return
        }
        ensureChannel()

        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle(sender)
            .setContentText(body)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(open)
            .build()

        NotificationManagerCompat.from(this)
            .notify(sender.hashCode(), notification)
    }

    private fun ensureChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Messages",
                NotificationManager.IMPORTANCE_HIGH,
            ),
        )
    }
}
