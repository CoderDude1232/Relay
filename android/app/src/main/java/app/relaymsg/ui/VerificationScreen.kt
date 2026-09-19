package app.relaymsg.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** What the app believes about a peer's identity key. Mirrors the store's enum. */
enum class Verification { UNVERIFIED, VERIFIED, CHANGED, UNKNOWN }

/**
 * Safety-number verification.
 *
 * The number is derived from both identity keys and both account ids, so the
 * two devices compute the same sixty digits without exchanging anything. That
 * is what makes it worth checking: a relay that wanted to sit in the middle
 * would have to produce a matching number for a key it does not hold.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VerificationScreen(
    peerName: String,
    numeric: String?,
    scannableBase64: String?,
    state: Verification,
    onSetVerified: (Boolean) -> Unit,
    onScan: () -> Unit,
    scanResult: Boolean?,
    onDismissResult: () -> Unit,
    onBack: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Verify safety number") },
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
                .verticalScroll(rememberScrollState())
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (numeric == null) {
                Text(
                    "Send a message to $peerName first, then come back to verify.",
                    style = MaterialTheme.typography.bodyLarge,
                    textAlign = TextAlign.Center,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                return@Column
            }

            StatusBanner(state, peerName)
            Spacer(Modifier.height(20.dp))

            scannableBase64?.let { QrImage(it, size = 200.dp) }
            Spacer(Modifier.height(20.dp))

            SafetyNumberGrid(numeric)
            Spacer(Modifier.height(16.dp))
            Text(
                "Compare these numbers with $peerName in person, or over a call " +
                    "you already trust — or scan their code to check automatically.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )

            Spacer(Modifier.height(24.dp))
            Button(onClick = onScan, modifier = Modifier.fillMaxWidth()) {
                Text("Scan their code")
            }
            Spacer(Modifier.height(8.dp))
            OutlinedButton(
                onClick = { onSetVerified(state != Verification.VERIFIED) },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    if (state == Verification.VERIFIED) {
                        "Clear verification"
                    } else {
                        "Mark as verified"
                    },
                )
            }
        }
    }

    scanResult?.let { matched ->
        AlertDialog(
            onDismissRequest = onDismissResult,
            title = { Text(if (matched) "Verified" else "Codes don't match") },
            text = {
                Text(
                    if (matched) {
                        "The scanned code matches. $peerName is now marked verified."
                    } else {
                        // Stated plainly: a mismatch is the one outcome that
                        // means something may be badly wrong.
                        "This code does not match your safety number with " +
                            "$peerName. Do not trust this conversation until " +
                            "the numbers match."
                    },
                )
            },
            confirmButton = { TextButton(onClick = onDismissResult) { Text("OK") } },
        )
    }
}

@Composable
private fun StatusBanner(state: Verification, peerName: String) {
    val (text, container, ink) = when (state) {
        Verification.VERIFIED -> Triple(
            "Verified",
            MaterialTheme.colorScheme.primaryContainer,
            MaterialTheme.colorScheme.onPrimaryContainer,
        )
        // The one state worth alarming about: they were verified and the key
        // moved, which is either a reinstall or somebody else.
        Verification.CHANGED -> Triple(
            "$peerName's key has changed since you verified them. Verify again.",
            MaterialTheme.colorScheme.errorContainer,
            MaterialTheme.colorScheme.onErrorContainer,
        )
        else -> Triple(
            "Not verified yet",
            MaterialTheme.colorScheme.surfaceVariant,
            MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
    Text(
        text = text,
        style = MaterialTheme.typography.bodyMedium,
        color = ink,
        textAlign = TextAlign.Center,
        modifier = Modifier
            .fillMaxWidth()
            .background(container, RoundedCornerShape(12.dp))
            .padding(horizontal = 16.dp, vertical = 10.dp),
    )
}

/**
 * Sixty digits as twelve groups of five, three to a row.
 *
 * The same grouping iOS uses, so two people reading their screens to each other
 * are reading the same shape and can keep their place.
 */
@Composable
private fun SafetyNumberGrid(numeric: String) {
    val groups = numeric.filter { it.isDigit() }.chunked(5)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(14.dp))
            .padding(vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        groups.chunked(3).forEach { row ->
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly,
            ) {
                row.forEach { group ->
                    Text(
                        text = group,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 19.sp,
                        letterSpacing = 1.sp,
                    )
                }
            }
        }
    }
}
