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
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.EmojiEmotions
import androidx.compose.material.icons.filled.FormatBold
import androidx.compose.material.icons.filled.FormatItalic
import androidx.compose.material.icons.filled.StrikethroughS
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.filled.Poll
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.MarkEmailUnread
import androidx.compose.material3.Switch
import app.relaymsg.core.PollPayload
import app.relaymsg.storage.StoredPollVote
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarOutline
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.unit.sp
import app.relaymsg.storage.QuotedMessage
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
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
import app.relaymsg.core.LocationPayload
import app.relaymsg.core.RelayService
import app.relaymsg.storage.Conversation
import app.relaymsg.storage.MessageStatus
import app.relaymsg.storage.SearchResult
import app.relaymsg.storage.StoredMessage
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

// --------------------------------------------------------- conversation list

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConversationListScreen(
    connection: ConnectionState,
    conversations: List<Conversation>,
    titleFor: (Conversation) -> String,
    busy: Boolean,
    onOpen: (String) -> Unit,
    onStartConversation: (String, (String) -> Unit, (String) -> Unit) -> Unit,
    onPin: (id: String, pinned: Boolean) -> Unit,
    onArchive: (id: String, archived: Boolean) -> Unit,
    onMarkUnread: (id: String) -> Unit,
    onDelete: (id: String) -> Unit,
    panicEnabled: Boolean,
    hiddenConversations: Set<String>,
    onToggleHidden: (id: String, hidden: Boolean) -> Unit,
    searchResults: List<SearchResult>,
    onSearch: (String) -> Unit,
) {
    var showNewChat by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    var groupsOnly by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<Conversation?>(null) }
    var confirmDelete by remember { mutableStateOf<Conversation?>(null) }
    var newChatName by remember { mutableStateOf("") }
    var newChatError by remember { mutableStateOf<String?>(null) }

    Scaffold { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {

            LargeTitle("Chats") {
                CircleAction(
                    icon = Icons.Filled.Edit,
                    contentDescription = "New conversation",
                    onClick = { showNewChat = true },
                )
            }

            // The old top bar carried the connection state at all times. iOS has
            // nowhere for it, and "Connected" is the boring case — so it now
            // shows only when something is wrong, where it is actually news.
            if (connection != ConnectionState.CONNECTED) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        Modifier
                            .size(7.dp)
                            .background(MaterialTheme.colorScheme.error, CircleShape),
                    )
                    Spacer(Modifier.width(7.dp))
                    Text(
                        text = connection.label(),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                Spacer(Modifier.height(8.dp))
            }

            SearchField(
                value = query,
                onValueChange = { query = it; onSearch(it) },
                placeholder = "Search messages",
            )
            Spacer(Modifier.height(12.dp))

            // Only worth offering once there is a group to filter to.
            if (conversations.any { it.groupId != null }) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    FilterChip("All", selected = !groupsOnly) { groupsOnly = false }
                    FilterChip("Groups", selected = groupsOnly) { groupsOnly = true }
                }
                Spacer(Modifier.height(8.dp))
            }


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

            val trimmed = query.trim()
            val shown = if (groupsOnly) conversations.filter { it.groupId != null } else conversations
            if (trimmed.isNotEmpty()) {
                SearchList(
                    query = trimmed,
                    conversations = conversations,
                    titleFor = titleFor,
                    results = searchResults,
                    onOpen = { id ->
                        query = ""
                        onSearch("")
                        onOpen(id)
                    },
                )
            } else if (shown.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.padding(horizontal = 40.dp),
                    ) {
                        Text(
                            if (groupsOnly) "No groups yet" else "No conversations yet",
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
                    items(shown, key = { it.id }) { conversation ->
                        ConversationRow(
                            conversation = conversation,
                            title = titleFor(conversation),
                            onClick = { onOpen(conversation.id) },
                            onLongClick = { menuFor = conversation },
                        )
                    }
                    // Clearance for the floating tab bar, which sits over the list.
                    item { Spacer(Modifier.height(96.dp)) }
                }
            }
        }
    }

    menuFor?.let { conversation ->
        ConversationActions(
            conversation = conversation,
            title = titleFor(conversation),
            onDismiss = { menuFor = null },
            onPin = { onPin(conversation.id, conversation.pinnedAt == null); menuFor = null },
            onArchive = { onArchive(conversation.id, !conversation.archived); menuFor = null },
            onMarkUnread = { onMarkUnread(conversation.id); menuFor = null },
            onDelete = { confirmDelete = conversation; menuFor = null },
            panicEnabled = panicEnabled,
            isHidden = conversation.id in hiddenConversations,
            onToggleHidden = {
                onToggleHidden(conversation.id, conversation.id !in hiddenConversations)
                menuFor = null
            },
        )
    }

    confirmDelete?.let { conversation ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirmDelete = null },
            title = { Text("Delete ${titleFor(conversation)}?") },
            text = {
                Text(
                    "Every message in this conversation is removed from this " +
                        "phone. The other side keeps their copy.",
                )
            },
            confirmButton = {
                TextButton(onClick = { onDelete(conversation.id); confirmDelete = null }) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = null }) { Text("Cancel") }
            },
        )
    }
}

/**
 * What search shows: conversations whose name matches, then messages whose body
 * matches, mirroring the two sections iOS puts under its search field.
 *
 * The message results arrive already filtered by the service — hidden threads
 * and marker payloads never reach here.
 */
@Composable
private fun SearchList(
    query: String,
    conversations: List<Conversation>,
    titleFor: (Conversation) -> String,
    results: List<SearchResult>,
    onOpen: (String) -> Unit,
) {
    val byName = conversations.filter { titleFor(it).contains(query, ignoreCase = true) }

    if (byName.isEmpty() && results.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                "No results for \"$query\".",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 40.dp),
            )
        }
        return
    }

    LazyColumn(Modifier.fillMaxSize()) {
        if (byName.isNotEmpty()) {
            item { SearchSectionHeader("Conversations") }
            items(byName, key = { "c:" + it.id }) { conversation ->
                ConversationRow(
                    conversation = conversation,
                    title = titleFor(conversation),
                    onClick = { onOpen(conversation.id) },
                    onLongClick = {},
                )
            }
        }
        if (results.isNotEmpty()) {
            item { SearchSectionHeader("Messages") }
            items(results, key = { "m:" + it.messageId }) { result ->
                val conversation = conversations.firstOrNull { it.id == result.conversationId }
                SearchResultRow(
                    title = conversation?.let(titleFor) ?: "Message",
                    account = conversation?.peerAccount ?: result.conversationId,
                    body = result.body,
                    timestamp = result.timestamp,
                    query = query,
                    onClick = { onOpen(result.conversationId) },
                )
            }
        }
        item { Spacer(Modifier.height(24.dp)) }
    }
}

@Composable
private fun SearchSectionHeader(label: String) {
    Text(
        text = label,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 6.dp),
    )
}

@Composable
private fun SearchResultRow(
    title: String,
    account: String,
    body: String,
    timestamp: Long,
    query: String,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Avatar(id = account, name = title, size = 56.dp)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                text = highlight(body, query),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                text = timestamp.asListTime(),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** Bolds every occurrence of the query inside the matched body. */
private fun highlight(text: String, query: String): AnnotatedString = buildAnnotatedString {
    if (query.isEmpty()) {
        append(text)
        return@buildAnnotatedString
    }
    var from = 0
    while (from < text.length) {
        val at = text.indexOf(query, startIndex = from, ignoreCase = true)
        if (at < 0) {
            append(text.substring(from))
            break
        }
        append(text.substring(from, at))
        withStyle(SpanStyle(fontWeight = FontWeight.Bold)) {
            append(text.substring(at, at + query.length))
        }
        from = at + query.length
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ConversationRow(
    conversation: Conversation,
    title: String,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
) {
    val unread = conversation.unreadCount > 0
    Row(
        Modifier
            .fillMaxWidth()
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Avatar(
            id = conversation.peerAccount,
            name = title,
            size = 56.dp,
            isGroup = conversation.groupId != null,
        )
        Spacer(Modifier.width(14.dp))

        Column(Modifier.weight(1f)) {
            Text(
                text = if (conversation.pinnedAt != null) "\uD83D\uDCCC $title" else title,
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

/** What a long press on a conversation offers. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConversationActions(
    conversation: Conversation,
    title: String,
    onDismiss: () -> Unit,
    onPin: () -> Unit,
    onArchive: () -> Unit,
    onMarkUnread: () -> Unit,
    onDelete: () -> Unit,
    panicEnabled: Boolean,
    isHidden: Boolean,
    onToggleHidden: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Text(
            title,
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
        )
        SheetAction(
            label = if (conversation.pinnedAt != null) "Unpin" else "Pin to top",
            icon = Icons.Filled.PushPin,
            onClick = onPin,
        )
        SheetAction(
            label = if (conversation.archived) "Unarchive" else "Archive",
            icon = Icons.Filled.Archive,
            onClick = onArchive,
        )
        // Only offered when there is something to mark: marking an already
        // unread thread unread again does nothing visible.
        if (conversation.unreadCount == 0) {
            SheetAction("Mark as unread", Icons.Filled.MarkEmailUnread, onMarkUnread)
        }
        if (panicEnabled) {
            SheetAction(
                label = if (isHidden) "Unhide" else "Hide behind PIN",
                icon = if (isHidden) Icons.Filled.Visibility else Icons.Filled.VisibilityOff,
                onClick = onToggleHidden,
            )
        }
        SheetAction("Delete conversation", Icons.Filled.Delete, onDelete, destructive = true)
        Spacer(Modifier.height(24.dp))
    }
}

/** "You: …" for our own last message, so a thread reads without opening it. */
private fun Conversation.preview(): String {
    val body = lastMessageBody?.takeIf { it.isNotBlank() } ?: return "No messages yet"
    return if (lastMessageIsOutgoing) "You: $body" else body
}

// ---------------------------------------------------------------------- chat

/** What the composer is doing: a new message, a reply, or an edit in progress. */
private sealed interface Compose {
    data object New : Compose
    data class Reply(val quote: QuotedMessage) : Compose
    data class Edit(val message: StoredMessage) : Compose
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun ChatScreen(
    title: String,
    messages: List<StoredMessage>,
    ownAccount: String,
    peerAccount: String,
    onSend: (body: String, quote: QuotedMessage?) -> Unit,
    onSendAttachment: (android.net.Uri) -> Unit,
    onReact: (targetTimestamp: Long, targetAuthor: String, emoji: String) -> Unit,
    onEdit: (targetTimestamp: Long, newBody: String) -> Unit,
    onUnsend: (targetTimestamp: Long) -> Unit,
    onDeleteLocally: (messageId: String) -> Unit,
    onToggleStar: (messageId: String, starred: Boolean) -> Unit,
    onTogglePin: (messageId: String, pinned: Boolean) -> Unit,
    onCreatePoll: (question: String, options: List<String>, multiSelect: Boolean) -> Unit,
    onVote: (pollAuthor: String, pollTimestamp: Long, option: Int) -> Unit,
    votesFor: (StoredMessage) -> List<StoredPollVote>,
    loadAttachment: suspend (app.relaymsg.storage.StoredAttachment) -> ByteArray?,
    onBack: () -> Unit,
    /** Places a call; `true` for video. Null hides the buttons. */
    onCall: ((Boolean) -> Unit)? = null,
    isBlocked: Boolean = false,
    /** Null in a group: there is no single account to block. */
    onToggleBlock: (() -> Unit)? = null,
    onVerify: (() -> Unit)? = null,
    disappearingSeconds: Long = 0,
    onSetDisappearing: ((Long) -> Unit)? = null,
    wallpaperId: String? = null,
    bubbleKey: String? = null,
    onShowGallery: () -> Unit = {},
    onShowAppearance: () -> Unit = {},
    onShowNotepad: () -> Unit = {},
    /** Null in a 1:1 conversation, which has no roster. */
    onShowGroupInfo: (() -> Unit)? = null,
    onSchedule: ((body: String, atMillis: Long) -> Unit)? = null,
    /** The one live bubble to show, already filtered for expiry. */
    liveLocation: Pair<String, LocationPayload>? = null,
    onOpenMap: (String) -> Unit = {},
    sharingLocation: Boolean = false,
    onToggleLocation: () -> Unit = {},
    recording: Boolean = false,
    onStartRecording: () -> Unit = {},
    onFinishRecording: () -> Unit = {},
    onCancelRecording: () -> Unit = {},
) {
    val pickImage = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia(),
    ) { uri -> uri?.let(onSendAttachment) }
    val pickFile = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.OpenDocument(),
    ) { uri -> uri?.let(onSendAttachment) }

    var draft by remember { mutableStateOf("") }
    var mode by remember { mutableStateOf<Compose>(Compose.New) }
    var selected by remember { mutableStateOf<StoredMessage?>(null) }
    var info by remember { mutableStateOf<StoredMessage?>(null) }
    var attachMenu by remember { mutableStateOf(false) }
    var overflow by remember { mutableStateOf(false) }
    var composePoll by remember { mutableStateOf(false) }
    var showDisappearing by remember { mutableStateOf(false) }
    var showEmoji by remember { mutableStateOf(false) }
    var showSchedule by remember { mutableStateOf(false) }
    var draftSelection by remember { mutableStateOf(0..0) }
    val listState = rememberLazyListState()
    val clipboard = LocalClipboardManager.current

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
                    run {
                        Box {
                            IconButton(onClick = { overflow = true }) {
                                Icon(Icons.Filled.MoreVert, contentDescription = "More")
                            }
                            DropdownMenu(
                                expanded = overflow,
                                onDismissRequest = { overflow = false },
                            ) {
                                onShowGroupInfo?.let { show ->
                                    DropdownMenuItem(
                                        text = { Text("Group info") },
                                        leadingIcon = {
                                            Icon(Icons.Filled.Groups, contentDescription = null)
                                        },
                                        onClick = { overflow = false; show() },
                                    )
                                }
                                DropdownMenuItem(
                                    text = { Text("Media, files and links") },
                                    leadingIcon = {
                                        Icon(Icons.Filled.PhotoLibrary, contentDescription = null)
                                    },
                                    onClick = { overflow = false; onShowGallery() },
                                )
                                DropdownMenuItem(
                                    text = { Text("Shared notes") },
                                    leadingIcon = {
                                        Icon(Icons.Filled.EditNote, contentDescription = null)
                                    },
                                    onClick = { overflow = false; onShowNotepad() },
                                )
                                DropdownMenuItem(
                                    text = { Text("Appearance") },
                                    leadingIcon = {
                                        Icon(Icons.Filled.Palette, contentDescription = null)
                                    },
                                    onClick = { overflow = false; onShowAppearance() },
                                )
                                onVerify?.let { verify ->
                                    DropdownMenuItem(
                                        text = { Text("Verify safety number") },
                                        leadingIcon = {
                                            Icon(Icons.Filled.Shield, contentDescription = null)
                                        },
                                        onClick = { overflow = false; verify() },
                                    )
                                }
                                onSetDisappearing?.let { set ->
                                    DropdownMenuItem(
                                        text = { Text("Disappearing messages") },
                                        leadingIcon = {
                                            Icon(Icons.Filled.Timer, contentDescription = null)
                                        },
                                        onClick = { overflow = false; showDisappearing = true },
                                    )
                                }
                                onToggleBlock?.let { toggle ->
                                    DropdownMenuItem(
                                        text = { Text(if (isBlocked) "Unblock" else "Block") },
                                        leadingIcon = {
                                            Icon(Icons.Filled.Block, contentDescription = null)
                                        },
                                        onClick = { overflow = false; toggle() },
                                    )
                                }
                            }
                        }
                    }
                },
            )
        },
    ) { padding ->
        val wallpaper = ChatAppearance.wallpaper(wallpaperId).brush
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .then(if (wallpaper != null) Modifier.background(wallpaper) else Modifier)
                .imePadding(),
        ) {
            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f).fillMaxWidth(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(12.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                items(
                    // The notepad rides on ordinary messages, so its revisions
                    // would otherwise fill the thread with marker text.
                    // The notepad and location updates both ride on ordinary
                    // messages; neither belongs in the thread as text.
                    messages.filterNot {
                        it.body.startsWith(RelayService.NOTEPAD_PREFIX) ||
                            it.body.startsWith(LocationPayload.MARKER)
                    },
                    key = { it.id },
                ) { message ->
                    MessageBubble(
                        message = message,
                        loadAttachment = loadAttachment,
                        onLongPress = { selected = message },
                        ownAccount = ownAccount,
                        bubbleKey = bubbleKey,
                        votesFor = votesFor,
                        onVote = { target, option ->
                            onVote(
                                target.senderAccount
                                    ?: if (target.isOutgoing) ownAccount else peerAccount,
                                target.timestamp,
                                option,
                            )
                        },
                    )
                }
            }

            liveLocation?.let { (who, payload) ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .background(MaterialTheme.colorScheme.primaryContainer)
                        .clickable {
                            onOpenMap("geo:${payload.lat},${payload.lng}?q=${payload.lat},${payload.lng}")
                        }
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        Icons.Filled.LocationOn,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onPrimaryContainer,
                    )
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            "$who is sharing their location",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onPrimaryContainer,
                        )
                        Text(
                            "Tap to open in a map app",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onPrimaryContainer.copy(alpha = 0.8f),
                        )
                    }
                }
            }

            if (isBlocked) {
                // Said where it matters, not buried in settings: an unexplained
                // silence in a thread is exactly what a stale block looks like.
                Text(
                    "You blocked this contact. Their messages are being discarded.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onErrorContainer,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(MaterialTheme.colorScheme.errorContainer)
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }

            ComposerBanner(
                mode = mode,
                onCancel = { mode = Compose.New; draft = "" },
            )

            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)

            // Only while there is something to format: an always-on toolbar
            // takes a row of the screen to do nothing most of the time.
            if (draft.isNotEmpty()) {
                Row(
                    Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    listOf(
                        "**" to Icons.Filled.FormatBold,
                        "_" to Icons.Filled.FormatItalic,
                        "~~" to Icons.Filled.StrikethroughS,
                        "`" to Icons.Filled.Code,
                    ).forEach { (marker, icon) ->
                        IconButton(
                            onClick = {
                                val (updated, caret) =
                                    MessageText.applyMarker(draft, draftSelection, marker)
                                draft = updated
                                draftSelection = caret..caret
                            },
                            modifier = Modifier.size(34.dp),
                        ) {
                            Icon(
                                icon,
                                contentDescription = marker,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                }
            }

            Row(
                Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 8.dp),
                verticalAlignment = Alignment.Bottom,
            ) {
                IconButton(onClick = { showEmoji = !showEmoji }) {
                    Icon(
                        Icons.Filled.EmojiEmotions,
                        contentDescription = "Emoji",
                        tint = if (showEmoji) {
                            MaterialTheme.colorScheme.primary
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                    )
                }
                Box {
                    IconButton(onClick = { attachMenu = true }) {
                        Icon(
                            Icons.Filled.Add,
                            contentDescription = "Attach",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    DropdownMenu(expanded = attachMenu, onDismissRequest = { attachMenu = false }) {
                        DropdownMenuItem(
                            text = { Text("Photo or video") },
                            leadingIcon = { Icon(Icons.Filled.Image, contentDescription = null) },
                            onClick = {
                                attachMenu = false
                                pickImage.launch(
                                    androidx.activity.result.PickVisualMediaRequest(
                                        androidx.activity.result.contract.ActivityResultContracts
                                            .PickVisualMedia.ImageAndVideo,
                                    ),
                                )
                            },
                        )
                        DropdownMenuItem(
                            text = {
                                Text(if (sharingLocation) "Stop sharing location" else "Live location")
                            },
                            leadingIcon = {
                                Icon(Icons.Filled.LocationOn, contentDescription = null)
                            },
                            onClick = { attachMenu = false; onToggleLocation() },
                        )
                        DropdownMenuItem(
                            text = { Text("Poll") },
                            leadingIcon = { Icon(Icons.Filled.Poll, contentDescription = null) },
                            onClick = { attachMenu = false; composePoll = true },
                        )
                        DropdownMenuItem(
                            text = { Text("File") },
                            leadingIcon = {
                                Icon(Icons.AutoMirrored.Filled.InsertDriveFile, contentDescription = null)
                            },
                            onClick = {
                                attachMenu = false
                                // Any type: the relay stores ciphertext and never
                                // looks at what it is.
                                pickFile.launch(arrayOf("*/*"))
                            },
                        )
                    }
                }

                TextField(
                    value = draft,
                    onValueChange = { draft = it },
                    placeholder = {
                        Text(if (mode is Compose.Edit) "Edit message" else "Message")
                    },
                    modifier = Modifier.weight(1f).clip(RoundedCornerShape(22.dp)),
                    maxLines = 5,
                    textStyle = MaterialTheme.typography.bodyLarge,
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                        unfocusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent,
                        disabledIndicatorColor = Color.Transparent,
                    ),
                )
                Spacer(Modifier.width(6.dp))
                val canSend = draft.isNotBlank()
                if (!canSend && mode !is Compose.Edit) {
                    IconButton(
                        onClick = { if (recording) onFinishRecording() else onStartRecording() },
                        modifier = Modifier
                            .size(46.dp)
                            .background(
                                if (recording) {
                                    MaterialTheme.colorScheme.error
                                } else {
                                    MaterialTheme.colorScheme.surfaceVariant
                                },
                                CircleShape,
                            ),
                    ) {
                        Icon(
                            if (recording) Icons.Filled.Stop else Icons.Filled.Mic,
                            contentDescription = if (recording) "Send voice note" else "Record",
                            tint = if (recording) {
                                MaterialTheme.colorScheme.onError
                            } else {
                                MaterialTheme.colorScheme.onSurfaceVariant
                            },
                            modifier = Modifier.size(20.dp),
                        )
                    }
                    return@Row
                }
                @OptIn(ExperimentalFoundationApi::class)
                Box(
                    Modifier
                        .size(46.dp)
                        .clip(CircleShape)
                        .background(
                            if (canSend) {
                                MaterialTheme.colorScheme.primary
                            } else {
                                MaterialTheme.colorScheme.surfaceVariant
                            },
                        )
                        .combinedClickable(
                            enabled = canSend,
                            onLongClick = {
                                // Long press, because scheduling is rare enough
                                // that a permanent second button would be clutter.
                                if (onSchedule != null && mode !is Compose.Edit) {
                                    showSchedule = true
                                }
                            },
                            onClick = {
                                val body = draft.trim()
                        when (val current = mode) {
                            is Compose.Edit -> onEdit(current.message.timestamp, body)
                            is Compose.Reply -> onSend(body, current.quote)
                            Compose.New -> onSend(body, null)
                        }
                                draft = ""
                                mode = Compose.New
                            },
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        if (mode is Compose.Edit) Icons.Filled.Check else Icons.AutoMirrored.Filled.Send,
                        contentDescription = if (mode is Compose.Edit) "Save edit" else "Send",
                        tint = if (canSend) {
                            MaterialTheme.colorScheme.onPrimary
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                        modifier = Modifier.size(20.dp),
                    )
                }
            }

            if (showEmoji) {
                EmojiPicker(onPick = { emoji -> draft += emoji })
            }
        }
    }

    selected?.let { message ->
        MessageActions(
            message = message,
            onDismiss = { selected = null },
            onReact = { emoji ->
                onReact(
                    message.timestamp,
                    message.senderAccount ?: if (message.isOutgoing) ownAccount else peerAccount,
                    emoji,
                )
                selected = null
            },
            onReply = {
                mode = Compose.Reply(
                    QuotedMessage(
                        targetTimestamp = message.timestamp,
                        author = message.senderAccount
                            ?: if (message.isOutgoing) ownAccount else peerAccount,
                        text = message.body,
                    ),
                )
                selected = null
            },
            onCopy = {
                clipboard.setText(androidx.compose.ui.text.AnnotatedString(message.body))
                selected = null
            },
            onEdit = {
                draft = message.body
                mode = Compose.Edit(message)
                selected = null
            },
            onToggleStar = { onToggleStar(message.id, !message.isStarred); selected = null },
            onTogglePin = { onTogglePin(message.id, !message.isPinned); selected = null },
            onInfo = { info = message; selected = null },
            onUnsend = { onUnsend(message.timestamp); selected = null },
            onDeleteLocally = { onDeleteLocally(message.id); selected = null },
        )
    }


    info?.let { message ->
        MessageInfo(message) { info = null }
    }

    if (showSchedule && onSchedule != null) {
        SchedulePicker(
            onPick = { millis ->
                onSchedule(draft.trim(), millis)
                draft = ""
                showSchedule = false
            },
            onDismiss = { showSchedule = false },
        )
    }

    if (showDisappearing && onSetDisappearing != null) {
        DisappearingPicker(
            current = disappearingSeconds,
            onPick = { onSetDisappearing(it); showDisappearing = false },
            onDismiss = { showDisappearing = false },
        )
    }

    if (composePoll) {
        PollComposer(
            onDismiss = { composePoll = false },
            onCreate = { question, options, multi ->
                onCreatePoll(question, options, multi)
                composePoll = false
            },
        )
    }
}

/** When to send a queued message. Relative offsets, which is how people think. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SchedulePicker(onPick: (Long) -> Unit, onDismiss: () -> Unit) {
    val options = listOf(
        60L * 60 to "In an hour",
        60L * 60 * 3 to "In 3 hours",
        60L * 60 * 8 to "In 8 hours",
        60L * 60 * 24 to "Tomorrow",
        60L * 60 * 24 * 7 to "Next week",
    )
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Text(
            "Send later",
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
        )
        options.forEach { (seconds, label) ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable { onPick(System.currentTimeMillis() + seconds * 1000) }
                    .padding(horizontal = 24.dp, vertical = 14.dp),
            ) {
                Text(label, style = MaterialTheme.typography.bodyLarge)
            }
        }
        Spacer(Modifier.height(24.dp))
    }
}

/** How long new messages in this conversation should live. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DisappearingPicker(current: Long, onPick: (Long) -> Unit, onDismiss: () -> Unit) {
    // Signal's ladder, which is the one people recognise.
    val options = listOf(
        0L to "Off",
        30L to "30 seconds",
        300L to "5 minutes",
        3_600L to "1 hour",
        28_800L to "8 hours",
        86_400L to "1 day",
        604_800L to "1 week",
        2_419_200L to "4 weeks",
    )
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Text(
            "Disappearing messages",
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
        )
        Text(
            "Applies to messages sent from now on, on both sides. Older ones stay.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 24.dp),
        )
        Spacer(Modifier.height(8.dp))
        options.forEach { (seconds, label) ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable { onPick(seconds) }
                    .padding(horizontal = 24.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = if (seconds == current) "● $label" else "○ $label",
                    style = MaterialTheme.typography.bodyLarge,
                    color = if (seconds == current) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.onSurface
                    },
                )
            }
        }
        Spacer(Modifier.height(24.dp))
    }
}

/**
 * A poll inside a bubble.
 *
 * Tallies are computed here rather than stored: votes arrive independently of
 * the poll and a stored count would drift the moment one was missed.
 */
@Composable
private fun PollBody(
    poll: PollPayload,
    votes: List<StoredPollVote>,
    ownAccount: String,
    onBlack: Boolean,
    onVote: (Int) -> Unit,
) {
    val ink = if (onBlack) Color.White else MaterialTheme.colorScheme.onSurface
    val total = votes.size
    val mine = votes.firstOrNull { it.voterAccount == ownAccount }?.selectedOptions.orEmpty()

    Column {
        Text(poll.question, style = MaterialTheme.typography.bodyLarge, color = ink)
        Spacer(Modifier.height(8.dp))
        poll.options.forEachIndexed { index, option ->
            val count = votes.count { index in it.selectedOptions }
            val share = if (total == 0) 0f else count.toFloat() / total
            val chosen = index in mine
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .clickable { onVote(index) }
                    .padding(vertical = 5.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = if (chosen) "● $option" else "○ $option",
                        style = MaterialTheme.typography.bodyMedium,
                        color = ink,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        text = "$count",
                        style = MaterialTheme.typography.labelMedium,
                        color = ink.copy(alpha = 0.7f),
                    )
                }
                Spacer(Modifier.height(3.dp))
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(4.dp)
                        .clip(RoundedCornerShape(2.dp))
                        .background(ink.copy(alpha = 0.18f)),
                ) {
                    Box(
                        Modifier
                            .fillMaxWidth(share)
                            .height(4.dp)
                            .background(if (onBlack) Color.White else MaterialTheme.colorScheme.primary),
                    )
                }
            }
        }
        Spacer(Modifier.height(2.dp))
        Text(
            text = when {
                total == 0 -> "No votes yet"
                total == 1 -> "1 vote"
                else -> "$total votes"
            } + if (poll.multiSelect) " · pick any" else "",
            style = MaterialTheme.typography.labelSmall,
            color = ink.copy(alpha = 0.7f),
        )
    }
}

/** Question plus up to ten options; blanks are dropped on create. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PollComposer(
    onDismiss: () -> Unit,
    onCreate: (String, List<String>, Boolean) -> Unit,
) {
    var question by remember { mutableStateOf("") }
    var options by remember { mutableStateOf(listOf("", "")) }
    var multiSelect by remember { mutableStateOf(false) }
    val filled = options.map { it.trim() }.filter { it.isNotEmpty() }
    val valid = question.isNotBlank() && filled.size >= 2

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 24.dp)) {
            Text("New poll", style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = question,
                onValueChange = { question = it.take(200) },
                label = { Text("Question") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            options.forEachIndexed { index, value ->
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = value,
                    onValueChange = { text ->
                        options = options.toMutableList().also { it[index] = text.take(100) }
                    },
                    label = { Text("Option ${index + 1}") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            if (options.size < 10) {
                TextButton(onClick = { options = options + "" }) { Text("Add option") }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(checked = multiSelect, onCheckedChange = { multiSelect = it })
                Spacer(Modifier.width(12.dp))
                Text("Allow multiple answers", style = MaterialTheme.typography.bodyMedium)
            }
            Spacer(Modifier.height(12.dp))
            Button(
                enabled = valid,
                onClick = { onCreate(question.trim(), filled, multiSelect) },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Create poll") }
        }
    }
}

/**
 * What the app actually knows about one message.
 *
 * Worth its own sheet because "Sent" and "Delivered" mean different things —
 * the first is the relay accepting it, the second the recipient's device
 * decrypting it — and that distinction is the only way to tell a slow network
 * from a phone that never opened.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MessageInfo(message: StoredMessage, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Text(
            "Message info",
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
        )
        InfoLine("Sent", message.timestamp.asFullTime())
        if (message.isOutgoing) InfoLine("Status", message.status.indicator().ifEmpty { "—" })
        message.editedAt?.let { InfoLine("Edited", it.asFullTime()) }
        if (message.attachments.isNotEmpty()) {
            InfoLine("Attachments", "${message.attachments.size}")
        }
        if (message.reactions.isNotEmpty()) {
            InfoLine("Reactions", message.reactions.joinToString(" ") { it.emoji })
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun InfoLine(label: String, value: String) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(110.dp),
        )
        Text(value, style = MaterialTheme.typography.bodyLarge)
    }
}

/** The strip above the composer while replying to, or editing, a message. */
@Composable
private fun ComposerBanner(mode: Compose, onCancel: () -> Unit) {
    if (mode is Compose.New) return
    val label = when (mode) {
        is Compose.Reply -> "Replying to"
        is Compose.Edit -> "Editing"
        Compose.New -> return
    }
    val body = when (mode) {
        is Compose.Reply -> mode.quote.text
        is Compose.Edit -> mode.message.body
        Compose.New -> ""
    }
    Row(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .width(3.dp)
                .height(32.dp)
                .background(MaterialTheme.colorScheme.primary, RoundedCornerShape(2.dp)),
        )
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                label,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.primary,
            )
            Text(
                body,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = onCancel) {
            Icon(
                Icons.Filled.Close,
                contentDescription = "Cancel",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * What a long press on a message offers.
 *
 * Only actions that actually exist appear: editing and unsending are the
 * author's alone, and the protocol enforces that too — a delete from anyone
 * else is ignored on receipt.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MessageActions(
    message: StoredMessage,
    onDismiss: () -> Unit,
    onReact: (String) -> Unit,
    onReply: () -> Unit,
    onCopy: () -> Unit,
    onEdit: () -> Unit,
    onToggleStar: () -> Unit,
    onTogglePin: () -> Unit,
    onInfo: () -> Unit,
    onUnsend: () -> Unit,
    onDeleteLocally: () -> Unit,
) {
    val hasText = message.body.isNotEmpty() && !message.isDeleted
    ModalBottomSheet(onDismissRequest = onDismiss) {
        if (!message.isDeleted) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.SpaceEvenly,
            ) {
                // The set every messenger converges on. Tapping one you have
                // already used takes it back.
                listOf("👍", "❤️", "😂", "😮", "😢", "🙏")
                    .forEach { emoji ->
                        val mine = message.reactions.any { it.isOutgoing && it.emoji == emoji }
                        Text(
                            text = emoji,
                            fontSize = 28.sp,
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(
                                    if (mine) {
                                        MaterialTheme.colorScheme.primaryContainer
                                    } else {
                                        Color.Transparent
                                    },
                                )
                                .clickable { onReact(emoji) }
                                .padding(8.dp),
                        )
                    }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        }

        // Order and wording follow iOS's menu, so the same action is in the
        // same place on both.
        SheetAction("Reply", Icons.AutoMirrored.Filled.Reply, onReply)
        // iOS gates editing on having no attachments rather than on having
        // text: an edit only carries a body, so a caption change would silently
        // drop the picture.
        if (message.isOutgoing && message.attachments.isEmpty() && !message.isDeleted) {
            SheetAction("Edit", Icons.Filled.Edit, onEdit)
        }
        if (hasText) SheetAction("Copy", Icons.Filled.ContentCopy, onCopy)
        SheetAction(
            label = if (message.isStarred) "Unstar" else "Star",
            icon = if (message.isStarred) Icons.Filled.StarOutline else Icons.Filled.Star,
            onClick = onToggleStar,
        )
        SheetAction(
            label = if (message.isPinned) "Unpin" else "Pin",
            icon = Icons.Filled.PushPin,
            onClick = onTogglePin,
        )
        SheetAction("Info", Icons.Filled.Info, onInfo)
        if (message.isOutgoing && !message.isDeleted) {
            SheetAction(
                "Unsend for Everyone",
                Icons.AutoMirrored.Filled.Undo,
                onUnsend,
                destructive = true,
            )
        }
        SheetAction("Delete", Icons.Filled.Delete, onDeleteLocally, destructive = true)
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun SheetAction(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    onClick: () -> Unit,
    destructive: Boolean = false,
) {
    val tint = if (destructive) {
        MaterialTheme.colorScheme.error
    } else {
        MaterialTheme.colorScheme.onSurface
    }
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 24.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(18.dp))
        Text(label, style = MaterialTheme.typography.bodyLarge, color = tint)
    }
}

@Composable
@OptIn(ExperimentalFoundationApi::class)
private fun MessageBubble(
    message: StoredMessage,
    loadAttachment: suspend (app.relaymsg.storage.StoredAttachment) -> ByteArray?,
    onLongPress: () -> Unit,
    ownAccount: String,
    bubbleKey: String?,
    votesFor: (StoredMessage) -> List<StoredPollVote>,
    onVote: (StoredMessage, Int) -> Unit,
) {
    val outgoing = message.isOutgoing
    // Deep -> band, not the logo's full gradient: white on the bright stop is
    // only 3.0:1. Along this run it never drops below 4.7:1.
    // A chosen tint, or the brand's own deep -> band run.
    val outgoingFill = Brush.linearGradient(
        ChatAppearance.bubbleTint(bubbleKey) ?: listOf(MagentaDeep, Magenta),
    )
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

    // A single 😂 in a full-width bubble reads as shouting. Short all-emoji
    // messages render large and bare, the way iMessage and Signal do it.
    if (Emoji.isJumbo(message.body) && message.attachments.isEmpty() && !message.isDeleted) {
        Row(
            Modifier.fillMaxWidth().combinedClickable(onClick = {}, onLongClick = onLongPress),
            horizontalArrangement = if (outgoing) Arrangement.End else Arrangement.Start,
        ) {
            Text(
                text = message.body.trim(),
                fontSize = 44.sp,
                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
        return
    }

    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = if (outgoing) Arrangement.End else Arrangement.Start,
    ) {
        Column(
            Modifier
                .widthIn(max = 300.dp)
                .clip(shape)
                .background(if (outgoing) outgoingFill else incomingFill)
                // Long press, not a tap: tapping a bubble should do nothing,
                // so scrolling past one never springs a menu open.
                .combinedClickable(onClick = {}, onLongClick = onLongPress)
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
                AttachmentBody(attachment, onBlack = outgoing, load = loadAttachment)
                Spacer(Modifier.height(4.dp))
            }
            val poll = remember(message.body) { PollPayload.fromBody(message.body) }
            val link = remember(message.body) {
                if (poll == null && !message.isDeleted) LinkPreview.firstUrl(message.body) else null
            }
            if (poll != null && !message.isDeleted) {
                PollBody(
                    poll = poll,
                    votes = votesFor(message),
                    ownAccount = ownAccount,
                    onBlack = outgoing,
                    onVote = { option -> onVote(message, option) },
                )
            } else if (message.body.isNotEmpty() || message.isDeleted) {
                Text(
                    text = if (message.isDeleted) {
                        androidx.compose.ui.text.AnnotatedString("This message was deleted")
                    } else {
                        MessageText.format(message.body)
                    },
                    style = MaterialTheme.typography.bodyLarge,
                    color = if (message.isDeleted) meta else ink,
                    fontStyle = if (message.isDeleted) FontStyle.Italic else FontStyle.Normal,
                )
            }
            link?.let { LinkPreviewCard(it, onBlack = outgoing) }

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
private val fullFormat = SimpleDateFormat("d MMM yyyy, HH:mm:ss", Locale.getDefault())

private fun Long.asFullTime(): String = fullFormat.format(Date(this))

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
