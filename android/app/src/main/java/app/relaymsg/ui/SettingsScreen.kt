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
) {
    var confirmSignOut by remember { mutableStateOf(false) }
    var confirmClearCalls by remember { mutableStateOf(false) }

    Scaffold(topBar = { TopAppBar(title = { Text("Settings") }) }) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState()),
        ) {
            Profile(username, accountId, deviceId)

            Section("Privacy")
            SwitchRow(
                title = "Private Call Mode",
                detail = "Relay every call through the TURN server so the other " +
                    "side never learns your IP address. Slower, and it falls back " +
                    "automatically if no relay is available.",
                checked = privateCallMode,
                onCheckedChange = onPrivateCallMode,
            )
            SwitchRow(
                title = "Faster notifications",
                detail = "Put the encrypted message inside the push so it opens " +
                    "instantly. Google then carries the ciphertext and its size, " +
                    "instead of an empty wake-up. Off is the private default.",
                checked = pushIncludesContent,
                onCheckedChange = onPushIncludesContent,
            )

            Section("Devices")
            devices.forEach { device ->
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            if (device.deviceId == deviceId) "This phone" else "Linked device",
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        Text(
                            "Device ${device.deviceId}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
            if (devices.isEmpty()) {
                Detail("Checking…", Modifier.padding(horizontal = 20.dp, vertical = 12.dp))
            }
            ActionRow("Link a device", "Scan the code shown on your other phone", onLinkDevice)

            Section("Calls")
            ActionRow(
                title = "Clear call history",
                detail = "Removes the log from this device. It is not stored anywhere else.",
                onClick = { confirmClearCalls = true },
            )

            Section("Account")
            InfoRow("Server", server.removePrefix("https://"))
            ActionRow(
                title = "Sign out",
                detail = "Erases this device's keys and messages. Without a linked " +
                    "device or a backup, they are gone.",
                destructive = true,
                onClick = { confirmSignOut = true },
            )

            Spacer(Modifier.height(24.dp))
            Text(
                "Relay for Android · end-to-end encrypted",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.fillMaxWidth().padding(bottom = 24.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
        }
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

@Composable
private fun Section(title: String) {
    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
    Text(
        text = title.uppercase(),
        style = MaterialTheme.typography.labelMedium,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 20.dp, bottom = 4.dp),
    )
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
            .padding(horizontal = 20.dp, vertical = 12.dp),
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
    onClick: () -> Unit,
    destructive: Boolean = false,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 12.dp),
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
        Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
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
