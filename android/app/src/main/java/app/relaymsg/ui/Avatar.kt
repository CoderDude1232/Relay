package app.relaymsg.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * A contact's circle.
 *
 * The tints are a small curated set rather than a hue wheel: every one is a
 * neighbour of the brand magenta, so a list of them reads as one palette
 * instead of a fruit salad. Which one a contact gets is derived from their
 * account id, so it is stable across devices and installs without storing
 * anything.
 *
 * Each pair is a fill and a foreground checked to at least 4.5:1.
 */
private val Tints = listOf(
    Color(0xFF7E0A8A) to Color.White, //  9.1:1 — brand deep
    Color(0xFF5B2A9D) to Color.White, //  9.0:1 — violet
    Color(0xFF9C1458) to Color.White, //  7.5:1 — rose
    Color(0xFF3F3D8F) to Color.White, // 10.0:1 — indigo
    Color(0xFF8E2C2C) to Color.White, //  7.8:1 — plum red
    Color(0xFF2E5F73) to Color.White, //  7.4:1 — slate teal
)

@Composable
fun Avatar(
    /** Stable key — the account or group id, never the display name. */
    id: String,
    name: String,
    size: Dp = 48.dp,
) {
    // Math.floorMod, because String.hashCode is signed and a negative index
    // would crash on the first contact whose id happened to hash that way.
    val (fill, ink) = Tints[Math.floorMod(id.hashCode(), Tints.size)]

    Box(
        modifier = Modifier.size(size).background(fill, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = name.initials(),
            color = ink,
            fontWeight = FontWeight.SemiBold,
            // Scales with the circle so one composable serves a list row and a
            // call screen without a second set of sizes.
            fontSize = (size.value * 0.36f).sp,
            style = MaterialTheme.typography.titleMedium,
        )
    }
}

/**
 * One or two letters.
 *
 * Works on code points, not chars: a name starting with an emoji or any
 * astral-plane character would otherwise be cut in half and render as a box.
 */
private fun String.initials(): String {
    val words = trim().split(' ', '.', '_', '-').filter { it.isNotEmpty() }
    return when {
        words.isEmpty() -> "?"
        words.size == 1 -> words[0].firstGrapheme().uppercase()
        else -> (words[0].firstGrapheme() + words[1].firstGrapheme()).uppercase()
    }
}

private fun String.firstGrapheme(): String =
    if (isEmpty()) "" else substring(0, offsetByCodePoints(0, 1))
