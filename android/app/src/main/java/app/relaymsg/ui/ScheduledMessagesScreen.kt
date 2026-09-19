package app.relaymsg.ui

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
import androidx.compose.material.icons.automirrored.filled.ArrowBack
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.relaymsg.core.RelayService
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Messages queued to send later.
 *
 * The screen states the real constraint plainly: nothing wakes the app to send
 * one, so a message scheduled for the small hours goes out when the app next
 * runs. Better said here than discovered by someone whose message did not
 * arrive at 9am.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScheduledMessagesScreen(
    messages: List<RelayService.ScheduledMessage>,
    titleFor: (conversationId: String) -> String,
    onCancel: (id: String) -> Unit,
    onBack: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Scheduled") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        if (messages.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.padding(horizontal = 40.dp),
                ) {
                    Text("Nothing scheduled", style = MaterialTheme.typography.titleLarge)
                    Spacer(Modifier.size(6.dp))
                    Text(
                        "Hold the send button in a conversation to schedule a " +
                            "message.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                }
            }
            return@Scaffold
        }

        Column(Modifier.fillMaxSize().padding(padding)) {
            Text(
                "Relay has to be running to send these. One scheduled while the " +
                    "phone is asleep goes out when the app next opens.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
            )
            LazyColumn {
                items(messages, key = { it.id }) { message ->
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(
                                titleFor(message.conversationId),
                                style = MaterialTheme.typography.bodyLarge,
                            )
                            Text(
                                message.body,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                message.scheduledAt.asScheduleTime(),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.primary,
                            )
                        }
                        TextButton(onClick = { onCancel(message.id) }) {
                            Text("Cancel", color = MaterialTheme.colorScheme.error)
                        }
                    }
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                }
            }
        }
    }
}

private val scheduleFormat = SimpleDateFormat("EEE d MMM, HH:mm", Locale.getDefault())

/** Seconds on the wire, milliseconds in Java — an easy factor of 1000 to lose. */
private fun Double.asScheduleTime(): String {
    val millis = (this * 1000).toLong()
    val overdue = millis < System.currentTimeMillis()
    return scheduleFormat.format(Date(millis)) + if (overdue) " · sending soon" else ""
}
