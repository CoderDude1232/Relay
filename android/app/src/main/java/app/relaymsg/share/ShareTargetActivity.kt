package app.relaymsg.share

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.relaymsg.core.RelayService
import app.relaymsg.push.RelayRuntime
import app.relaymsg.storage.Conversation
import app.relaymsg.ui.Avatar
import app.relaymsg.ui.theme.RelayTheme
import kotlinx.coroutines.launch

/**
 * Android's answer to the iOS Share Extension.
 *
 * Shares arrive here from any app. Unlike iOS there is no separate process and
 * no App Group hand-off: this activity runs inside the app, so it can open the
 * encrypted store directly and send immediately rather than parking a
 * `PendingShare` for the main app to pick up later.
 */
class ShareTargetActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val text = intent?.getStringExtra(Intent.EXTRA_TEXT)
        val streams = intent?.streams()
        if (text.isNullOrBlank() && streams.isNullOrEmpty()) {
            finish()
            return
        }

        setContent {
            RelayTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    val service by produceState<RelayService?>(null) {
                        value = RelayRuntime.require(this@ShareTargetActivity)
                    }
                    val relay = service
                    if (relay == null) {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator()
                        }
                    } else {
                        // Pre-selected by a Direct Share shortcut, if the user
                        // picked a conversation straight from the share sheet.
                        val preselected = intent?.getStringExtra(Intent.EXTRA_SHORTCUT_ID)
                        if (preselected != null) {
                            SendAndFinish(relay, preselected, text, streams)
                        } else {
                            ChooseConversation(relay) { conversationId ->
                                send(relay, conversationId, text, streams)
                            }
                        }
                    }
                }
            }
        }
    }

    @Composable
    private fun SendAndFinish(
        relay: RelayService,
        conversationId: String,
        text: String?,
        streams: List<Uri>?,
    ) {
        androidx.compose.runtime.LaunchedEffect(conversationId) {
            send(relay, conversationId, text, streams)
        }
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator()
        }
    }

    private fun send(
        relay: RelayService,
        conversationId: String,
        text: String?,
        streams: List<Uri>?,
    ) {
        // Finishes immediately and sends in the background: a share sheet that
        // sits there spinning is worse than one that gets out of the way, and
        // the message appears in the conversation either way.
        Toast.makeText(this, "Sending…", Toast.LENGTH_SHORT).show()
        RelayRuntime.scope.launch {
            streams?.forEach { uri ->
                runCatching { relay.sendSharedFile(applicationContext, conversationId, uri) }
            }
            if (!text.isNullOrBlank()) {
                runCatching { relay.sendText(conversationId, text.trim()) }
            }
        }
        finish()
    }

    /** `ACTION_SEND` carries one stream, `ACTION_SEND_MULTIPLE` a list. */
    private fun Intent.streams(): List<Uri> = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> when (action) {
            Intent.ACTION_SEND_MULTIPLE ->
                getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
            else -> listOfNotNull(getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java))
        }
        else -> @Suppress("DEPRECATION") when (action) {
            Intent.ACTION_SEND_MULTIPLE ->
                getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
            else -> listOfNotNull(getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChooseConversation(relay: RelayService, onPick: (String) -> Unit) {
    val conversations by relay.conversations.collectAsState()

    Scaffold(topBar = { TopAppBar(title = { Text("Share with") }) }) { padding ->
        if (conversations.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Text(
                    "No conversations yet",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            return@Scaffold
        }
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            items(conversations, key = { it.id }) { conversation ->
                ShareRow(conversation, relay.conversationTitle(conversation)) {
                    onPick(conversation.id)
                }
            }
        }
    }
}

@Composable
private fun ShareRow(conversation: Conversation, title: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Avatar(id = conversation.peerAccount, name = title, size = 44.dp)
        Spacer(Modifier.width(14.dp))
        Column {
            Text(title, style = MaterialTheme.typography.bodyLarge)
        }
    }
}
