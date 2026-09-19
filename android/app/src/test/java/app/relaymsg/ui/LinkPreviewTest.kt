package app.relaymsg.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Finding the link in a message body. */
class LinkPreviewTest {

    @Test
    fun `finds the first link`() {
        assertEquals("https://example.com", LinkPreview.firstUrl("see https://example.com now"))
        assertEquals(
            "https://a.example.com/x?y=1",
            LinkPreview.firstUrl("https://a.example.com/x?y=1 and https://b.example.com"),
        )
        assertEquals("http://plain.example", LinkPreview.firstUrl("http://plain.example"))
    }

    @Test
    fun `no link means none`() {
        assertNull(LinkPreview.firstUrl("just talking about example.com"))
        assertNull(LinkPreview.firstUrl(""))
        // A bare scheme is not a link worth previewing.
        assertNull(LinkPreview.firstUrl("ftp://files.example.com"))
    }

    @Test
    fun `a trailing quote or bracket is not part of the link`() {
        assertEquals("https://example.com", LinkPreview.firstUrl("""look <https://example.com>"""))
        assertEquals("https://example.com", LinkPreview.firstUrl("""a "https://example.com" b"""))
    }
}
