package app.relaymsg.ui

import android.graphics.Bitmap
import android.graphics.Color as AndroidColor
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

/**
 * A QR code, always on white.
 *
 * The white plate is not decoration: a dark-theme QR drawn in the foreground
 * colour on a dark surface is unreadable to most scanners, which expect dark
 * modules on a light field.
 */
@Composable
fun QrImage(content: String, size: Dp) {
    val bitmap = remember(content) { qrBitmap(content) }
    Box(
        modifier = Modifier
            .background(Color.White, RoundedCornerShape(14.dp))
            .padding(14.dp),
    ) {
        if (bitmap == null) {
            Text(
                "Couldn't draw the code.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
            )
        } else {
            Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = "QR code",
                modifier = Modifier.size(size),
            )
        }
    }
}

private fun qrBitmap(text: String, pixels: Int = 640): Bitmap? = runCatching {
    val matrix = QRCodeWriter().encode(
        text,
        BarcodeFormat.QR_CODE,
        pixels,
        pixels,
        mapOf(
            // These payloads are short, so there is room for the stronger level;
            // it survives a poorer camera and a reflective screen.
            EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.Q,
            EncodeHintType.MARGIN to 1,
        ),
    )
    val buffer = IntArray(matrix.width * matrix.height)
    for (y in 0 until matrix.height) {
        val row = y * matrix.width
        for (x in 0 until matrix.width) {
            buffer[row + x] = if (matrix.get(x, y)) AndroidColor.BLACK else AndroidColor.WHITE
        }
    }
    Bitmap.createBitmap(buffer, matrix.width, matrix.height, Bitmap.Config.ARGB_8888)
}.getOrNull()
