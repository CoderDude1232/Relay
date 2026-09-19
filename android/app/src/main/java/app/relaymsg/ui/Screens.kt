package app.relaymsg.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.material3.FloatingActionButton
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontStyle
import app.relaymsg.ui.theme.Magenta
import app.relaymsg.ui.theme.MagentaDeep
import app.relaymsg.core.ConnectionState
import app.relaymsg.storage.Conversation
import app.relaymsg.storage.MessageStatus
import app.relaymsg.storage.StoredMessage
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

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
                        modifier = Modifier.padding(end = 4.dp),
                    )
                },
            )
        },
        floatingActionButton = {
            if (!showNewChat) {
                FloatingActionButton(
                    onClick = { showNewChat = true },
                    containerColor = MaterialTheme.colorScheme.primary,
                    contentColor = MaterialTheme.colorScheme.onPrimary,
                ) {
                    Icon(Icons.Filled.Add, contentDescription = "New conversation")
                }
            }
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            Text(
                "Signed in as $username",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
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
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.padding(horizontal = 40.dp),
                    ) {
                        Text(
                            "No conversations yet",
                            style = MaterialTheme.typography.titleLarge,
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                            "Messages are encrypted before they leave this phone, " +
                                "and deleted from the relay the moment they arrive.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center,
                        )
                        Spacer(Modifier.height(20.dp))
                        Button(onClick = { showNewChat = true }) { Text("Start a conversation") }
                    }
                }
            } else {
                LazyColumn(Modifier.fillMaxSize()) {
                    items(conversations, key = { it.id }) { conversation ->
                        ConversationRow(conversation, titleFor(conversation)) { onOpen(conversation.id) }
                    }
                    item { Spacer(Modifier.height(88.dp)) } // clearance for the FAB
                }
            }
        }
    }
}

@Composable
private fun ConversationRow(conversation: Conversation, title: String, onClick: () -> Unit) {
    val unread = conversation.unreadCount > 0
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Avatar(id = conversation.peerAccount, name = title)
        Spacer(Modifier.width(14.dp))

        Column(Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                // An unread thread leans on weight rather than colour, so it
                // still reads as unread to anyone who cannot see the accent.
                fontWeight = if (unread) FontWeight.Bold else FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                text = conversation.preview(),
                style = MaterialTheme.typography.bodyMedium,
                color = if (unread) {
                    MaterialTheme.colorScheme.onSurface
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        Spacer(Modifier.width(12.dp))
        Column(horizontalAlignment = Alignment.End) {
            conversation.lastMessageAt?.let { at ->
                Text(
                    text = at.asListTime(),
                    style = MaterialTheme.typography.labelSmall,
                    color = if (unread) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
            }
            if (unread) {
                Spacer(Modifier.height(6.dp))
                Box(
                    Modifier
                        .background(MaterialTheme.colorScheme.primary, CircleShape)
                        .defaultMinSize(minWidth = 20.dp, minHeight = 20.dp)
                        .padding(horizontal = 6.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        // A four-digit badge would stretch the row; nobody needs
                        // the exact number past a hundred.
                        text = if (conversation.unreadCount > 99) "99+" else "${conversation.unreadCount}",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onPrimary,
                    )
                }
            }
        }
    }
}

/** "You: …" for our own last message, so a thread reads without opening it. */
private fun Conversation.preview(): String {
    val body = lastMessageBody?.takeIf { it.isNotBlank() } ?: return "No messages yet"
    return if (lastMessageIsOutgoing) "You: $body" else body
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
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                items(messages, key = { it.id }) { MessageBubble(it, loadAttachment) }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 8.dp),
                verticalAlignment = Alignment.Bottom,
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
                ) {
                    Icon(
                        Icons.Filled.Add,
                        contentDescription = "Attach image",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                // A pill rather than an outlined field: it reads as a composer
                // instead of a form, and it grows with the draft.
                TextField(
                    value = draft,
                    onValueChange = { draft = it },
                    placeholder = { Text("Message") },
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(22.dp)),
                    maxLines = 5,
                    textStyle = MaterialTheme.typography.bodyLarge,
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                        unfocusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                        // The underline is what makes a TextField look like a
                        // form control; a pill does not want one.
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent,
                        disabledIndicatorColor = Color.Transparent,
                    ),
                )
                Spacer(Modifier.width(6.dp))
                val canSend = draft.isNotBlank()
                IconButton(
                    enabled = canSend,
                    onClick = { onSend(draft.trim()); draft = "" },
                    modifier = Modifier
                        .size(46.dp)
                        .background(
                            // Dimmed rather than hidden, so the target does not
                            // move as you type the first character.
                            if (canSend) {
                                MaterialTheme.colorScheme.primary
                            } else {
                                MaterialTheme.colorScheme.surfaceVariant
                            },
                            CircleShape,
                        ),
                ) {
                    Icon(
                        Icons.AutoMirrored.Filled.Send,
                        contentDescription = "Send",
                        tint = if (canSend) {
                            MaterialTheme.colorScheme.onPrimary
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                        modifier = Modifier.size(20.dp),
                    )
                }
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
    // Deep -> band, not the logo's full gradient: white on the bright stop is
    // only 3.0:1. Along this run it never drops below 4.7:1.
    val outgoingFill = Brush.linearGradient(listOf(MagentaDeep, Magenta))
    val incomingFill = SolidColor(MaterialTheme.colorScheme.surfaceVariant)

    // The corner nearest the sender is squared off. It is what gives a thread a
    // direction at a glance, without drawing tails.
    val shape = RoundedCornerShape(
        topStart = 18.dp,
        topEnd = 18.dp,
        bottomStart = if (outgoing) 18.dp else 4.dp,
        bottomEnd = if (outgoing) 4.dp else 18.dp,
    )
    val ink = if (outgoing) Color.White else MaterialTheme.colorScheme.onSurface
    val meta = if (outgoing) Color.White.copy(alpha = 0.75f) else MaterialTheme.colorScheme.onSurfaceVariant

    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = if (outgoing) Arrangement.End else Arrangement.Start,
    ) {
        Column(
            Modifier
                .widthIn(max = 300.dp)
                .clip(shape)
                .background(if (outgoing) outgoingFill else incomingFill)
                .padding(horizontal = 14.dp, vertical = 9.dp),
        ) {
            message.replyTo?.let { quote ->
                // A rule down the side, the way a pull-quote is marked, so the
                // quoted text is not mistaken for part of the message.
                Row(
                    Modifier
                        .padding(bottom = 6.dp)
                        .background(
                            if (outgoing) Color.White.copy(alpha = 0.16f)
                            else MaterialTheme.colorScheme.surface,
                            RoundedCornerShape(8.dp),
                        )
                        .height(IntrinsicSize.Min),
                ) {
                    Box(
                        Modifier
                            .width(3.dp)
                            .fillMaxHeight()
                            .background(if (outgoing) Color.White else MaterialTheme.colorScheme.primary),
                    )
                    Text(
                        quote.text.take(80),
                        style = MaterialTheme.typography.bodySmall,
                        color = meta,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 5.dp),
                    )
                }
            }
            message.attachments.forEach { attachment ->
                AttachmentImage(attachment, loadAttachment)
                Spacer(Modifier.height(4.dp))
            }
            if (message.body.isNotEmpty() || message.isDeleted) {
                Text(
                    text = if (message.isDeleted) "This message was deleted" else message.body,
                    style = MaterialTheme.typography.bodyLarge,
                    color = if (message.isDeleted) meta else ink,
                    fontStyle = if (message.isDeleted) FontStyle.Italic else FontStyle.Normal,
                )
            }
            // Metadata sits under the text and to the trailing edge, so it never
            // competes with the message itself.
            Row(
                Modifier.align(Alignment.End).padding(top = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    buildString {
                        append(message.timestamp.asClockTime())
                        if (message.editedAt != null) append(" · edited")
                        if (outgoing) {
                            message.status.indicator().takeIf { it.isNotEmpty() }
                                ?.let { append(" · ").append(it) }
                        }
                    },
                    style = MaterialTheme.typography.labelSmall,
                    color = if (message.status == MessageStatus.FAILED) {
                        MaterialTheme.colorScheme.error
                    } else {
                        meta
                    },
                )
            }
            if (message.reactions.isNotEmpty()) {
                Box(
                    Modifier
                        .padding(top = 4.dp)
                        .background(
                            if (outgoing) Color.White.copy(alpha = 0.18f)
                            else MaterialTheme.colorScheme.surface,
                            CircleShape,
                        )
                        .padding(horizontal = 7.dp, vertical = 3.dp),
                ) {
                    Text(
                        message.reactions.joinToString(" ") { it.emoji },
                        style = MaterialTheme.typography.labelMedium,
                    )
                }
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
private val weekdayFormat = SimpleDateFormat("EEE", Locale.getDefault())
private val dateFormat = SimpleDateFormat("d MMM", Locale.getDefault())

private fun Long.asClockTime(): String = clockFormat.format(Date(this))

/**
 * A conversation-list timestamp: the clock today, a weekday this week, a date
 * before that.
 *
 * Compared by calendar day rather than by elapsed milliseconds — a message sent
 * at 23:58 is "yesterday" at 00:02, not "two minutes ago".
 */
private fun Long.asListTime(): String {
    val now = Calendar.getInstance()
    val then = Calendar.getInstance().apply { timeInMillis = this@asListTime }

    fun sameDay(a: Calendar, b: Calendar) =
        a.get(Calendar.ERA) == b.get(Calendar.ERA) &&
            a.get(Calendar.YEAR) == b.get(Calendar.YEAR) &&
            a.get(Calendar.DAY_OF_YEAR) == b.get(Calendar.DAY_OF_YEAR)

    val yesterday = (now.clone() as Calendar).apply { add(Calendar.DAY_OF_YEAR, -1) }
    val weekAgo = (now.clone() as Calendar).apply { add(Calendar.DAY_OF_YEAR, -6) }

    return when {
        sameDay(then, now) -> clockFormat.format(Date(this))
        sameDay(then, yesterday) -> "Yesterday"
        then.after(weekAgo) -> weekdayFormat.format(Date(this))
        else -> dateFormat.format(Date(this))
    }
}
