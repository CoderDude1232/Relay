package app.relaymsg.call

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import app.relaymsg.R

/**
 * The ringing UI.
 *
 * Android has no PushKit/CallKit equivalent, so an incoming call is a
 * **full-screen-intent notification** in a high-importance channel plus a
 * foreground service — the same shape WhatsApp and Signal use. The full-screen
 * intent is what turns the screen on and shows [IncomingCallActivity] over the
 * lock screen; when the device is unlocked and in use, the system shows the
 * CallStyle heads-up notification instead, which is the behaviour users expect.
 */
object CallNotifications {

    /** Its own channel so a call rings even when message notifications are muted. */
    const val CHANNEL_CALLS = "relay.calls"
    private const val CHANNEL_MISSED = "relay.calls.missed"

    /** One call at a time, so one id — a second call replaces the notification. */
    const val NOTIFICATION_ID = 0xCA11

    private const val MISSED_ID = 0xCA12

    fun ensureChannels(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (manager.getNotificationChannel(CHANNEL_CALLS) == null) {
            val channel = NotificationChannel(
                CHANNEL_CALLS,
                "Calls",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Incoming Relay calls"
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                    AudioAttributes.Builder()
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        // RINGTONE, not NOTIFICATION: it follows the ring volume
                        // and keeps ringing rather than playing a one-shot blip.
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .build(),
                )
                enableVibration(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setBypassDnd(true)
            }
            manager.createNotificationChannel(channel)
        }

        if (manager.getNotificationChannel(CHANNEL_MISSED) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_MISSED,
                    "Missed calls",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
        }
    }

    /** The ringing notification, which doubles as the foreground-service one. */
    fun incoming(context: Context, wake: CallWake): Notification {
        val caller = Person.Builder()
            .setName(wake.displayName)
            .setImportant(true)
            .build()

        return NotificationCompat.Builder(context, CHANNEL_CALLS)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle(wake.displayName)
            .setContentText(if (wake.isVideo) "Incoming video call" else "Incoming call")
            .setStyle(
                NotificationCompat.CallStyle.forIncomingCall(
                    caller,
                    action(context, CallService.ACTION_DECLINE, wake),
                    action(context, CallService.ACTION_ACCEPT, wake),
                ),
            )
            .setFullScreenIntent(fullScreen(context, wake), true)
            .setContentIntent(fullScreen(context, wake))
            // Ongoing + no auto-cancel: a ringing call must not be swiped away
            // into a state where the far side is still waiting.
            .setOngoing(true)
            .setAutoCancel(false)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
    }

    /** Replaces the ringing notification once the call is up. */
    fun ongoing(context: Context, wake: CallWake): Notification {
        val caller = Person.Builder().setName(wake.displayName).setImportant(true).build()
        return NotificationCompat.Builder(context, CHANNEL_CALLS)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle(wake.displayName)
            .setContentText("Relay call")
            .setStyle(
                NotificationCompat.CallStyle.forOngoingCall(
                    caller,
                    action(context, CallService.ACTION_DECLINE, wake),
                ),
            )
            .setContentIntent(fullScreen(context, wake))
            .setOngoing(true)
            .setUsesChronometer(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
    }

    /** Posts "missed call". No-op without notification permission. */
    fun missed(context: Context, wake: CallWake) {
        if (!canNotify(context)) return
        ensureChannels(context)
        val notification = NotificationCompat.Builder(context, CHANNEL_MISSED)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle("Missed call")
            .setContentText(wake.displayName)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MISSED_CALL)
            .build()
        NotificationManagerCompat.from(context).notify(MISSED_ID, notification)
    }

    /**
     * Rings without a foreground service.
     *
     * The fallback for when starting one is refused — the wake still arrived, so
     * ringing with a plain notification beats staying silent.
     */
    fun ringWithoutService(context: Context, wake: CallWake) {
        if (!canNotify(context)) return
        ensureChannels(context)
        NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, incoming(context, wake))
    }

    fun cancel(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
    }

    /**
     * Whether the system will actually raise the full-screen UI.
     *
     * From Android 14 `USE_FULL_SCREEN_INTENT` is granted by default only to
     * calling and alarm apps; elsewhere it is a user toggle. When it is off the
     * notification still posts as a heads-up, so this is for diagnostics rather
     * than a reason to skip ringing.
     */
    fun canUseFullScreenIntent(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        val manager = context.getSystemService(NotificationManager::class.java)
        return manager.canUseFullScreenIntent()
    }

    private fun canNotify(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ActivityCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun fullScreen(context: Context, wake: CallWake): PendingIntent {
        val intent = wake.putInto(Intent(context, IncomingCallActivity::class.java))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            context,
            wake.callId.hashCode(),
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    /**
     * Answer/decline go to the service, not the activity: the service already
     * holds the call, and routing through it means the buttons behave the same
     * whether they were tapped on the lock screen or in the heads-up card.
     */
    private fun action(context: Context, action: String, wake: CallWake): PendingIntent {
        val intent = wake.putInto(Intent(context, CallService::class.java)).setAction(action)
        return PendingIntent.getService(
            context,
            action.hashCode(),
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}
