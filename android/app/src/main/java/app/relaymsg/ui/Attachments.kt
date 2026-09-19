package app.relaymsg.ui

import android.content.Intent
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import app.relaymsg.storage.StoredAttachment
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * Renders an attachment according to what it actually is.
 *
 * Everything arrives as encrypted bytes with a content type, so the type is the
 * only thing to dispatch on. Anything unrecognised falls through to the file
 * row rather than showing nothing — a document the app cannot preview is still
 * a document the user can open.
 */
@Composable
fun AttachmentBody(
    attachment: StoredAttachment,
    onBlack: Boolean,
    load: suspend (StoredAttachment) -> ByteArray?,
) {
    var bytes by remember(attachment.id) { mutableStateOf<ByteArray?>(null) }
    var failed by remember(attachment.id) { mutableStateOf(false) }

    LaunchedEffect(attachment.id) {
        val loaded = load(attachment)
        if (loaded == null) failed = true else bytes = loaded
    }

    val data = bytes
    when {
        failed -> Text(
            "Attachment unavailable",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error,
        )

        data == null -> Box(
            Modifier
                .fillMaxWidth()
                .height(110.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(Color.Black.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) { CircularProgressIndicator(Modifier.size(22.dp)) }

        attachment.contentType.startsWith("image/") -> ImageAttachment(attachment, data)
        attachment.contentType.startsWith("video/") -> VideoAttachment(attachment, data)
        attachment.contentType.startsWith("audio/") -> AudioAttachment(attachment, data, onBlack)
        else -> FileAttachment(attachment, data, onBlack)
    }
}

@Composable
private fun ImageAttachment(attachment: StoredAttachment, bytes: ByteArray) {
    val bitmap = remember(attachment.id) { bytes.decode() }
    if (bitmap == null) {
        FileAttachment(attachment, bytes, onBlack = false)
        return
    }
    Image(
        bitmap = bitmap,
        contentDescription = attachment.filename ?: "Photo",
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)),
        contentScale = ContentScale.FillWidth,
    )
}

/**
 * A video: its first frame, with a play badge.
 *
 * Playing it hands the decrypted bytes to the system player through a
 * FileProvider, rather than embedding one — the plaintext has to touch the
 * filesystem either way for any player to read it, and the app's own cache
 * directory is the narrowest place to put it.
 */
@Composable
private fun VideoAttachment(attachment: StoredAttachment, bytes: ByteArray) {
    val context = LocalContext.current
    var thumbnail by remember(attachment.id) { mutableStateOf<ImageBitmap?>(null) }

    LaunchedEffect(attachment.id) {
        thumbnail = withContext(Dispatchers.IO) { videoThumbnail(context, attachment, bytes) }
    }

    Box(
        Modifier
            .fillMaxWidth()
            .height(180.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.Black)
            .clickable { openExternally(context, attachment, bytes) },
        contentAlignment = Alignment.Center,
    ) {
        thumbnail?.let {
            Image(
                bitmap = it,
                contentDescription = attachment.filename ?: "Video",
                modifier = Modifier.fillMaxWidth(),
                contentScale = ContentScale.Crop,
            )
        }
        Box(
            Modifier.size(48.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.55f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Filled.PlayArrow,
                contentDescription = "Play",
                tint = Color.White,
                modifier = Modifier.size(28.dp),
            )
        }
    }
}

/** Audio, played in place. Voice notes arrive here too. */
@Composable
private fun AudioAttachment(attachment: StoredAttachment, bytes: ByteArray, onBlack: Boolean) {
    val context = LocalContext.current
    val ink = if (onBlack) Color.White else MaterialTheme.colorScheme.onSurface
    var playing by remember(attachment.id) { mutableStateOf(false) }
    var progress by remember(attachment.id) { androidx.compose.runtime.mutableFloatStateOf(0f) }

    val player = remember(attachment.id) { android.media.MediaPlayer() }
    DisposableEffect(attachment.id) {
        onDispose { runCatching { player.release() } }
    }

    // Ticks the bar while playing. Stops as soon as playback does, so a paused
    // clip does not keep a coroutine alive.
    LaunchedEffect(playing) {
        while (playing) {
            progress = runCatching {
                if (player.duration > 0) player.currentPosition.toFloat() / player.duration else 0f
            }.getOrDefault(0f)
            delay(200)
        }
    }

    Row(
        Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(38.dp)
                .clip(CircleShape)
                .background(ink.copy(alpha = 0.18f))
                .clickable {
                    if (playing) {
                        runCatching { player.pause() }
                        playing = false
                    } else {
                        runCatching {
                            if (player.duration <= 0) {
                                player.setDataSource(cacheFile(context, attachment, bytes).path)
                                player.prepare()
                            }
                            player.setOnCompletionListener { playing = false; progress = 0f }
                            player.start()
                            playing = true
                        }
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                contentDescription = if (playing) "Pause" else "Play",
                tint = ink,
                modifier = Modifier.size(22.dp),
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            LinearProgressIndicator(
                progress = { progress },
                modifier = Modifier.fillMaxWidth(),
                color = ink,
                trackColor = ink.copy(alpha = 0.22f),
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = attachment.filename ?: "Audio",
                style = MaterialTheme.typography.labelSmall,
                color = ink.copy(alpha = 0.75f),
            )
        }
    }
}

@Composable
private fun FileAttachment(attachment: StoredAttachment, bytes: ByteArray, onBlack: Boolean) {
    val context = LocalContext.current
    val ink = if (onBlack) Color.White else MaterialTheme.colorScheme.onSurface
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .clickable { openExternally(context, attachment, bytes) }
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.AutoMirrored.Filled.InsertDriveFile,
            contentDescription = null,
            tint = ink,
            modifier = Modifier.size(28.dp),
        )
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                text = attachment.filename ?: "File",
                style = MaterialTheme.typography.bodyMedium,
                color = ink,
                maxLines = 1,
            )
            Text(
                // The stored size is the ciphertext's; the plaintext is what
                // the user is about to open, so that is what is shown.
                text = bytes.size.asFileSize(),
                style = MaterialTheme.typography.labelSmall,
                color = ink.copy(alpha = 0.7f),
            )
        }
    }
}

private fun ByteArray.decode(): ImageBitmap? = runCatching {
    android.graphics.BitmapFactory.decodeByteArray(this, 0, size)?.asImageBitmap()
}.getOrNull()

private fun Int.asFileSize(): String = when {
    this < 1024 -> "$this B"
    this < 1024 * 1024 -> "%.0f KB".format(this / 1024f)
    else -> "%.1f MB".format(this / (1024f * 1024f))
}

/**
 * Writes the plaintext to the app's cache so another app can open it.
 *
 * Unavoidable: no external player reads from memory. It lives in the app's own
 * cache directory, shared one file at a time through a FileProvider grant, and
 * the OS reclaims it — which is a far smaller exposure than the Downloads
 * folder a naive "save" would use.
 */
private fun cacheFile(
    context: android.content.Context,
    attachment: StoredAttachment,
    bytes: ByteArray,
): File {
    val directory = File(context.cacheDir, "attachments").apply { mkdirs() }
    // The blob id is relay-supplied, so it is sanitised before it becomes a
    // filename — a traversal here would write outside the cache.
    val safe = attachment.id.filter { it.isLetterOrDigit() || it == '-' || it == '_' }.take(64)
    return File(directory, safe).apply { if (!exists() || length() != bytes.size.toLong()) writeBytes(bytes) }
}

private fun openExternally(
    context: android.content.Context,
    attachment: StoredAttachment,
    bytes: ByteArray,
) {
    runCatching {
        val file = cacheFile(context, attachment, bytes)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        context.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, attachment.contentType)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}

private fun videoThumbnail(
    context: android.content.Context,
    attachment: StoredAttachment,
    bytes: ByteArray,
): ImageBitmap? = runCatching {
    val retriever = android.media.MediaMetadataRetriever()
    retriever.use {
        it.setDataSource(cacheFile(context, attachment, bytes).path)
        it.getFrameAtTime(0)?.asImageBitmap()
    }
}.getOrNull()
