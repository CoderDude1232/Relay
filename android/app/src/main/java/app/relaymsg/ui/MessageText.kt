package app.relaymsg.ui

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration

/**
 * The small markdown subset the composer can produce.
 *
 * Rendered, not stripped: the markers travel in the message body, so a client
 * that does not understand them still shows something readable. That is why
 * the set is deliberately tiny and why nothing here can fail — an unmatched
 * marker is left exactly as typed rather than swallowing the rest of the line.
 */
object MessageText {

    /** Marker, style. Order matters: the longest marker has to be tried first. */
    private val rules = listOf(
        "**" to SpanStyle(fontWeight = FontWeight.Bold),
        "~~" to SpanStyle(textDecoration = TextDecoration.LineThrough),
        "_" to SpanStyle(fontStyle = FontStyle.Italic),
        "`" to SpanStyle(fontFamily = FontFamily.Monospace),
    )

    fun format(body: String): AnnotatedString = buildAnnotatedString {
        var index = 0
        while (index < body.length) {
            val rule = rules.firstOrNull { (marker, _) ->
                body.startsWith(marker, index) &&
                    // A closing marker must exist, and there must be something
                    // between them — "**" alone is two asterisks, not bold.
                    body.indexOf(marker, index + marker.length).let { it > index + marker.length }
            }
            if (rule == null) {
                append(body[index])
                index++
                continue
            }
            val (marker, style) = rule
            val close = body.indexOf(marker, index + marker.length)
            withStyle(style) { append(body.substring(index + marker.length, close)) }
            index = close + marker.length
        }
    }

    /** Wraps a selection, or opens an empty pair for the cursor to sit inside. */
    fun applyMarker(text: String, selection: IntRange, marker: String): Pair<String, Int> {
        val start = selection.first.coerceIn(0, text.length)
        val end = (selection.last + 1).coerceIn(start, text.length)
        val selected = text.substring(start, end)
        val updated = text.substring(0, start) + marker + selected + marker + text.substring(end)
        // With nothing selected the caret belongs between the markers, not
        // after them, or the next keystroke lands outside the formatting.
        val caret = if (selected.isEmpty()) start + marker.length else end + marker.length * 2
        return updated to caret
    }
}
