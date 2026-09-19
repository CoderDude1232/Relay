package app.relaymsg.call

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale

/**
 * What a voice call sits on, mirroring iOS's `CallView.audioBackground`.
 *
 * With a profile photo it is that photo blown up into an unrecognisable wash of
 * its own colours; without one it is the same colour the contact's circle uses,
 * falling to black. Either way the screen is tinted by who is on it, which is
 * the point — you can tell who you are talking to from across the room.
 */
@Composable
internal fun CallBackdrop(peerName: String, peerAvatar: ByteArray?, modifier: Modifier = Modifier) {
    // Black underneath regardless: every layer above is translucent, and a
    // half-loaded screen should read as dark, not as blank white.
    Box(modifier.fillMaxSize().background(Color.Black)) {
        val wash = remember(peerAvatar) { peerAvatar?.let(::decodeWash) }
        if (wash != null) {
            Image(
                bitmap = wash,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                // The blur is the decode: the bitmap comes back a few dozen
                // pixels wide and is stretched over the screen, which blurs it
                // on every API level. Modifier.blur needs 31+ and does nothing
                // silently below that, which is worse than not offering it.
                filterQuality = FilterQuality.High,
                colorFilter = ColorFilter.colorMatrix(ColorMatrix().apply { setToSaturation(2.2f) }),
                modifier = Modifier.fillMaxSize(),
            )
            // iOS darkens the wash by the same amount; without it the controls
            // have to compete with whatever was in the photo.
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.38f)))
        } else {
            val tint = callTint(peerName)
            Box(
                Modifier.fillMaxSize().background(
                    Brush.verticalGradient(
                        // iOS's three stops. The colour is gone by 80% down, so
                        // the controls sit on black.
                        0.0f to tint.copy(alpha = 0.80f),
                        0.4f to tint.copy(alpha = 0.40f),
                        0.8f to tint.copy(alpha = 0.05f),
                    ),
                ),
            )
        }
    }
}

/**
 * Decodes the avatar down to a thumbnail.
 *
 * `inSampleSize` is chosen so the result is at most ~48px on its long edge,
 * which is both the blur and a guarantee that the call screen never holds a
 * full-resolution bitmap.
 */
private fun decodeWash(data: ByteArray) = runCatching {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 48) sample *= 2
    BitmapFactory.decodeByteArray(
        data, 0, data.size,
        BitmapFactory.Options().apply { inSampleSize = sample },
    )?.asImageBitmap()
}.getOrNull()

/**
 * The contact's avatar colour, so the screen and the circle agree.
 *
 * Deliberately a copy of `ui.Avatar`'s palette and hash rather than a call into
 * it: that one is a composable returning a circle, and this needs the colour.
 * Both mirror iOS, and if one moves the other has to move with it.
 */
internal fun callTint(name: String): Color {
    val palette = listOf(
        Color(0xFF007AFF), Color(0xFFAF52DE), Color(0xFFFF2D55), Color(0xFFFF9500),
        Color(0xFF30B0C7), Color(0xFF5856D6), Color(0xFF34C759),
    )
    var hash = 0L
    var i = 0
    while (i < name.length) {
        val codePoint = name.codePointAt(i)
        hash = hash * 31L + codePoint.toLong()
        i += Character.charCount(codePoint)
    }
    val positive = if (hash == Long.MIN_VALUE) 0L else kotlin.math.abs(hash)
    return palette[(positive % palette.size).toInt()]
}
