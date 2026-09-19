package app.relaymsg.ui

import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

/**
 * Per-conversation look: the wallpaper behind the thread and the tint of your
 * own bubbles.
 *
 * Purely local. Nothing here is sent, so two people in the same conversation
 * can and will see different colours — which is the point, and why it is not
 * part of the wire format.
 *
 * The palettes are iOS's, hex for hex, so the same choice looks the same on
 * both clients.
 */
object ChatAppearance {

    data class Wallpaper(val id: String, val title: String, val stops: List<Color>?) {
        val brush: Brush? get() = stops?.let { Brush.verticalGradient(it) }
    }

    data class BubbleTint(val key: String, val stops: List<Color>)

    data class Theme(val id: String, val name: String, val wallpaperId: String, val bubbleKey: String)

    val wallpapers = listOf(
        Wallpaper("none", "None", null),
        Wallpaper("sunset", "Sunset", listOf(0xFFFF7E5F, 0xFFFEB47B).colours()),
        Wallpaper("ocean", "Ocean", listOf(0xFF2193B0, 0xFF6DD5ED).colours()),
        Wallpaper("forest", "Forest", listOf(0xFF134E5E, 0xFF71B280).colours()),
        Wallpaper("twilight", "Twilight", listOf(0xFF4B2E83, 0xFF9D50BB).colours()),
        Wallpaper("rose", "Rose", listOf(0xFFC94B8F, 0xFFF6A5C0).colours()),
        Wallpaper("graphite", "Graphite", listOf(0xFF1C1C1E, 0xFF3A3A3C).colours()),
    )

    val bubbleTints = listOf(
        BubbleTint("0A84FF-5E5CE6", listOf(0xFF0A84FF, 0xFF5E5CE6).colours()),
        BubbleTint("30D158-00C7BE", listOf(0xFF30D158, 0xFF00C7BE).colours()),
        BubbleTint("BF5AF2-FF2D55", listOf(0xFFBF5AF2, 0xFFFF2D55).colours()),
        BubbleTint("FF3B30-FF9500", listOf(0xFFFF3B30, 0xFFFF9500).colours()),
        BubbleTint("FF9500-FFCC00", listOf(0xFFFF9500, 0xFFFFCC00).colours()),
        BubbleTint("34C759-0A84FF", listOf(0xFF34C759, 0xFF0A84FF).colours()),
        BubbleTint("2C2C2E-48484A", listOf(0xFF2C2C2E, 0xFF48484A).colours()),
        BubbleTint("FF2D55-FF6B35", listOf(0xFFFF2D55, 0xFFFF6B35).colours()),
    )

    /** Wallpaper and bubble chosen together, so the bubble contrasts with it. */
    val themes = listOf(
        Theme("ocean", "Ocean", "ocean", "30D158-00C7BE"),
        Theme("forest", "Forest", "forest", "FF9500-FFCC00"),
        Theme("twilight", "Twilight", "twilight", "00C7BE-30D158"),
        Theme("sunset", "Sunset", "sunset", "BF5AF2-5E5CE6"),
        Theme("rose", "Rose", "rose", "0A84FF-5E5CE6"),
        Theme("dark", "Dark", "graphite", "0A84FF-5E5CE6"),
    )

    fun wallpaper(id: String?): Wallpaper = wallpapers.firstOrNull { it.id == id } ?: wallpapers[0]

    /**
     * A bubble tint by key, or null for the brand magenta.
     *
     * Keys are parsed rather than looked up, so a theme naming a pair that is
     * not in the palette still works — iOS's themes do exactly that.
     */
    fun bubbleTint(key: String?): List<Color>? {
        if (key.isNullOrEmpty()) return null
        bubbleTints.firstOrNull { it.key == key }?.let { return it.stops }
        val parts = key.split("-")
        if (parts.size != 2) return null
        return runCatching {
            parts.map { Color(("FF$it").toLong(16)) }
        }.getOrNull()
    }

    private fun List<Long>.colours() = map { Color(it) }
}
