package app.relaymsg.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.Image
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
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
    displayName: String,
    avatar: ByteArray?,
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
    blockedCount: Int,
    screenLock: Boolean,
    lockTimeout: Long,
    onScreenLock: (Boolean) -> Unit,
    onLockTimeout: (Long) -> Unit,
    panicEnabled: Boolean,
    onEnablePanic: (String) -> Unit,
    onDisablePanic: () -> Unit,
    onCreateInvite: () -> Unit,
    onShowBlocked: () -> Unit,
    onShowContactCard: () -> Unit,
    onShowContactSync: () -> Unit,
    scheduledCount: Int,
    onShowScheduled: () -> Unit,
    onEditProfile: () -> Unit,
    onRemoveDevice: (Int) -> Unit,
) {
    var confirmSignOut by remember { mutableStateOf(false) }
    var confirmClearCalls by remember { mutableStateOf(false) }
    var confirmRemove by remember { mutableStateOf<Int?>(null) }
    var showLockTimeout by remember { mutableStateOf(false) }
    var showPanicPin by remember { mutableStateOf(false) }

    Scaffold(topBar = { TopAppBar(title = { Text("Settings") }) }) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState()),
        ) {
            Profile(username, displayName, avatar, accountId, deviceId, onEditProfile)

            Section(
                title = "Account",
                footnote = "Your username link is permanent. An invite link works " +
                    "once and then expires, so handing one out does not publish " +
                    "who you are to anyone who later finds it.",
            ) {
                ActionRow("My code", publicLink.removePrefix("https://")) {
                    onShowContactCard()
                }
                RowDivider()
                ActionRow(
                    title = "Find contacts",
                    detail = "Check your address book against the directory",
                    onClick = onShowContactSync,
                )
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
                title = "Security",
                footnote = "The lock uses your phone's own unlock. Relay does " +
                    "not add a second PIN: the database key is already held in " +
                    "hardware, and a weaker credential guarding the same data " +
                    "would not help.",
            ) {
                SwitchRow(
                    title = "Screen lock",
                    detail = "Require fingerprint, face or PIN to open Relay.",
                    checked = screenLock,
                    onCheckedChange = onScreenLock,
                )
                if (screenLock) {
                    RowDivider()
                    ActionRow(
                        title = "Lock after",
                        detail = lockTimeout.lockLabel(),
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
                    onCheckedChange = { wanted ->
                        if (wanted) showPanicPin = true else onDisablePanic()
                    },
                )
            }

            Section(
                title = "Devices",
                footnote = "Linked devices share this account's identity, so your " +
                    "safety numbers do not change when you add one.",
            ) {
                devices.forEach { device ->
                    val isThis = device.deviceId == deviceId
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
                        // No remove on the device you are holding: that would
                        // leave this phone with keys it can no longer
                        // authenticate with, which reads as a broken app.
                        // Signing out is how you remove this one.
                        if (!isThis) {
                            TextButton(onClick = { confirmRemove = device.deviceId }) {
                                Text("Remove", color = MaterialTheme.colorScheme.error)
                            }
                        }
                    }
                    RowDivider()
                }
                if (devices.isEmpty()) {
                    InfoRow("Devices", "Checking\u2026")
                    RowDivider()
                }
                ActionRow("Link a device", "Scan the code shown on your other phone", onClick = onLinkDevice)
            }

            Section(
                title = "Chats",
                footnote = "Blocking is local: nothing is sent, so a blocked " +
                    "account cannot tell.",
            ) {
                ActionRow(
                    title = "Scheduled messages",
                    detail = if (scheduledCount == 0) "None" else "$scheduledCount waiting",
                    onClick = onShowScheduled,
                )
                RowDivider()
                ActionRow(
                    title = "Blocked contacts",
                    detail = if (blockedCount == 0) "None" else "$blockedCount blocked",
                    onClick = onShowBlocked,
                )
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

    if (showPanicPin) {
        var pin by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { showPanicPin = false },
            title = { Text("Set a PIN") },
            text = {
                Column {
                    Text(
                        "Four digits or more. There is no way to recover it — " +
                            "forget it and the hidden chats stay hidden.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.size(12.dp))
                    OutlinedTextField(
                        value = pin,
                        onValueChange = { pin = it.filter(Char::isDigit).take(12) },
                        label = { Text("PIN") },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled = pin.length >= 4,
                    onClick = { onEnablePanic(pin); showPanicPin = false },
                ) { Text("Set PIN") }
            },
            dismissButton = {
                TextButton(onClick = { showPanicPin = false }) { Text("Cancel") }
            },
        )
    }

    if (showLockTimeout) {
        val options = listOf(0L, 60L, 300L, 900L, 3_600L)
        AlertDialog(
            onDismissRequest = { showLockTimeout = false },
            title = { Text("Lock after") },
            text = {
                Column {
                    options.forEach { seconds ->
                        TextButton(
                            onClick = { onLockTimeout(seconds); showLockTimeout = false },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                text = seconds.lockLabel(),
                                modifier = Modifier.fillMaxWidth(),
                                fontWeight = if (seconds == lockTimeout) {
                                    FontWeight.Bold
                                } else {
                                    FontWeight.Normal
                                },
                            )
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showLockTimeout = false }) { Text("Cancel") }
            },
        )
    }

    confirmRemove?.let { target ->
        Confirm(
            title = "Remove device $target?",
            body = "It will no longer receive messages for this account, and " +
                "whoever holds it will have to link again.",
            confirmLabel = "Remove",
            onConfirm = { confirmRemove = null; onRemoveDevice(target) },
            onDismiss = { confirmRemove = null },
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
private fun Profile(
    username: String,
    displayName: String,
    avatar: ByteArray?,
    accountId: String,
    deviceId: Int,
    onEdit: () -> Unit,
) {
    val bitmap = remember(avatar) {
        avatar?.let {
            runCatching {
                android.graphics.BitmapFactory.decodeByteArray(it, 0, it.size)?.asImageBitmap()
            }.getOrNull()
        }
    }
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onEdit)
            .padding(horizontal = 20.dp, vertical = 20.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (bitmap != null) {
            Image(
                bitmap = bitmap,
                contentDescription = "Profile photo",
                modifier = Modifier.size(64.dp).clip(CircleShape),
                contentScale = ContentScale.Crop,
            )
        } else {
            Avatar(id = accountId, name = displayName.ifEmpty { username }.ifEmpty { "?" }, size = 64.dp)
        }
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(
                text = displayName.ifEmpty { username }.ifEmpty { "No username" },
                style = MaterialTheme.typography.headlineSmall,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                // The first block of the account id: enough to tell two
                // accounts apart when debugging, short enough to read out.
                text = if (displayName.isNotEmpty() && username.isNotEmpty()) {
                    "@$username · device $deviceId"
                } else {
                    "${accountId.take(8)} · device $deviceId"
                },
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

private fun Long.lockLabel(): String = when (this) {
    0L -> "Immediately"
    60L -> "After 1 minute"
    300L -> "After 5 minutes"
    900L -> "After 15 minutes"
    else -> "After 1 hour"
}
