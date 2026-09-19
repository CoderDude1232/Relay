package app.relaymsg.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.relaymsg.storage.StoredAttachment

/**
 * Everything shared in one conversation, newest first.
 *
 * Thumbnails decrypt on demand as tiles scroll into view, rather than all at
 * once: a long conversation can hold hundreds of attachments, and decrypting
 * them eagerly would mean holding every photo in memory to show twelve.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MediaGalleryScreen(
    title: String,
    attachments: List<StoredAttachment>,
    load: suspend (StoredAttachment) -> ByteArray?,
    onBack: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Media in $title") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        if (attachments.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.padding(horizontal = 40.dp),
                ) {
                    Text("Nothing shared yet", style = MaterialTheme.typography.titleLarge)
                    Spacer(Modifier.size(6.dp))
                    Text(
                        "Photos, files and voice notes in this conversation " +
                            "will collect here.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                }
            }
            return@Scaffold
        }

        LazyVerticalGrid(
            columns = GridCells.Adaptive(108.dp),
            modifier = Modifier.fillMaxSize().padding(padding),
        ) {
            items(attachments, key = { it.id }) { attachment ->
                GalleryTile(attachment, load)
            }
        }
    }
}

@Composable
private fun GalleryTile(attachment: StoredAttachment, load: suspend (StoredAttachment) -> ByteArray?) {
    val isImage = attachment.contentType.startsWith("image/")
    var thumbnail by remember(attachment.id) { mutableStateOf<ImageBitmap?>(null) }

    LaunchedEffect(attachment.id) {
        // Only images decode to a thumbnail; a video would need a frame
        // extracted, which costs a temp file per tile.
        if (isImage) {
            thumbnail = load(attachment)?.let { bytes ->
                runCatching {
                    android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                        ?.asImageBitmap()
                }.getOrNull()
            }
        }
    }

    Box(
        Modifier
            .padding(1.dp)
            .aspectRatio(1f)
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .clickable { },
        contentAlignment = Alignment.Center,
    ) {
        val bitmap = thumbnail
        when {
            bitmap != null -> Image(
                bitmap = bitmap,
                contentDescription = attachment.filename,
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
            attachment.contentType.startsWith("video/") ->
                TileIcon(Icons.Filled.PlayArrow, "Video")
            attachment.contentType.startsWith("audio/") ->
                TileIcon(Icons.Filled.VolumeUp, "Voice note")
            isImage -> Unit // still decrypting
            else -> TileIcon(Icons.AutoMirrored.Filled.InsertDriveFile, attachment.filename ?: "File")
        }
    }
}

@Composable
private fun TileIcon(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(
            icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(28.dp),
        )
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            maxLines = 2,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 4.dp),
        )
    }
}
