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
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Videocam
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
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
    onLinkDevice: () -> Unit,
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
        Spacer(Modifier.height(24.dp))
        // The other way in: join an account that already exists on another phone,
        // rather than creating a second, separate identity.
        TextButton(onClick = onLinkDevice, enabled = !busy) {
            Text("Already have Relay on another device?")
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
    onShowCalls: () -> Unit,
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
                        modifier = Modifier.padding(end = 4.dp),
                    )
                    IconButton(onClick = onShowCalls) {
                        Icon(Icons.Filled.Call, contentDescription = "Calls")
                    }
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
    onSendImage: (android.net.Uri) -> Unit,
    loadAttachment: suspend (app.relaymsg.storage.StoredAttachment) -> ByteArray?,
    onBack: () -> Unit,
    /** Places a call; `true` for video. Null hides the buttons — groups have no calls yet. */
    onCall: ((Boolean) -> Unit)? = null,
) {
    val pickImage = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia(),
    ) { uri -> uri?.let(onSendImage) }
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
                actions = {
                    onCall?.let { call ->
                        IconButton(onClick = { call(true) }) {
                            Icon(Icons.Filled.Videocam, contentDescription = "Video call")
                        }
                        IconButton(onClick = { call(false) }) {
                            Icon(Icons.Filled.Call, contentDescription = "Call")
                        }
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
                items(messages, key = { it.id }) { MessageBubble(it, loadAttachment) }
            }
            HorizontalDivider()
            Row(
                Modifier.fillMaxWidth().padding(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(
                    onClick = {
                        pickImage.launch(
                            androidx.activity.result.PickVisualMediaRequest(
                                androidx.activity.result.contract.ActivityResultContracts
                                    .PickVisualMedia.ImageOnly,
                            ),
                        )
                    },
                ) { Icon(Icons.Filled.Add, contentDescription = "Attach image") }
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
private fun MessageBubble(
    message: StoredMessage,
    loadAttachment: suspend (app.relaymsg.storage.StoredAttachment) -> ByteArray?,
) {
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
            message.attachments.forEach { attachment ->
                AttachmentImage(attachment, loadAttachment)
                Spacer(Modifier.height(4.dp))
            }
            if (message.body.isNotEmpty() || message.isDeleted) {
                Text(
                    if (message.isDeleted) "This message was deleted" else message.body,
                    style = MaterialTheme.typography.bodyLarge,
                )
            }
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

/**
 * Renders an attachment once it has been fetched and decrypted.
 *
 * Decryption happens per-attachment and off the main thread; until it completes
 * (or if the digest check fails) a placeholder stands in rather than an empty gap.
 */
@Composable
private fun AttachmentImage(
    attachment: app.relaymsg.storage.StoredAttachment,
    loadAttachment: suspend (app.relaymsg.storage.StoredAttachment) -> ByteArray?,
) {
    var bitmap by remember(attachment.id) {
        mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null)
    }
    var failed by remember(attachment.id) { mutableStateOf(false) }

    LaunchedEffect(attachment.id) {
        val bytes = loadAttachment(attachment)
        if (bytes == null) {
            failed = true
        } else {
            bitmap = android.graphics.BitmapFactory
                .decodeByteArray(bytes, 0, bytes.size)
                ?.asImageBitmap()
            if (bitmap == null) failed = true
        }
    }

    val image = bitmap
    when {
        image != null -> androidx.compose.foundation.Image(
            bitmap = image,
            contentDescription = attachment.filename ?: "Attachment",
            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)),
            contentScale = androidx.compose.ui.layout.ContentScale.FillWidth,
        )
        failed -> Text(
            "Attachment unavailable",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error,
        )
        else -> Box(
            Modifier.fillMaxWidth().height(120.dp)
                .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(12.dp)),
            contentAlignment = Alignment.Center,
        ) { CircularProgressIndicator(Modifier.height(20.dp)) }
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
