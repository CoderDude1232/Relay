package app.relaymsg.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * A shared scratchpad for one conversation.
 *
 * Not a separate channel: saving sends an ordinary encrypted message carrying a
 * marker, so the relay cannot tell it from chat and the newest revision simply
 * wins. That also means saving is a *send* — it goes to the other person, and
 * the screen says so rather than implying a private note.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NotepadScreen(
    title: String,
    initialContent: String,
    busy: Boolean,
    onSave: (String) -> Unit,
    onBack: () -> Unit,
) {
    var content by remember(initialContent) { mutableStateOf(initialContent) }
    val changed = content != initialContent

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Shared notes") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    TextButton(enabled = changed && !busy, onClick = { onSave(content) }) {
                        if (busy) CircularProgressIndicator(Modifier.height(18.dp)) else Text("Save")
                    }
                },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding()) {
            Text(
                "Shared with $title. Saving sends the new version to them, " +
                    "encrypted like any other message.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
            )
            OutlinedTextField(
                value = content,
                onValueChange = { content = it },
                placeholder = { Text("Anything you both need to hand…") },
                modifier = Modifier.fillMaxWidth().weight(1f).padding(horizontal = 16.dp),
            )
        }
    }
}
