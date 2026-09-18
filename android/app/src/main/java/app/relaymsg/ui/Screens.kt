package app.relaymsg.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import app.relaymsg.core.ConnectionState
import app.relaymsg.storage.Conversation
import app.relaymsg.storage.MessageStatus
import app.relaymsg.storage.StoredMessage
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// ---------------------------------------------------------------- onboarding

@Composable
fun OnboardingScreen(
    busy: Boolean,
    error: String?,
    onRegister: (String) -> Unit,
) {
    var username by remember { mutableStateOf("") }
    // The relay enforces this exact charset; rejecting locally avoids a
    // round-trip to be told the same thing.
    val valid = username.matches(Regex("^[a-zA-Z0-9._\\-]{1,64}$"))

    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp).imePadding(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Relay", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text(
            "Choose a username to get started.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(24.dp))
        OutlinedTextField(
            value = username,
            onValueChange = { username = it },
            label = { Text("Username") },
            singleLine = true,
            enabled = !busy,
            supportingText = { Text("Letters, numbers, dots, underscores and hyphens.") },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { if (valid) onRegister(username) }),
            modifier = Modifier.fillMaxWidth(),
        )
        if (error != null) {
            Spacer(Modifier.height(8.dp))
            Text(error, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
        }
        Spacer(Modifier.height(16.dp))
        Button(
            onClick = { onRegister(username) },
            enabled = valid && !busy,
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (busy) CircularProgressIndicator(Modifier.height(18.dp)) else Text("Create account")
        }
    }
}

// --------------------------------------------------------- conversation list

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConversationListScreen(
    username: String,
    connection: ConnectionState,
    conversations: List<Conversation>,
    titleFor: (Conversation) -> String,
    busy: Boolean,
    onOpen: (String) -> Unit,
    onStartConversation: (String, (String) -> Unit, (String) -> Unit) -> Unit,
) {
    var showNewChat by remember { mutableStateOf(false) }
    var newChatName by remember { mutableStateOf("") }
    var newChatError by remember { mutableStateOf<String?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Relay") },
                actions = {
                    Text(
                        text = connection.label(),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(end = 12.dp),
                    )
                },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            Text(
                "Signed in as $username",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            )

            if (showNewChat) {
                Column(Modifier.padding(horizontal = 16.dp)) {
                    OutlinedTextField(
                        value = newChatName,
                        onValueChange = { newChatName = it; newChatError = null },
                        label = { Text("Username to message") },
                        singleLine = true,
                        isError = newChatError != null,
                        supportingText = newChatError?.let { { Text(it) } },
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
                        TextButton(onClick = { showNewChat = false; newChatError = null }) {
                            Text("Cancel")
                        }
                        TextButton(
                            enabled = newChatName.isNotBlank() && !busy,
                            onClick = {
                                onStartConversation(
                                    newChatName,
                                    { id -> showNewChat = false; newChatName = ""; onOpen(id) },
                                    { message -> newChatError = message },
                                )
                            },
                        ) { Text("Start") }
                    }
                }
                HorizontalDivider()
            }

            if (conversations.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("No conversations yet", style = MaterialTheme.typography.bodyLarge)
                        Spacer(Modifier.height(8.dp))
                        TextButton(onClick = { showNewChat = true }) { Text("Start one") }
                    }
                }
            } else {
                LazyColumn(Modifier.fillMaxSize()) {
                    items(conversations, key = { it.id }) { conversation ->
                        ConversationRow(conversation, titleFor(conversation)) { onOpen(conversation.id) }
                        HorizontalDivider()
                    }
                    item {
                        TextButton(
                            onClick = { showNewChat = true },
                            modifier = Modifier.fillMaxWidth().padding(8.dp),
                        ) { Text("New conversation") }
                    }
                }
            }
        }
    }
}

@Composable
private fun ConversationRow(conversation: Conversation, title: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            conversation.lastMessageBody?.let {
                Text(
                    it.take(80),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        if (conversation.unreadCount > 0) {
            Box(
                Modifier
                    .background(MaterialTheme.colorScheme.primary, RoundedCornerShape(12.dp))
                    .padding(horizontal = 8.dp, vertical = 2.dp),
            ) {
                Text(
                    conversation.unreadCount.toString(),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onPrimary,
                )
            }
        }
    }
}

// ---------------------------------------------------------------------- chat

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(
    title: String,
    messages: List<StoredMessage>,
    onSend: (String) -> Unit,
    onBack: () -> Unit,
) {
    var draft by remember { mutableStateOf("") }
    val listState = rememberLazyListState()

    // Keep the newest message in view as they arrive.
    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.lastIndex)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding()) {
            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f).fillMaxWidth(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(12.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                items(messages, key = { it.id }) { MessageBubble(it) }
            }
            HorizontalDivider()
            Row(
                Modifier.fillMaxWidth().padding(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    placeholder = { Text("Message") },
                    modifier = Modifier.weight(1f),
                    maxLines = 4,
                )
                TextButton(
                    enabled = draft.isNotBlank(),
                    onClick = { onSend(draft.trim()); draft = "" },
                ) { Text("Send") }
            }
        }
    }
}

@Composable
private fun MessageBubble(message: StoredMessage) {
    val outgoing = message.isOutgoing
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = if (outgoing) Arrangement.End else Arrangement.Start,
    ) {
        Column(
            Modifier
                .widthIn(max = 280.dp)
                .background(
                    if (outgoing) MaterialTheme.colorScheme.primaryContainer
                    else MaterialTheme.colorScheme.surfaceVariant,
                    RoundedCornerShape(16.dp),
                )
                .padding(horizontal = 12.dp, vertical = 8.dp),
        ) {
            message.replyTo?.let { quote ->
                Text(
                    quote.text.take(60),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(2.dp))
            }
            Text(
                if (message.isDeleted) "This message was deleted" else message.body,
                style = MaterialTheme.typography.bodyLarge,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    message.timestamp.asClockTime(),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (message.editedAt != null) {
                    Text(
                        " · edited",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                if (outgoing) {
                    Text(
                        " · ${message.status.indicator()}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (message.reactions.isNotEmpty()) {
                Text(
                    message.reactions.joinToString(" ") { it.emoji },
                    style = MaterialTheme.typography.labelMedium,
                )
            }
        }
    }
}

// ------------------------------------------------------------------ helpers

private fun ConnectionState.label(): String = when (this) {
    ConnectionState.CONNECTED -> "Connected"
    ConnectionState.CONNECTING -> "Connecting…"
    ConnectionState.DISCONNECTED -> "Offline"
}

/**
 * The delivery indicator. "Sent" means the relay accepted it; "Delivered" means
 * the recipient's device decrypted it and sent a receipt back — so a message
 * stuck on "Sent" is a genuine signal that it never opened on the other side.
 */
private fun MessageStatus.indicator(): String = when (this) {
    MessageStatus.SENDING -> "Sending…"
    MessageStatus.SENT -> "Sent"
    MessageStatus.DELIVERED -> "Delivered"
    MessageStatus.READ -> "Read"
    MessageStatus.FAILED -> "Failed"
    MessageStatus.RECEIVED -> ""
}

private val clockFormat = SimpleDateFormat("HH:mm", Locale.getDefault())

private fun Long.asClockTime(): String = clockFormat.format(Date(this))
