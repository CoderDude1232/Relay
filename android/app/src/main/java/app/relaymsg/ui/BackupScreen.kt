package app.relaymsg.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Backup and restore.
 *
 * Two mechanisms, both iOS's. The Recovery Key backup produces the same blob
 * iOS puts in iCloud — same key derivation, same AES-GCM layout — so a backup
 * moves between the two clients. The password export is the one-off file.
 *
 * The difference from iOS is where the blob lands: there is no CloudKit here,
 * so the user picks a destination and Android hands the bytes to whatever they
 * chose — Drive, Files, a USB stick. Relay never sees plaintext either way, and
 * neither does whoever is storing it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BackupScreen(
    enabled: Boolean,
    lastBackupAt: Long?,
    recoveryKey: () -> String,
    onSetEnabled: (Boolean) -> Unit,
    onWriteBackup: (Uri, (String?) -> Unit) -> Unit,
    onRestore: (Uri, String, (String?) -> Unit) -> Unit,
    onExportWithPassword: (Uri, String, (String?) -> Unit) -> Unit,
    onImportWithPassword: (Uri, String, (String?) -> Unit) -> Unit,
    onBack: () -> Unit,
) {
    var showKey by remember { mutableStateOf(false) }
    var askRestoreKey by remember { mutableStateOf<Uri?>(null) }
    var askImportPassword by remember { mutableStateOf<Uri?>(null) }
    var password by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    fun finish(failure: String?, success: String) {
        busy = false
        error = failure
        message = if (failure == null) success else null
    }

    val createBackup = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument(MIME),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        busy = true
        onWriteBackup(uri) { finish(it, "Backed up.") }
    }

    val openBackup = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> askRestoreKey = uri }

    val exportWithPassword = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument(MIME),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        busy = true
        onExportWithPassword(uri, password) { failure ->
            if (failure == null) { password = ""; confirm = "" }
            finish(failure, "Exported.")
        }
    }

    val openPasswordBackup = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> askImportPassword = uri }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Backup & restore") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState()),
        ) {
            Section(
                title = "Recovery Key backup",
                footnote = buildString {
                    append(
                        "Messages are encrypted with your Recovery Key before they " +
                            "leave this phone. Whoever stores the file cannot read it, " +
                            "and losing the key means losing the backup — nobody, " +
                            "Relay included, can recover it for you.",
                    )
                    if (busy) {
                        append("\n\nWorking…")
                    } else {
                        error?.let { append("\n\n⚠️ $it") }
                        message?.let { append("\n\n$it") }
                        lastBackupAt?.let { append("\n\nLast backup: ${it.asBackupTime()}") }
                    }
                },
            ) {
                SwitchRow(
                    title = "Back up my messages",
                    detail = "Generates a Recovery Key and lets you save an encrypted copy.",
                    checked = enabled,
                    onCheckedChange = { on ->
                        onSetEnabled(on)
                        if (on) showKey = true
                    },
                )
                if (enabled) {
                    RowDivider()
                    ActionRow(
                        title = "View Recovery Key",
                        detail = "Write it down. It is the only way back in.",
                        onClick = { showKey = true },
                    )
                    RowDivider()
                    ActionRow(
                        title = "Back up now",
                        detail = "Choose where to save the encrypted file.",
                        onClick = {
                            error = null
                            message = null
                            createBackup.launch("relay-backup-${today()}.relaybackup")
                        },
                    )
                }
            }

            Section(
                title = "Restore",
                footnote = "Restores messages from a backup file using its Recovery " +
                    "Key. Anything already on this phone is kept — restoring twice " +
                    "changes nothing.",
            ) {
                ActionRow(
                    title = "Restore from a backup",
                    detail = "Pick the file, then enter its Recovery Key.",
                    onClick = {
                        error = null
                        message = null
                        openBackup.launch(arrayOf("*/*"))
                    },
                )
            }

            Section(
                title = "Password export",
                footnote = "A one-off encrypted file protected by a password instead " +
                    "of the Recovery Key. AES-256-GCM, same as the backup — Relay " +
                    "cannot recover the password if you lose it.",
            ) {
                Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                    OutlinedTextField(
                        value = password,
                        onValueChange = { password = it },
                        label = { Text("Password (at least 8 characters)") },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value = confirm,
                        onValueChange = { confirm = it },
                        label = { Text("Confirm password") },
                        singleLine = true,
                        isError = confirm.isNotEmpty() && confirm != password,
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.End,
                    ) {
                        TextButton(
                            enabled = !busy,
                            onClick = {
                                error = null
                                message = null
                                openPasswordBackup.launch(arrayOf("*/*"))
                            },
                        ) { Text("Import…") }
                        TextButton(
                            enabled = !busy && password.length >= 8 && password == confirm,
                            onClick = {
                                error = null
                                message = null
                                exportWithPassword.launch("relay-export-${today()}.relaybackup")
                            },
                        ) { Text("Export…") }
                    }
                }
            }

            Spacer(Modifier.height(32.dp))
        }
    }

    if (showKey) {
        RecoveryKeyDialog(key = recoveryKey(), onDismiss = { showKey = false })
    }

    askRestoreKey?.let { uri ->
        KeyPromptDialog(
            title = "Recovery Key",
            label = "Recovery Key",
            explanation = "Enter the key you wrote down when this backup was made.",
            confirmLabel = "Restore",
            onDismiss = { askRestoreKey = null },
            onConfirm = { key ->
                askRestoreKey = null
                busy = true
                onRestore(uri, key) { finish(it, "Restored.") }
            },
        )
    }

    askImportPassword?.let { uri ->
        KeyPromptDialog(
            title = "Import",
            label = "Password",
            explanation = "Enter the password this file was exported with.",
            confirmLabel = "Import",
            masked = true,
            onDismiss = { askImportPassword = null },
            onConfirm = { entered ->
                askImportPassword = null
                busy = true
                onImportWithPassword(uri, entered) { finish(it, "Imported.") }
            },
        )
    }
}

@Composable
private fun RecoveryKeyDialog(key: String, onDismiss: () -> Unit) {
    val clipboard = LocalClipboardManager.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Your Recovery Key") },
        text = {
            Column {
                Text(
                    "Write this down and keep it somewhere safe. It is the only " +
                        "way to open your backup — Relay cannot recover it for you.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(16.dp))
                Text(
                    text = key,
                    style = MaterialTheme.typography.titleMedium,
                    fontFamily = FontFamily.Monospace,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        dismissButton = {
            TextButton(onClick = { clipboard.setText(AnnotatedString(key)) }) { Text("Copy") }
        },
    )
}

@Composable
private fun KeyPromptDialog(
    title: String,
    label: String,
    explanation: String,
    confirmLabel: String,
    masked: Boolean = false,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var entry by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column {
                Text(
                    explanation,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = entry,
                    onValueChange = { entry = it },
                    label = { Text(label) },
                    singleLine = !masked,
                    visualTransformation = if (masked) {
                        PasswordVisualTransformation()
                    } else {
                        androidx.compose.ui.text.input.VisualTransformation.None
                    },
                    keyboardOptions = KeyboardOptions(
                        keyboardType = if (masked) KeyboardType.Password else KeyboardType.Ascii,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(enabled = entry.isNotBlank(), onClick = { onConfirm(entry) }) {
                Text(confirmLabel)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/**
 * An opaque type: the file is ciphertext, and calling it JSON would invite a
 * viewer to try to open it.
 */
private const val MIME = "application/octet-stream"

private fun today(): String =
    SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())

private fun Long.asBackupTime(): String =
    SimpleDateFormat("d MMM yyyy, h:mm a", Locale.getDefault()).format(Date(this))
