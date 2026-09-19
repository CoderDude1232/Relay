package app.relaymsg.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** The markdown subset. Markers travel in the body, so they must fail safe. */
class MessageTextTest {

    @Test
    fun `formatting removes the markers it understood`() {
        assertEquals("bold", MessageText.format("**bold**").text)
        assertEquals("italic", MessageText.format("_italic_").text)
        assertEquals("struck", MessageText.format("~~struck~~").text)
        assertEquals("code", MessageText.format("`code`").text)
        assertEquals("a bold b", MessageText.format("a **bold** b").text)
    }

    @Test
    fun `an unmatched marker is left exactly as typed`() {
        // Anything else would swallow the rest of the message, which is much
        // worse than showing an asterisk.
        assertEquals("**unclosed", MessageText.format("**unclosed").text)
        assertEquals("2 * 3 * 4", MessageText.format("2 * 3 * 4").text)
        assertEquals("_", MessageText.format("_").text)
    }

    @Test
    fun `an empty pair is not formatting`() {
        assertEquals("****", MessageText.format("****").text)
    }

    @Test
    fun `applying a marker wraps the selection`() {
        val (text, caret) = MessageText.applyMarker("hello world", 0..4, "**")
        assertEquals("**hello** world", text)
        assertEquals(9, caret)
    }

    @Test
    fun `applying a marker with no selection leaves the caret inside`() {
        // The next keystroke has to land between the markers, not after them.
        val (text, caret) = MessageText.applyMarker("ab", 2..1, "_")
        assertEquals("ab__", text)
        assertEquals(3, caret)
    }
}
