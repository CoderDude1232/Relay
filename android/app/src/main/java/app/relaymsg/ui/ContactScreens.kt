package app.relaymsg.ui

import android.Manifest
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.relaymsg.core.RelayService

/**
 * Your own contact card: the QR others scan, and a link you can send.
 *
 * The QR carries `https://relaymsg.app/add/<username>`, the same payload iOS
 * encodes — so either client's camera opens it, and a phone with neither
 * installed lands on the website instead of a dead scheme.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContactCardScreen(
    username: String,
    displayName: String,
    accountId: String,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val link = "https://relaymsg.app/add/$username"

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("My code") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Avatar(id = accountId, name = displayName.ifEmpty { username }, size = 72.dp)
            Spacer(Modifier.height(12.dp))
            Text(
                displayName.ifEmpty { username },
                style = MaterialTheme.typography.headlineSmall,
            )
            Text(
                "@$username",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Spacer(Modifier.height(24.dp))
            QrImage(link, size = 240.dp)
            Spacer(Modifier.height(12.dp))
            Text(
                "relaymsg.app/add/$username",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Spacer(Modifier.height(24.dp))
            Button(
                onClick = {
                    runCatching {
                        context.startActivity(
                            Intent.createChooser(
                                Intent(Intent.ACTION_SEND)
                                    .setType("text/plain")
                                    .putExtra(Intent.EXTRA_TEXT, "Message me on Relay: $link"),
                                "Share your code",
                            ),
                        )
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Share link") }

            Spacer(Modifier.height(16.dp))
            Text(
                // Said explicitly: a permanent link is not the same as the
                // one-time invite in Settings, and the difference matters.
                "This link is permanent. Anyone who has it can start a " +
                    "conversation with you.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}

/**
 * Finds address-book contacts who are on Relay.
 *
 * Addresses never reach the relay. Each is blinded locally, the relay evaluates
 * its OPRF over the blinded element, and only the resulting token is presented
 * for matching — so it learns neither the addresses nor which of them matched.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContactSyncScreen(
    onSync: suspend (List<String>) -> List<RelayService.DiscoveredContact>,
    onStart: (username: String) -> Unit,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    var granted by remember { mutableStateOf(hasContacts(context)) }
    var scanning by remember { mutableStateOf(false) }
    var matches by remember { mutableStateOf<List<RelayService.DiscoveredContact>?>(null) }

    val request = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted = it }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Find contacts") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            Text(
                "Relay checks your contacts' email addresses against the " +
                    "directory without sending them. Each address is blinded on " +
                    "this phone first, so the server never learns who is in your " +
                    "address book — or which of them matched.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
            )

            Button(
                enabled = !scanning,
                onClick = {
                    if (!granted) {
                        request.launch(Manifest.permission.READ_CONTACTS)
                    } else {
                        scanning = true
                    }
                },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp),
            ) {
                if (scanning) {
                    CircularProgressIndicator(Modifier.height(18.dp))
                } else {
                    Text(if (granted) "Check contacts" else "Allow contacts access")
                }
            }

            if (scanning) {
                androidx.compose.runtime.LaunchedEffect(Unit) {
                    matches = onSync(readEmails(context))
                    scanning = false
                }
            }

            matches?.let { found ->
                HorizontalDivider(
                    color = MaterialTheme.colorScheme.outlineVariant,
                    modifier = Modifier.padding(top = 16.dp),
                )
                if (found.isEmpty()) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(
                            "None of your contacts are on Relay yet",
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.padding(32.dp),
                        )
                    }
                } else {
                    LazyColumn {
                        items(found, key = { it.accountId }) { match ->
                            Row(
                                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Avatar(id = match.accountId, name = match.username, size = 44.dp)
                                Column(
                                    Modifier.weight(1f).padding(start = 14.dp),
                                    verticalArrangement = Arrangement.spacedBy(2.dp),
                                ) {
                                    Text(match.username, style = MaterialTheme.typography.bodyLarge)
                                    Text(
                                        match.identifier,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                                TextButton(onClick = { onStart(match.username) }) {
                                    Text("Message")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun hasContacts(context: android.content.Context): Boolean =
    androidx.core.content.ContextCompat.checkSelfPermission(
        context,
        Manifest.permission.READ_CONTACTS,
    ) == android.content.pm.PackageManager.PERMISSION_GRANTED

/**
 * Every email address in the address book.
 *
 * Emails only, matching iOS: the directory is keyed on an email's OPRF token,
 * and phone numbers are not in it. They are read here and blinded immediately;
 * nothing keeps a copy.
 */
private fun readEmails(context: android.content.Context): List<String> = runCatching {
    val projection = arrayOf(android.provider.ContactsContract.CommonDataKinds.Email.ADDRESS)
    context.contentResolver.query(
        android.provider.ContactsContract.CommonDataKinds.Email.CONTENT_URI,
        projection,
        null,
        null,
        null,
    )?.use { cursor ->
        buildList {
            while (cursor.moveToNext()) {
                cursor.getString(0)?.trim()?.lowercase()?.takeIf { it.contains("@") }?.let(::add)
            }
        }.distinct()
    }.orEmpty()
}.getOrDefault(emptyList())
