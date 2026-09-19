package app.relaymsg.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import app.relaymsg.storage.StoredGroup

/**
 * Group membership and settings.
 *
 * The relay stores no group state at all: the roster here **is** the group, as
 * far as this device is concerned, and it is kept in step with everyone else's
 * only by the updates they exchange. So every change made here is announced,
 * and a change nobody can announce is not offered.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupInfoScreen(
    group: StoredGroup,
    ownAccount: String,
    nameFor: (String) -> String,
    busy: Boolean,
    onRename: (String) -> Unit,
    onAddMember: (String) -> Unit,
    onRemoveMember: (String) -> Unit,
    onSetAdmin: (account: String, admin: Boolean) -> Unit,
    onSetAnnounceOnly: (Boolean) -> Unit,
    onLeave: () -> Unit,
    onBack: () -> Unit,
) {
    val isAdmin = ownAccount in group.admins
    var rename by remember(group.name) { mutableStateOf(group.name) }
    var newMember by remember { mutableStateOf("") }
    var confirmRemove by remember { mutableStateOf<String?>(null) }
    var confirmLeave by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Group info") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()),
        ) {
            Column(
                Modifier.fillMaxWidth().padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Avatar(id = group.id, name = group.name, size = 72.dp)
                Spacer(Modifier.height(10.dp))
                Text(group.name, style = MaterialTheme.typography.headlineSmall)
                Text(
                    "${group.members.size} members",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            if (isAdmin) {
                SectionLabel("Name")
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 20.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    OutlinedTextField(
                        value = rename,
                        onValueChange = { rename = it.take(64) },
                        singleLine = true,
                        enabled = !busy,
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(
                        enabled = rename.isNotBlank() && rename != group.name && !busy,
                        onClick = { onRename(rename) },
                    ) { Text("Save") }
                }

                SectionLabel("Posting")
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("Admins only", style = MaterialTheme.typography.bodyLarge)
                        Text(
                            // Honest about the limit: the roster is client-side,
                            // so this is a convention the other clients keep, not
                            // something a server refuses.
                            "Other members' apps will stop them posting. Nothing " +
                                "on the server enforces it.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    Switch(
                        checked = group.isAnnounceOnly,
                        onCheckedChange = onSetAnnounceOnly,
                        enabled = !busy,
                    )
                }

                SectionLabel("Add someone")
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 20.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    OutlinedTextField(
                        value = newMember,
                        onValueChange = { newMember = it.trim() },
                        placeholder = { Text("Username") },
                        singleLine = true,
                        enabled = !busy,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(
                        enabled = newMember.isNotBlank() && !busy,
                        onClick = { onAddMember(newMember); newMember = "" },
                    ) { Text("Add") }
                }
            }

            SectionLabel("Members")
            group.members.sortedBy { nameFor(it).lowercase() }.forEach { account ->
                val memberIsAdmin = account in group.admins
                val isSelf = account == ownAccount
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Avatar(id = account, name = nameFor(account), size = 40.dp)
                    Column(Modifier.weight(1f).padding(start = 12.dp)) {
                        Text(
                            text = if (isSelf) "You" else nameFor(account),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        if (memberIsAdmin) {
                            Text(
                                "Admin",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.primary,
                            )
                        }
                    }
                    if (isAdmin && !isSelf) {
                        TextButton(
                            enabled = !busy,
                            onClick = { onSetAdmin(account, !memberIsAdmin) },
                        ) { Text(if (memberIsAdmin) "Demote" else "Promote") }
                        TextButton(enabled = !busy, onClick = { confirmRemove = account }) {
                            Text("Remove", color = MaterialTheme.colorScheme.error)
                        }
                    }
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            }

            TextButton(
                onClick = { confirmLeave = true },
                enabled = !busy,
                modifier = Modifier.fillMaxWidth().padding(20.dp),
            ) { Text("Leave group", color = MaterialTheme.colorScheme.error) }
        }
    }

    confirmRemove?.let { account ->
        AlertDialog(
            onDismissRequest = { confirmRemove = null },
            title = { Text("Remove ${nameFor(account)}?") },
            text = {
                Text(
                    // Worth saying: removal rotates the group's keys, so they
                    // cannot read anything sent afterwards.
                    "They will stop receiving messages, and the group's keys " +
                        "change so they cannot read anything sent from now on.",
                )
            },
            confirmButton = {
                TextButton(onClick = { onRemoveMember(account); confirmRemove = null }) {
                    Text("Remove", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmRemove = null }) { Text("Cancel") }
            },
        )
    }

    if (confirmLeave) {
        AlertDialog(
            onDismissRequest = { confirmLeave = false },
            title = { Text("Leave ${group.name}?") },
            text = { Text("The conversation is removed from this phone.") },
            confirmButton = {
                TextButton(onClick = { confirmLeave = false; onLeave() }) {
                    Text("Leave", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmLeave = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun SectionLabel(text: String) = Text(
    text = text.uppercase(),
    style = MaterialTheme.typography.labelMedium,
    fontWeight = FontWeight.SemiBold,
    color = MaterialTheme.colorScheme.primary,
    modifier = Modifier.padding(start = 20.dp, top = 18.dp, bottom = 6.dp),
)
