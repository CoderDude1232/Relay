package app.relaymsg.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * A curated emoji grid.
 *
 * Curated rather than the full Unicode set on purpose, and for the same reason
 * iOS curates it: the system keyboard already has every emoji one tap away, so
 * this exists to put the useful few hundred in reach *without* dismissing the
 * composer. The set matches iOS's, category for category.
 */
object Emoji {

    data class Category(val name: String, val emoji: List<String>)

    val categories = listOf(
        Category(
            "Smileys",
            (
                "😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 😚 😋 😛 😜 🤪 😝 " +
                    "🤗 🤔 🤨 😐 😑 😶 🙄 😏 😴 😪 😌 😔 🤤 😷 🤒 🤕 🤮 🥵 🥶 😵 🤯 🤠 🥳 😎 " +
                    "🤓 😕 😟 🙁 😮 😯 😲 😳 🥺 😦 😰 😢 😭 😱 😖 😞 😤 😡 🤬 💀 👻 👽 🤖 🎃"
                ).split(" "),
        ),
        Category(
            "Gestures & People",
            (
                "👋 🤚 ✋ 🖐️ 👌 🤌 🤏 ✌️ 🤞 🤟 🤘 👈 👉 👆 👇 ☝️ 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 " +
                    "👐 🤲 🙏 💪 🫶 💅 👀 🧠 🫦 👶 🧑 👨 👩 🧔 👮 🕵️ 💃 🕺 🧗 🏃 🚶 🧘"
                ).split(" "),
        ),
        Category(
            "Hearts & Symbols",
            (
                "❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💯 ✨ ⭐️ 🌟 💫 🔥 " +
                    "💥 💦 💤 🎉 🎊 ✅ ❌ ❓ ❗️ ⚠️ 🚫 🔴"
                ).split(" "),
        ),
        Category(
            "Animals & Nature",
            (
                "🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🐔 🐧 🐦 🦄 🐝 🦋 🐢 🐙 🐳 " +
                    "🌵 🌲 🌴 🌸 🌻 🌹 🍀 🍁 🌈 ☀️ 🌙 ⚡️"
                ).split(" "),
        ),
        Category(
            "Food & Drink",
            (
                "🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🥑 🌽 🌶️ 🍔 🍟 🍕 🌭 " +
                    "🌮 🌯 🍜 🍣 🍩 🍪 🎂 🍰 🍫 🍿 ☕️ 🍺"
                ).split(" "),
        ),
        Category(
            "Activities & Objects",
            (
                "⚽️ 🏀 🏈 ⚾️ 🎾 🏐 🎱 🏓 🏸 🥅 🎯 🎮 🎲 🎸 🎹 🎺 🎧 🎤 🎬 📷 💻 📱 ⌚️ 💡 " +
                    "🔑 🎁 📚 ✏️ 📌 🔒 ⏰ 🚗 ✈️ 🚀 🏠 💰"
                ).split(" "),
        ),
    )

    /**
     * Whether a message is short and entirely emoji.
     *
     * Those render large and without a bubble, the way iMessage and Signal do
     * it — a single 😂 in a full-width bubble reads as shouting.
     */
    fun isJumbo(body: String): Boolean {
        val trimmed = body.trim()
        if (trimmed.isEmpty()) return false
        var count = 0
        var index = 0
        while (index < trimmed.length) {
            val codePoint = trimmed.codePointAt(index)
            // Variation selectors and zero-width joiners are part of the
            // neighbouring glyph, not characters of their own.
            if (codePoint != 0xFE0F && codePoint != 0x200D) {
                if (!isEmojiCodePoint(codePoint)) return false
                count++
            }
            index += Character.charCount(codePoint)
        }
        return count in 1..JUMBO_MAX
    }

    private const val JUMBO_MAX = 3

    private fun isEmojiCodePoint(codePoint: Int): Boolean = when (codePoint) {
        in 0x1F000..0x1FAFF, in 0x2600..0x27BF, in 0x2B00..0x2BFF,
        in 0xFE00..0xFE0F, in 0x1F1E6..0x1F1FF, 0x203C, 0x2049,
        in 0x2190..0x21FF, in 0x2300..0x23FF,
        -> true
        else -> false
    }
}

/** The grid itself, for the composer and the reaction sheet alike. */
@Composable
fun EmojiPicker(onPick: (String) -> Unit, modifier: Modifier = Modifier) {
    var tab by remember { mutableIntStateOf(0) }
    Column(modifier) {
        ScrollableTabRow(selectedTabIndex = tab, edgePadding = 12.dp) {
            Emoji.categories.forEachIndexed { index, category ->
                Tab(
                    selected = index == tab,
                    onClick = { tab = index },
                    text = {
                        Text(category.name, style = MaterialTheme.typography.labelMedium)
                    },
                )
            }
        }
        LazyVerticalGrid(
            columns = GridCells.Adaptive(46.dp),
            modifier = Modifier.fillMaxWidth().height(240.dp),
        ) {
            items(Emoji.categories[tab].emoji) { emoji ->
                Text(
                    text = emoji,
                    fontSize = 28.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .clickable { onPick(emoji) }
                        .padding(8.dp),
                )
            }
        }
    }
}
