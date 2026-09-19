package app.relaymsg.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import app.relaymsg.MainActivity
import app.relaymsg.R
import app.relaymsg.push.RelayRuntime
import kotlinx.coroutines.launch

/**
 * The home-screen widget: recent conversations and an unread count.
 *
 * The Android analogue of the iOS widget extension, and it stops at the same
 * place iOS's small widget does — names and a count, never message text. A
 * widget is on a locked home screen where anyone can read it.
 *
 * iOS's Live Activity has no Android counterpart worth faking; the ongoing
 * call notification already fills that role.
 */
class RelayWidget : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        // The store is encrypted and opening it is not instant, so the widget
        // renders its frame straight away and fills in when the data arrives.
        render(context, manager, appWidgetIds, names = emptyList(), unread = 0, loading = true)

        RelayRuntime.scope.launch {
            val service = RelayRuntime.require(context)
            val conversations = service?.conversations?.value.orEmpty()
            render(
                context = context,
                manager = manager,
                appWidgetIds = appWidgetIds,
                names = conversations
                    .sortedByDescending { it.lastMessageAt ?: 0L }
                    .take(ROWS)
                    .map { service?.conversationTitle(it) ?: it.peerAccount.take(8) },
                unread = conversations.sumOf { it.unreadCount },
                loading = false,
            )
        }
    }

    private fun render(
        context: Context,
        manager: AppWidgetManager,
        appWidgetIds: IntArray,
        names: List<String>,
        unread: Int,
        loading: Boolean,
    ) {
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val views = RemoteViews(context.packageName, R.layout.widget_relay).apply {
            setOnClickPendingIntent(R.id.widget_relay_root, open)
            setTextViewText(
                R.id.widget_subtitle,
                when {
                    loading -> ""
                    unread == 0 -> "No unread messages"
                    unread == 1 -> "1 unread message"
                    else -> "$unread unread messages"
                },
            )
            ROW_IDS.forEachIndexed { index, id ->
                val name = names.getOrNull(index)
                setTextViewText(id, name ?: "")
                setViewVisibility(id, if (name == null) View.GONE else View.VISIBLE)
            }
        }
        runCatching { manager.updateAppWidget(appWidgetIds, views) }
    }

    companion object {
        private const val ROWS = 4
        private val ROW_IDS = listOf(
            R.id.widget_row_0,
            R.id.widget_row_1,
            R.id.widget_row_2,
            R.id.widget_row_3,
        )

        /** Redraws every placed widget. Called when conversations change. */
        fun refresh(context: Context) {
            runCatching {
                val manager = AppWidgetManager.getInstance(context)
                val ids = manager.getAppWidgetIds(
                    android.content.ComponentName(context, RelayWidget::class.java),
                )
                if (ids.isNotEmpty()) {
                    context.sendBroadcast(
                        Intent(context, RelayWidget::class.java)
                            .setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids),
                    )
                }
            }
        }
    }
}
