package app.relaymsg.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import app.relaymsg.net.LinkedDevice

/**
 * The settings that live one level down.
 *
 * Everything used to be on a single scroll, which meant the screen lock sat
 * three screens below the profile card and nobody found it. Each of these is a
 * row on the Profile page that opens its own page — the shape iOS uses, and the
 * reason its Settings app stays navigable with far more in it than this.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsPage(
    title: String,
    onBack: () -> Unit,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    Scaffold(containerColor = MaterialTheme.colorScheme.surfaceVariant) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState()),
        ) {
            LargeTitle(title) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    CircleAction(
                        icon = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back",
                        onClick = onBack,
                    )
                }
            }
            content()
            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
fun PrivacySettingsScreen(
    privateCallMode: Boolean,
    pushIncludesContent: Boolean,
    onPrivateCallMode: (Boolean) -> Unit,
    onPushIncludesContent: (Boolean) -> Unit,
    onBack: () -> Unit,
) {
    SettingsPage("Privacy", onBack) {
        Section(
            title = "Metadata",
            footnote = "Relay never sees your messages. These control what it, " +
                "and the networks in between, can infer from around them.",
        ) {
            SwitchRow(
                title = "Private Call Mode",
                detail = "Relay every call through the TURN server so the other " +
                    "side never learns your IP address. Slower, and it falls " +
                    "back automatically if no relay is available.",
                checked = privateCallMode,
                icon = Icons.Filled.Call,
                tint = TileGreen,
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
                icon = Icons.Filled.Notifications,
                tint = TileOrange,
                onCheckedChange = onPushIncludesContent,
            )
        }
    }
}

@Composable
fun SecuritySettingsScreen(
    screenLock: Boolean,
    lockTimeout: Long,
    panicEnabled: Boolean,
    onScreenLock: (Boolean) -> Unit,
    onLockTimeout: (Long) -> Unit,
    onEnablePanic: (String) -> Unit,
    onDisablePanic: () -> Unit,
    onBack: () -> Unit,
) {
    var showLockTimeout by remember { mutableStateOf(false) }
    var showPanicPin by remember { mutableStateOf(false) }

    SettingsPage("Security", onBack) {
        Section(
            title = "This phone",
            footnote = "The lock uses your phone's own unlock. Relay does " +
                "not add a second PIN: the database key is already held in " +
                "hardware, and a weaker credential guarding the same data " +
                "would not help.",
        ) {
            SwitchRow(
                title = "Screen lock",
                detail = "Require fingerprint, face or PIN to open Relay.",
                checked = screenLock,
                icon = Icons.Filled.Lock,
                tint = TileGreen,
                onCheckedChange = onScreenLock,
            )
            if (screenLock) {
                RowDivider()
                ActionRow(
                    title = "Lock after",
                    detail = lockTimeout.lockLabel(),
                    icon = Icons.Filled.Schedule,
                    tint = TileGrey,
                    onClick = { showLockTimeout = true },
                )
            }
            RowDivider()
            SwitchRow(
                title = "Hidden chats",
                detail = "Set a second PIN, then long-press a conversation " +
                    "to hide it. Hidden chats are absent from the list, not " +
                    "marked as locked.",
                checked = panicEnabled,
                icon = Icons.Filled.VisibilityOff,
                tint = TileIndigo,
                onCheckedChange = { wanted ->
                    if (wanted) showPanicPin = true else onDisablePanic()
                },
            )
        }
    }

    if (showLockTimeout) {
        LockTimeoutDialog(
            current = lockTimeout,
            onPick = { onLockTimeout(it); showLockTimeout = false },
            onDismiss = { showLockTimeout = false },
        )
    }
    if (showPanicPin) {
        PanicPinDialog(
            onSet = { onEnablePanic(it); showPanicPin = false },
            onDismiss = { showPanicPin = false },
        )
    }
}

@Composable
fun DevicesSettingsScreen(
    devices: List<LinkedDevice>,
    thisDeviceId: Int,
    onLinkDevice: () -> Unit,
    onRemoveDevice: (Int) -> Unit,
    onBack: () -> Unit,
) {
    var confirmRemove by remember { mutableStateOf<Int?>(null) }

    SettingsPage("Linked devices", onBack) {
        Section(
            title = "Devices",
            footnote = "Linked devices share this account's identity, so your " +
                "safety numbers do not change when you add one.",
        ) {
            devices.forEach { device ->
                val isThis = device.deviceId == thisDeviceId
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            if (isThis) "This phone" else "Linked device",
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        Detail("Device ${device.deviceId}")
                    }
                    // No remove on the device you are holding: that would leave
                    // this phone with keys it can no longer authenticate with,
                    // which reads as a broken app. Signing out removes this one.
                    if (!isThis) {
                        TextButton(onClick = { confirmRemove = device.deviceId }) {
                            Text("Remove", color = MaterialTheme.colorScheme.error)
                        }
                    }
                }
                RowDivider(inset = 16.dp)
            }
            if (devices.isEmpty()) {
                InfoRow("Devices", "Checking…")
                RowDivider(inset = 16.dp)
            }
            ActionRow(
                title = "Link a device",
                detail = "Scan the code shown on your other phone",
                icon = Icons.Filled.Devices,
                tint = TileBlue,
                onClick = onLinkDevice,
            )
        }
    }

    confirmRemove?.let { id ->
        AlertDialog(
            onDismissRequest = { confirmRemove = null },
            title = { Text("Remove device $id?") },
            text = {
                Text(
                    "It stops receiving messages immediately. Anything already " +
                        "on it stays there — removing a device does not wipe it.",
                )
            },
            confirmButton = {
                TextButton(onClick = { onRemoveDevice(id); confirmRemove = null }) {
                    Text("Remove", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { confirmRemove = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun LockTimeoutDialog(current: Long, onPick: (Long) -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Lock after") },
        text = {
            Column {
                listOf(0L, 60L, 300L, 900L, 3600L).forEach { seconds ->
                    TextButton(
                        onClick = { onPick(seconds) },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            text = seconds.lockLabel() + if (seconds == current) "  ✓" else "",
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun PanicPinDialog(onSet: (String) -> Unit, onDismiss: () -> Unit) {
    var pin by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Set a PIN") },
        text = {
            Column {
                Text(
                    "Four digits or more. Forgetting it leaves the hidden chats " +
                        "hidden — there is no reset.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = pin,
                    onValueChange = { entered -> pin = entered.filter(Char::isDigit) },
                    label = { Text("PIN") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(enabled = pin.length >= 4, onClick = { onSet(pin) }) { Text("Set") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
