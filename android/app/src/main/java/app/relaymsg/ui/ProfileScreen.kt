package app.relaymsg.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/**
 * Your own profile, as your contacts see it.
 *
 * Nothing here reaches the relay in the clear: the name and the picture travel
 * as an ordinary end-to-end encrypted message to each peer, and the avatar goes
 * through the same sealed blob pipeline an attachment does.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileScreen(
    accountId: String,
    username: String,
    displayName: String,
    avatar: ByteArray?,
    status: String,
    bio: String,
    busy: Boolean,
    onPickAvatar: () -> Unit,
    onSave: (displayName: String, avatar: ByteArray?, status: String, bio: String) -> Unit,
    onBack: () -> Unit,
) {
    var name by remember(displayName) { mutableStateOf(displayName) }
    var statusText by remember(status) { mutableStateOf(status) }
    var bioText by remember(bio) { mutableStateOf(bio) }
    val bitmap = remember(avatar) {
        avatar?.let {
            runCatching {
                android.graphics.BitmapFactory.decodeByteArray(it, 0, it.size)?.asImageBitmap()
            }.getOrNull()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Profile") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    TextButton(
                        enabled = !busy,
                        onClick = { onSave(name.trim(), avatar, statusText.trim(), bioText.trim()) },
                    ) {
                        if (busy) CircularProgressIndicator(Modifier.height(18.dp)) else Text("Save")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(
                Modifier.size(112.dp).clip(CircleShape).clickable(onClick = onPickAvatar),
                contentAlignment = Alignment.Center,
            ) {
                if (bitmap != null) {
                    Image(
                        bitmap = bitmap,
                        contentDescription = "Profile photo",
                        modifier = Modifier.fillMaxSize(),
                        contentScale = ContentScale.Crop,
                    )
                } else {
                    Avatar(id = accountId, name = name.ifEmpty { username }, size = 112.dp)
                }
            }
            TextButton(onClick = onPickAvatar, enabled = !busy) {
                Text(if (avatar == null) "Add photo" else "Change photo")
            }
            if (avatar != null) {
                TextButton(
                    onClick = { onSave(name.trim(), null, statusText.trim(), bioText.trim()) },
                    enabled = !busy,
                ) {
                    Text("Remove photo", color = MaterialTheme.colorScheme.error)
                }
            }

            Spacer(Modifier.height(16.dp))
            OutlinedTextField(
                value = name,
                onValueChange = { name = it.take(64) },
                label = { Text("Display name") },
                singleLine = true,
                enabled = !busy,
                supportingText = {
                    Text("Shown to people you message. Your username stays @$username.")
                },
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = statusText,
                onValueChange = { statusText = it.take(64) },
                label = { Text("Status") },
                singleLine = true,
                enabled = !busy,
                supportingText = { Text("A short line under your name.") },
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = bioText,
                onValueChange = { bioText = it.take(500) },
                label = { Text("Bio") },
                minLines = 3,
                enabled = !busy,
                supportingText = {
                    // Said here rather than nowhere: a profile field that is
                    // pushed to every contact is not the same as one sitting on
                    // a server, and the difference is worth knowing before
                    // typing into it.
                    Text(
                        "Encrypted and sent to people you message — the relay " +
                            "never sees it.",
                    )
                },
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(24.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                Text(
                    "Your name and photo are sent encrypted to each contact " +
                        "individually. The relay never sees either.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}
