package app.relaymsg.ui
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Which messages render large and bubbleless. */
class EmojiTest {

    @Test
    fun `short all-emoji messages are jumbo`() {
        assertTrue(Emoji.isJumbo("😂"))
        assertTrue(Emoji.isJumbo("😂😂😂"))
        // A skin tone or a flag is one glyph made of several code points.
        assertTrue(Emoji.isJumbo("👍🏽"))
    }

    @Test
    fun `anything with text is not`() {
        assertFalse(Emoji.isJumbo("ha 😂"))
        assertFalse(Emoji.isJumbo("hello"))
        assertFalse(Emoji.isJumbo(""))
        assertFalse(Emoji.isJumbo("   "))
    }

    @Test
    fun `a long run of emoji is not`() {
        // Past a few it is a message rather than a reaction, and rendering it
        // at 40sp would take the whole screen.
        assertFalse(Emoji.isJumbo("😂😂😂😂😂"))
    }
}
