package app.relaymsg.ui

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * A contact's circle, matching iOS's `AvatarView`.
 *
 * The palette, the hash and the single initial are all copied from there so a
 * contact is the same colour on both clients — someone with both phones open
 * should not have to re-learn the list. These are Apple's system colours, and
 * the hash runs over code points in 64-bit arithmetic exactly as Swift's does,
 * so the two implementations land on the same index for the same name.
 *
 * Caveat inherited with the palette: white on the orange and green is below
 * the 4.5:1 contrast line. The initial is decorative — the name is always next
 * to it — but it is a real difference from the contrast-checked tints this used
 * to draw from, and it is here because matching iOS was the ask.
 */
private val Palette = listOf(
    Color(0xFF007AFF), // .blue
    Color(0xFFAF52DE), // .purple
    Color(0xFFFF2D55), // .pink
    Color(0xFFFF9500), // .orange
    Color(0xFF30B0C7), // .teal
    Color(0xFF5856D6), // .indigo
    Color(0xFF34C759), // .green
)

@Composable
fun Avatar(
    /** Kept for call-site compatibility; the colour comes from the name, as iOS does. */
    id: String,
    name: String,
    size: Dp = 48.dp,
    imageData: ByteArray? = null,
    isGroup: Boolean = false,
) {
    Box(Modifier.size(size)) {
        val bitmap = remember(imageData) {
            imageData?.let {
                runCatching { BitmapFactory.decodeByteArray(it, 0, it.size) }.getOrNull()
            }
        }
        if (bitmap != null) {
            Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.size(size).clip(CircleShape),
            )
        } else {
            Box(
                modifier = Modifier
                    .size(size)
                    .background(gradientFor(name), CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = name.initial(),
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    // iOS uses 0.42 of the circle; one composable then serves a
                    // list row and a call screen without a second set of sizes.
                    fontSize = (size.value * 0.42f).sp,
                    style = MaterialTheme.typography.titleMedium,
                )
            }
        }
        if (isGroup) GroupBadge(size)
    }
}

/** The small people mark iOS puts on a group's circle. */
@Composable
private fun BoxScope.GroupBadge(size: Dp) {
    val badge = size * 0.36f
    Box(
        Modifier
            .align(Alignment.BottomEnd)
            .size(badge)
            .background(MaterialTheme.colorScheme.surfaceVariant, CircleShape)
            .border(1.5.dp, MaterialTheme.colorScheme.surface, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.Filled.Groups,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(badge * 0.64f),
        )
    }
}

/**
 * SwiftUI's `Color.gradient`: the same hue, lifted at the top and dropped at
 * the bottom. Subtle on purpose — at 48dp it reads as depth, not as a stripe.
 */
private fun gradientFor(name: String): Brush {
    val base = Palette[paletteIndex(name)]
    return Brush.verticalGradient(listOf(base.scaled(1.12f), base.scaled(0.84f)))
}

private fun Color.scaled(factor: Float) = Color(
    red = (red * factor).coerceIn(0f, 1f),
    green = (green * factor).coerceIn(0f, 1f),
    blue = (blue * factor).coerceIn(0f, 1f),
    alpha = alpha,
)

/**
 * iOS's hash, reproduced.
 *
 * Swift's `Int` is 64-bit and the app iterates unicode scalars, so this uses
 * `Long` and code points rather than Kotlin's 32-bit `String.hashCode` over
 * UTF-16 units — otherwise the same name would land on a different colour on
 * each platform, which is the one thing this function exists to prevent.
 */
private fun paletteIndex(name: String): Int {
    var hash = 0L
    var i = 0
    while (i < name.length) {
        val codePoint = name.codePointAt(i)
        hash = hash * 31L + codePoint.toLong()
        i += Character.charCount(codePoint)
    }
    // Long.MIN_VALUE has no positive counterpart; its absolute value is itself.
    val positive = if (hash == Long.MIN_VALUE) 0L else kotlin.math.abs(hash)
    return (positive % Palette.size).toInt()
}

/** One letter, as iOS shows. */
private fun String.initial(): String {
    val trimmed = trim()
    if (trimmed.isEmpty()) return "?"
    val codePoint = trimmed.codePointAt(0)
    return String(Character.toChars(codePoint)).uppercase()
}
