package app.relaymsg.ui

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** The appearance palettes, which have to agree with iOS hex for hex. */
class ChatAppearanceTest {

    @Test
    fun `a tint key resolves to its two stops`() {
        val stops = ChatAppearance.bubbleTint("0A84FF-5E5CE6")
        assertEquals(listOf(Color(0xFF0A84FF), Color(0xFF5E5CE6)), stops)
    }

    @Test
    fun `a key outside the palette still parses`() {
        // iOS's own themes name pairs that are not palette entries, so keys are
        // parsed rather than looked up.
        assertNotNull(ChatAppearance.bubbleTint("00C7BE-30D158"))
        assertEquals(
            listOf(Color(0xFF00C7BE), Color(0xFF30D158)),
            ChatAppearance.bubbleTint("00C7BE-30D158"),
        )
    }

    @Test
    fun `no key means the brand colour`() {
        assertNull(ChatAppearance.bubbleTint(null))
        assertNull(ChatAppearance.bubbleTint(""))
    }

    @Test
    fun `a malformed key falls back rather than throwing`() {
        assertNull(ChatAppearance.bubbleTint("nonsense"))
        assertNull(ChatAppearance.bubbleTint("ZZZZZZ-YYYYYY"))
    }

    @Test
    fun `every theme names a wallpaper and a tint that resolve`() {
        ChatAppearance.themes.forEach { theme ->
            assertEquals(theme.wallpaperId, ChatAppearance.wallpaper(theme.wallpaperId).id)
            assertNotNull("${theme.id} tint", ChatAppearance.bubbleTint(theme.bubbleKey))
        }
    }

    @Test
    fun `an unknown wallpaper falls back to none`() {
        assertEquals("none", ChatAppearance.wallpaper("nope").id)
        assertNull(ChatAppearance.wallpaper("none").brush)
    }
}
