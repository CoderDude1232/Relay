package app.relaymsg.ui

import android.Manifest
import android.content.Context
import android.provider.ContactsContract
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.compose.ui.platform.LocalContext
import app.relaymsg.core.RelayService
import kotlinx.coroutines.launch

/** One address-book entry, as the sheet needs it. */
data class PhoneContact(
    val name: String,
    val emails: List<String>,
    val photo: ByteArray?,
) {
    override fun equals(other: Any?) = this === other ||
        (other is PhoneContact && name == other.name && emails == other.emails)

    override fun hashCode() = 31 * name.hashCode() + emails.hashCode()
}

/** Where a contact's directory lookup has got to. */
private sealed interface Lookup {
    data object Pending : Lookup
    data class OnRelay(val username: String) : Lookup
    data object NotFound : Lookup
}

/**
 * Starting a new conversation.
 *
 * Four ways in — a username, a group, yourself, a QR code — and then the
 * address book, so the common case (someone already in your phone) is one tap
 * rather than remembering their handle.
 *
 * **Contacts are not read until asked for.** Opening this sheet requests
 * nothing; the list is replaced by a button, and the permission dialog only
 * appears if it is pressed. Prompting on open trains people to dismiss the
 * dialog, and a messenger that asks for the address book the first time you
 * try to message anyone has earned that reflex.
 */
@Composable
fun NewConversationSheet(
    onCancel: () -> Unit,
    onFindByUsername: () -> Unit,
    onNewGroup: () -> Unit,
    onNoteToSelf: () -> Unit,
    onScanQr: () -> Unit,
    onOpenUsername: (String) -> Unit,
    onInvite: (Context) -> Unit,
    onDiscover: (List<String>, (List<RelayService.DiscoveredContact>) -> Unit) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var query by remember { mutableStateOf("") }
    var granted by remember { mutableStateOf(hasContactsPermission(context)) }
    var contacts by remember { mutableStateOf<List<PhoneContact>?>(null) }
    var lookups by remember { mutableStateOf<Map<String, Lookup>>(emptyMap()) }

    val request = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted = it }

    // Reading the address book touches the content provider; off the main
    // thread, because a large one takes long enough to drop frames.
    LaunchedEffect(granted) {
        if (!granted) return@LaunchedEffect
        val read = scope.launch { contacts = readContacts(context) }
        read.join()
        val emails = contacts.orEmpty().flatMap { it.emails }
        if (emails.isEmpty()) return@LaunchedEffect
        lookups = emails.associateWith { Lookup.Pending }
        onDiscover(emails) { found ->
            val byEmail = found.associateBy { it.identifier }
            lookups = emails.associateWith { email ->
                byEmail[email]?.let { Lookup.OnRelay(it.username) } ?: Lookup.NotFound
            }
        }
    }

    val shown = remember(contacts, query) {
        val trimmed = query.trim()
        contacts.orEmpty()
            .filter { trimmed.isEmpty() || it.name.contains(trimmed, ignoreCase = true) }
            .sortedBy { it.name.lowercase() }
    }
    val listState = rememberLazyListState()

    Column(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 44.dp, bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            PillButton("Cancel", onClick = onCancel)
            Text(
                text = "New Conversation",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                modifier = Modifier.weight(1f),
            )
            // Balances the Cancel pill so the title stays centred.
            Spacer(Modifier.width(84.dp))
        }

        SearchField(
            value = query,
            onValueChange = { query = it },
            placeholder = "Search contacts",
        )
        Spacer(Modifier.height(8.dp))

        Box(Modifier.weight(1f)) {
            LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
                item {
                    ActionEntry(Icons.Filled.Search, "Find by @username", onFindByUsername)
                    ActionEntry(Icons.Filled.Groups, "New Group", onNewGroup)
                    ActionEntry(Icons.Filled.EditNote, "Note to Self", onNoteToSelf)
                    ActionEntry(Icons.Filled.QrCodeScanner, "Scan QR Code", onScanQr)
                    Spacer(Modifier.height(20.dp))
                }

                if (!granted) {
                    item {
                        ContactsOptIn { request.launch(Manifest.permission.READ_CONTACTS) }
                    }
                    return@LazyColumn
                }

                if (contacts == null) {
                    item {
                        Box(Modifier.fillMaxWidth().padding(32.dp), Alignment.Center) {
                            CircularProgressIndicator(Modifier.size(24.dp))
                        }
                    }
                    return@LazyColumn
                }

                // Section headers, in the order the sorted list produces them.
                var lastInitial: Char? = null
                shown.forEach { contact ->
                    val initial = contact.name.initialChar()
                    if (initial != lastInitial) {
                        lastInitial = initial
                        item(key = "h$initial") { SectionLetter(initial) }
                    }
                    item(key = contact.name + contact.emails.firstOrNull()) {
                        val state = contact.emails
                            .firstNotNullOfOrNull { email ->
                                lookups[email]?.takeIf { it !is Lookup.NotFound }
                            }
                            ?: Lookup.NotFound
                        ContactRow(
                            contact = contact,
                            lookup = state,
                            onOpen = { username -> onOpenUsername(username) },
                            onInvite = { onInvite(context) },
                        )
                    }
                }

                if (shown.isEmpty()) {
                    item {
                        Box(Modifier.fillMaxWidth().padding(32.dp), Alignment.Center) {
                            Text(
                                if (query.isBlank()) {
                                    "No contacts with an email address"
                                } else {
                                    "No contact matches \"${query.trim()}\""
                                },
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                textAlign = TextAlign.Center,
                            )
                        }
                    }
                }
                item { Spacer(Modifier.height(24.dp)) }
            }

            // The alphabet rail. Only worth drawing once the list is long
            // enough that scrolling to a letter beats scrolling to a name.
            if (granted && shown.size > 12) {
                AlphabetRail(
                    letters = shown.map { it.name.initialChar() }.distinct(),
                    onPick = { letter ->
                        val index = shown.indexOfFirst { it.name.initialChar() == letter }
                        if (index >= 0) {
                            scope.launch {
                                // +1 for the action block, +1 per header above it.
                                val headers = shown.take(index)
                                    .map { it.name.initialChar() }
                                    .distinct()
                                    .size
                                listState.scrollToItem(1 + headers + index)
                            }
                        }
                    },
                    modifier = Modifier.align(Alignment.CenterEnd),
                )
            }
        }
    }
}

@Composable
private fun ActionEntry(icon: ImageVector, label: String, onClick: () -> Unit) {
    Column {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable(onClick = onClick)
                .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(26.dp),
            )
            Spacer(Modifier.width(18.dp))
            Text(label, style = MaterialTheme.typography.bodyLarge)
        }
        HorizontalDivider(
            color = MaterialTheme.colorScheme.outlineVariant,
            modifier = Modifier.padding(start = 64.dp),
        )
    }
}

/**
 * What stands in for the contact list before permission is given.
 *
 * It says what is read and what leaves the phone, because "allow contacts" on
 * its own is a request to trust the app with an address book, and the answer
 * depends entirely on what happens to it.
 */
@Composable
private fun ContactsOptIn(onEnable: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 28.dp, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            "Find people you know",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            "Relay can check your contacts' email addresses against the " +
                "directory. Each address is blinded on this phone first, so the " +
                "relay never learns who is in your address book — or which of " +
                "them matched. Nothing is uploaded or stored.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(20.dp))
        PillButton("Enable contacts", onClick = onEnable)
        Spacer(Modifier.height(10.dp))
        Text(
            "You can skip this and start a chat with a username instead.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun SectionLetter(letter: Char) {
    Text(
        text = letter.toString(),
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 20.dp, top = 16.dp, bottom = 4.dp),
    )
}

@Composable
private fun ContactRow(
    contact: PhoneContact,
    lookup: Lookup,
    onOpen: (String) -> Unit,
    onInvite: () -> Unit,
) {
    val onRelay = lookup as? Lookup.OnRelay
    Row(
        Modifier
            .fillMaxWidth()
            .let { if (onRelay != null) it.clickable { onOpen(onRelay.username) } else it }
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Avatar(id = contact.name, name = contact.name, size = 44.dp, imageData = contact.photo)
        Spacer(Modifier.width(16.dp))
        Text(
            text = contact.name,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.weight(1f),
        )
        when (lookup) {
            is Lookup.Pending -> CircularProgressIndicator(
                strokeWidth = 2.dp,
                modifier = Modifier.size(18.dp),
            )
            is Lookup.OnRelay -> Text(
                text = "@" + onRelay!!.username,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary,
            )
            // Not on Relay, so the only useful action is to ask them to be.
            is Lookup.NotFound -> InvitePill(onInvite)
        }
    }
}

@Composable
private fun InvitePill(onClick: () -> Unit) {
    Box(
        Modifier
            .background(MaterialTheme.colorScheme.surfaceVariant, CircleShape)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 7.dp),
    ) {
        Text(
            "Invite",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun AlphabetRail(letters: List<Char>, onPick: (Char) -> Unit, modifier: Modifier) {
    Column(
        modifier.padding(end = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        letters.forEach { letter ->
            Text(
                text = letter.toString(),
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier
                    .clickable { onPick(letter) }
                    .padding(horizontal = 8.dp, vertical = 1.dp),
            )
        }
    }
}

/** '#' for anything that does not start with a letter, so the rail stays A–Z. */
private fun String.initialChar(): Char =
    trim().firstOrNull()?.uppercaseChar()?.takeIf { it in 'A'..'Z' } ?: '#'

private fun hasContactsPermission(context: Context): Boolean =
    ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) ==
        android.content.pm.PackageManager.PERMISSION_GRANTED

/**
 * The address book: a display name, its email addresses and a thumbnail.
 *
 * Emails only, matching iOS — the directory is keyed on an email's OPRF token
 * and phone numbers are not in it. Contacts with no address are left out
 * entirely rather than listed with nothing to look up.
 */
private fun readContacts(context: Context): List<PhoneContact> = runCatching {
    val emailsByContact = mutableMapOf<String, MutableList<String>>()
    context.contentResolver.query(
        ContactsContract.CommonDataKinds.Email.CONTENT_URI,
        arrayOf(
            ContactsContract.CommonDataKinds.Email.CONTACT_ID,
            ContactsContract.CommonDataKinds.Email.ADDRESS,
        ),
        null, null, null,
    )?.use { cursor ->
        while (cursor.moveToNext()) {
            val id = cursor.getString(0) ?: continue
            val address = cursor.getString(1)?.trim()?.lowercase() ?: continue
            if ("@" !in address) continue
            emailsByContact.getOrPut(id) { mutableListOf() }.add(address)
        }
    }
    if (emailsByContact.isEmpty()) return@runCatching emptyList()

    val names = mutableMapOf<String, String>()
    val photos = mutableMapOf<String, ByteArray?>()
    context.contentResolver.query(
        ContactsContract.Contacts.CONTENT_URI,
        arrayOf(
            ContactsContract.Contacts._ID,
            ContactsContract.Contacts.DISPLAY_NAME_PRIMARY,
            ContactsContract.Contacts.PHOTO_THUMBNAIL_URI,
        ),
        null, null, null,
    )?.use { cursor ->
        while (cursor.moveToNext()) {
            val id = cursor.getString(0) ?: continue
            if (id !in emailsByContact) continue
            names[id] = cursor.getString(1)?.trim().orEmpty()
            photos[id] = cursor.getString(2)?.let { uri ->
                runCatching {
                    context.contentResolver.openInputStream(android.net.Uri.parse(uri))
                        ?.use { it.readBytes() }
                }.getOrNull()
            }
        }
    }

    emailsByContact.mapNotNull { (id, emails) ->
        val name = names[id]?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
        PhoneContact(name = name, emails = emails.distinct(), photo = photos[id])
    }.sortedBy { it.name.lowercase() }
}.getOrDefault(emptyList())
