package app.relaymsg.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CallMade
import androidx.compose.material.icons.automirrored.filled.CallMissed
import androidx.compose.material.icons.automirrored.filled.CallReceived
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import app.relaymsg.storage.StoredCall
import app.relaymsg.storage.StoredCallDirection
import app.relaymsg.storage.StoredCallKind
import app.relaymsg.storage.StoredCallOutcome
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Call history.
 *
 * Local only — the log is never sent anywhere and is not part of the encrypted
 * backup on either client, so it exists on exactly the device that made the
 * call. Clearing it is immediate and total, which is the point.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CallLogScreen(
    calls: List<StoredCall>,
    onClear: () -> Unit,
    onCall: (peerAccount: String, isVideo: Boolean) -> Unit,
) {
    Scaffold(
        topBar = {
            androidx.compose.material3.TopAppBar(
                title = { Text("Calls") },
                actions = {
                    if (calls.isNotEmpty()) {
                        TextButton(onClick = onClear) { Text("Clear") }
                    }
                },
            )
        },
    ) { padding ->
        if (calls.isEmpty()) {
            Box(
                Modifier.fillMaxSize().padding(padding),
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.padding(horizontal = 40.dp),
                ) {
                    Text("No calls yet", style = MaterialTheme.typography.titleLarge)
                    Spacer(Modifier.size(6.dp))
                    Text(
                        "Calls are encrypted end to end, and the log stays on " +
                            "this phone.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
                }
            }
            return@Scaffold
        }

        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            items(calls, key = { it.id }) { call ->
                CallRow(call, onCall)
                HorizontalDivider()
            }
        }
    }
}

@Composable
private fun CallRow(call: StoredCall, onCall: (String, Boolean) -> Unit) {
    val missed = call.outcome == StoredCallOutcome.MISSED
    Row(
        modifier = Modifier
            .fillMaxWidth()
            // Tapping redials in the same medium it was: a missed video call is
            // most likely to be returned as a video call.
            .clickable { onCall(call.peerAccount, call.kind == StoredCallKind.VIDEO) }
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Avatar(id = call.peerAccount, name = call.peerName, size = 44.dp)
        Column(
            Modifier.weight(1f).padding(start = 14.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = call.peerName,
                style = MaterialTheme.typography.bodyLarge,
                color = if (missed) MaterialTheme.colorScheme.error else Color.Unspecified,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = when {
                        missed -> Icons.AutoMirrored.Filled.CallMissed
                        call.direction == StoredCallDirection.OUTGOING ->
                            Icons.AutoMirrored.Filled.CallMade
                        else -> Icons.AutoMirrored.Filled.CallReceived
                    },
                    contentDescription = null,
                    tint = if (missed) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                    modifier = Modifier.size(14.dp),
                )
                Spacer(Modifier.size(5.dp))
                Text(
                    text = call.summary(),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        if (call.kind == StoredCallKind.VIDEO) {
            Icon(
                Icons.Filled.Videocam,
                contentDescription = "Video call",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

/** "Missed · 14:02" or "Outgoing · 14:02 · 3:21". */
private fun StoredCall.summary(): String {
    val label = when (outcome) {
        StoredCallOutcome.MISSED -> "Missed"
        StoredCallOutcome.DECLINED -> "Declined"
        // "Failed" covers never-connected and dropped alike; the user does not
        // need the distinction, and claiming to know which would often be wrong.
        StoredCallOutcome.FAILED -> "Not connected"
        StoredCallOutcome.COMPLETED ->
            if (direction == StoredCallDirection.OUTGOING) "Outgoing" else "Incoming"
    }
    val time = callLogTime.format(Date(startedAt))
    val duration = connectedAt?.let { start ->
        endedAt?.let { end ->
            val seconds = ((end - start) / 1000).coerceAtLeast(0)
            " · %d:%02d".format(seconds / 60, seconds % 60)
        }
    }.orEmpty()
    return "$label · $time$duration"
}

private val callLogTime = SimpleDateFormat("d MMM, HH:mm", Locale.getDefault())
