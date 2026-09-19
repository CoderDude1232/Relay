package app.relaymsg.ui

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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.relaymsg.storage.Conversation

/**
 * Creating a group.
 *
 * Members are picked from existing conversations rather than typed: a group
 * send needs a resolvable username for every member, and the people you have
 * already messaged are exactly the ones that resolve. Anyone else can be added
 * from the group's own page once it exists.
 */
@Composable
fun NewGroupScreen(
    conversations: List<Conversation>,
    titleFor: (Conversation) -> String,
    busy: Boolean,
    onCreate: (name: String, members: List<String>) -> Unit,
    onBack: () -> Unit,
) {
    var name by remember { mutableStateOf("") }
    var picked by remember { mutableStateOf<Set<String>>(emptySet()) }

    // Only 1:1 threads with a username: a group cannot contain a group, and a
    // peer whose username is unknown cannot be resolved at send time.
    val candidates = remember(conversations) {
        conversations
            .filter { it.groupId == null && !it.peerUsername.isNullOrBlank() }
            .sortedBy { titleFor(it).lowercase() }
    }

    Column(Modifier.fillMaxSize()) {
        LargeTitle("New Group") {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircleAction(
                    icon = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    onClick = onBack,
                )
                if (busy) {
                    CircularProgressIndicator(Modifier.size(24.dp))
                } else if (name.isNotBlank() && picked.isNotEmpty()) {
                    PillButton("Create") {
                        onCreate(name, picked.toList())
                    }
                }
            }
        }

        OutlinedTextField(
            value = name,
            onValueChange = { name = it },
            label = { Text("Group name") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = if (picked.isEmpty()) {
                "Choose who to add"
            } else {
                "${picked.size} selected"
            },
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 20.dp, top = 8.dp, bottom = 4.dp),
        )

        if (candidates.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    "Message someone first — a group is built from people you " +
                        "already have a conversation with.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(horizontal = 40.dp),
                )
            }
            return@Column
        }

        LazyColumn(Modifier.fillMaxSize()) {
            items(candidates, key = { it.id }) { conversation ->
                val username = conversation.peerUsername.orEmpty()
                val selected = username in picked
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable {
                            picked = if (selected) picked - username else picked + username
                        }
                        .padding(horizontal = 20.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Avatar(
                        id = conversation.peerAccount,
                        name = titleFor(conversation),
                        size = 44.dp,
                    )
                    Spacer(Modifier.width(16.dp))
                    Text(
                        text = titleFor(conversation),
                        style = MaterialTheme.typography.bodyLarge,
                        modifier = Modifier.weight(1f),
                    )
                    if (selected) {
                        Icon(
                            Icons.Filled.Check,
                            contentDescription = "Selected",
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    }
                }
            }
            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

/**
 * Starting a chat from a username.
 *
 * Its own screen rather than the inline form it replaces: from the sheet it is
 * one of four equal choices, and a field that unfolded in the middle of the
 * conversation list gave no room to say what went wrong.
 */
@Composable
fun FindByUsernameScreen(
    busy: Boolean,
    onStart: (username: String, onError: (String) -> Unit) -> Unit,
    onBack: () -> Unit,
) {
    var username by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }

    Column(Modifier.fillMaxSize()) {
        LargeTitle("Find by username") {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircleAction(
                    icon = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    onClick = onBack,
                )
                if (busy) {
                    CircularProgressIndicator(Modifier.size(24.dp))
                } else if (username.isNotBlank()) {
                    PillButton("Start") {
                        error = null
                        onStart(username) { error = it }
                    }
                }
            }
        }

        OutlinedTextField(
            value = username,
            onValueChange = { username = it; error = null },
            label = { Text("Username") },
            prefix = { Text("@") },
            singleLine = true,
            isError = error != null,
            supportingText = error?.let { { Text(it) } },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        )
        Spacer(Modifier.height(10.dp))
        Text(
            "Usernames are how Relay finds people without a phone number. " +
                "Yours is on your profile.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 20.dp),
        )
    }
}
