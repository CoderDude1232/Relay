package app.relaymsg.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
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
import androidx.compose.ui.unit.dp
import app.relaymsg.net.LinkedDevice

/**
 * Settings and profile.
 *
 * Every row here does something. A switch that does not reach the relay, or a
 * count that is not the real device list, would be worse than an empty screen —
 * this is where someone checks whether their privacy settings are what they
 * think they are.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    username: String,
    accountId: String,
    deviceId: Int,
    server: String,
    privateCallMode: Boolean,
    pushIncludesContent: Boolean,
    devices: List<LinkedDevice>,
    onPrivateCallMode: (Boolean) -> Unit,
    onPushIncludesContent: (Boolean) -> Unit,
    onLinkDevice: () -> Unit,
    onClearCallLog: () -> Unit,
    onSignOut: () -> Unit,
    publicLink: String,
    inviteLink: String?,
    appVersion: String,
    onCreateInvite: () -> Unit,
) {
    var confirmSignOut by remember { mutableStateOf(false) }
    var confirmClearCalls by remember { mutableStateOf(false) }
    var showQr by remember { mutableStateOf(false) }

    Scaffold(topBar = { TopAppBar(title = { Text("Settings") }) }) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState()),
        ) {
            Profile(username, accountId, deviceId)

            Section(
                title = "Account",
                footnote = "Your username link is permanent. An invite link works " +
                    "once and then expires, so handing one out does not publish " +
                    "who you are to anyone who later finds it.",
            ) {
                ActionRow("My QR code", publicLink.removePrefix("https://")) {
                    showQr = true
                }
                RowDivider()
                ActionRow(
                    title = "Invite someone",
                    detail = if (inviteLink != null) "Tap to share again" else "Create a one-time link",
                    onClick = onCreateInvite,
                )
                RowDivider()
                InfoRow("Server", server.removePrefix("https://"))
            }

            Section(
                title = "Privacy & security",
                footnote = "Relay never sees your messages. These control what it, " +
                    "and the networks in between, can infer from around them.",
            ) {
                SwitchRow(
                    title = "Private Call Mode",
                    detail = "Relay every call through the TURN server so the other " +
                        "side never learns your IP address. Slower, and it falls " +
                        "back automatically if no relay is available.",
                    checked = privateCallMode,
                    onCheckedChange = onPrivateCallMode,
                )
                RowDivider()
                SwitchRow(
                    title = "Faster notifications",
                    detail = "Put the encrypted message inside the push so it opens " +
                        "instantly. Google then carries the ciphertext and its " +
                        "size, instead of an empty wake-up. Off is the private " +
                        "default.",
                    checked = pushIncludesContent,
                    onCheckedChange = onPushIncludesContent,
                )
            }

            Section(
                title = "Devices",
                footnote = "Linked devices share this account's identity, so your " +
                    "safety numbers do not change when you add one.",
            ) {
                devices.forEach { device ->
                    InfoRow(
                        title = if (device.deviceId == deviceId) "This phone" else "Linked device",
                        value = "Device ${device.deviceId}",
                    )
                    RowDivider()
                }
                if (devices.isEmpty()) {
                    InfoRow("Devices", "Checking\u2026")
                    RowDivider()
                }
                ActionRow("Link a device", "Scan the code shown on your other phone", onClick = onLinkDevice)
            }

            Section("Calls") {
                ActionRow(
                    title = "Clear call history",
                    detail = "The log is only on this phone.",
                    onClick = { confirmClearCalls = true },
                )
            }

            Section(
                title = "Danger zone",
                footnote = "Relay $appVersion",
            ) {
                ActionRow(
                    title = "Sign out",
                    detail = "Erases this device's keys and messages.",
                    destructive = true,
                    onClick = { confirmSignOut = true },
                )
            }

            Spacer(Modifier.height(32.dp))
        }
    }

    if (showQr) {
        AlertDialog(
            onDismissRequest = { showQr = false },
            title = { Text("My QR code") },
            text = {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    QrImage(publicLink, size = 220.dp)
                    Spacer(Modifier.height(12.dp))
                    Detail("Anyone who scans this can start a conversation with you.")
                }
            },
            confirmButton = { TextButton(onClick = { showQr = false }) { Text("Done") } },
        )
    }

    if (confirmSignOut) {
        Confirm(
            title = "Sign out?",
            // Said plainly, because it is not recoverable and the word "sign
            // out" suggests somewhere else it could be signed back in from.
            body = "This erases the keys and message history on this phone. " +
                "Unless you have another device linked, they cannot be recovered.",
            confirmLabel = "Sign out",
            onConfirm = { confirmSignOut = false; onSignOut() },
            onDismiss = { confirmSignOut = false },
        )
    }
    if (confirmClearCalls) {
        Confirm(
            title = "Clear call history?",
            body = "The log is only on this phone, so this removes it entirely.",
            confirmLabel = "Clear",
            onConfirm = { confirmClearCalls = false; onClearCallLog() },
            onDismiss = { confirmClearCalls = false },
        )
    }
}

@Composable
private fun Profile(username: String, accountId: String, deviceId: Int) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 20.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Avatar(id = accountId, name = username.ifEmpty { "?" }, size = 64.dp)
        Spacer(Modifier.width(16.dp))
        Column {
            Text(
                text = username.ifEmpty { "No username" },
                style = MaterialTheme.typography.headlineSmall,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                // The first block of the account id: enough to tell two
                // accounts apart when debugging, short enough to read out.
                text = "${accountId.take(8)} · device $deviceId",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * A titled group of rows, with an optional footnote underneath.
 *
 * Inset cards rather than full-bleed rows and dividers: it is how iOS's
 * settings reads, and it lets each group carry its own explanation without the
 * screen turning into a wall of small grey text.
 */
@Composable
private fun Section(
    title: String,
    footnote: String? = null,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    Text(
        text = title.uppercase(),
        style = MaterialTheme.typography.labelMedium,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 32.dp, end = 20.dp, top = 24.dp, bottom = 7.dp),
    )
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant,
        shape = RoundedCornerShape(18.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
    ) {
        Column(content = content)
    }
    footnote?.let {
        Text(
            text = it,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp),
        )
    }
}

@Composable
private fun SwitchRow(
    title: String,
    detail: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable { onCheckedChange(!checked) }
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Spacer(Modifier.height(2.dp))
            Detail(detail)
        }
        Spacer(Modifier.width(16.dp))
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

@Composable
private fun ActionRow(
    title: String,
    detail: String,
    destructive: Boolean = false,
    onClick: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.bodyLarge,
            color = if (destructive) {
                MaterialTheme.colorScheme.error
            } else {
                MaterialTheme.colorScheme.onSurface
            },
        )
        Detail(detail)
    }
}

@Composable
private fun InfoRow(title: String, value: String) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Hairline between rows inside a card; inset so it does not touch the corners. */
@Composable
private fun RowDivider() = HorizontalDivider(
    color = MaterialTheme.colorScheme.outlineVariant,
    modifier = Modifier.padding(start = 16.dp),
)

@Composable
private fun Detail(text: String, modifier: Modifier = Modifier) = Text(
    text = text,
    style = MaterialTheme.typography.bodySmall,
    color = MaterialTheme.colorScheme.onSurfaceVariant,
    modifier = modifier,
)

@Composable
private fun Confirm(
    title: String,
    body: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) = AlertDialog(
    onDismissRequest = onDismiss,
    title = { Text(title) },
    text = { Text(body) },
    confirmButton = {
        TextButton(onClick = onConfirm) {
            Text(confirmLabel, color = MaterialTheme.colorScheme.error)
        }
    },
    dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
)
