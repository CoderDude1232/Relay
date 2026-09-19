package app.relaymsg.share

import android.content.Context
import android.content.Intent
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import app.relaymsg.R
import app.relaymsg.storage.Conversation

/**
 * Publishes recent conversations to the system share sheet.
 *
 * Android's analogue of the iOS Intents extension: iOS donates
 * `INSendMessageIntent` so Siri can offer "message X on Relay"; Android
 * publishes *sharing shortcuts*, which put the same people at the top of every
 * share sheet and in the launcher's long-press menu.
 *
 * Deliberately no avatars and no last-message text — shortcuts live in the
 * system's shortcut store, outside the encrypted database, and are readable by
 * the launcher. A name is the least that makes the feature work.
 */
object SharingShortcuts {

    /** The category the share target filters on; both sides must agree. */
    private const val CATEGORY = "app.relaymsg.category.SHARE_TARGET"

    /** The system caps these; four is what a share sheet shows anyway. */
    private const val MAX = 4

    fun publish(context: Context, conversations: List<Conversation>, titleFor: (Conversation) -> String) {
        runCatching {
            val shortcuts = conversations
                .sortedByDescending { it.lastMessageAt ?: 0L }
                .take(MAX)
                .map { conversation ->
                    val title = titleFor(conversation)
                    ShortcutInfoCompat.Builder(context, conversation.id)
                        .setShortLabel(title)
                        .setLongLabel(title)
                        .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
                        .setCategories(setOf(CATEGORY))
                        // Long-lived, or the system drops it from Direct Share
                        // as soon as the app is not in the foreground.
                        .setLongLived(true)
                        .setPerson(Person.Builder().setName(title).setKey(conversation.peerAccount).build())
                        .setIntent(
                            Intent(context, ShareTargetActivity::class.java)
                                .setAction(Intent.ACTION_SEND)
                                .putExtra(Intent.EXTRA_SHORTCUT_ID, conversation.id),
                        )
                        .build()
                }
            ShortcutManagerCompat.setDynamicShortcuts(context, shortcuts)
        }
    }

    /** Removes every shortcut. Called on sign-out, with the rest of the data. */
    fun clear(context: Context) {
        runCatching { ShortcutManagerCompat.removeAllDynamicShortcuts(context) }
    }
}
