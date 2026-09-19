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
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.relaymsg.storage.StoredProfile

/**
 * A peer's profile, as they published it.
 *
 * Everything here arrived inside an end-to-end-encrypted `ProfileUpdate` over
 * the pairwise session — the relay holds no display name, status or bio, so
 * there is no directory of these to scrape. Placement follows iOS: the status
 * is a line under the name, the bio gets its own section.
 *
 * Fields the peer has not set are absent rather than shown empty; a profile
 * with nothing filled in should look like a profile, not like a form.
 */
@Composable
fun PeerProfileScreen(
    account: String,
    displayName: String,
    username: String?,
    profile: StoredProfile?,
    isBlocked: Boolean,
    onVerify: (() -> Unit)?,
    onToggleBlock: (() -> Unit)?,
    onBack: () -> Unit,
) {
    Scaffold(containerColor = MaterialTheme.colorScheme.surfaceVariant) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState()),
        ) {
            LargeTitle("Profile") {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    CircleAction(
                        icon = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back",
                        onClick = onBack,
                    )
                }
            }

            Column(
                Modifier.fillMaxWidth().padding(horizontal = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Avatar(
                    id = account,
                    name = displayName,
                    size = 112.dp,
                    imageData = profile?.avatarData,
                )
                Spacer(Modifier.height(14.dp))
                Text(
                    text = displayName,
                    fontSize = 26.sp,
                    fontWeight = FontWeight.Bold,
                    textAlign = TextAlign.Center,
                )
                profile?.status?.takeIf { it.isNotBlank() }?.let { status ->
                    Spacer(Modifier.height(4.dp))
                    Text(
                        text = status,
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                }
                username?.takeIf { it.isNotBlank() }?.let {
                    Spacer(Modifier.height(6.dp))
                    Text(
                        text = "@$it",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
            }

            Spacer(Modifier.height(24.dp))

            profile?.bio?.takeIf { it.isNotBlank() }?.let { bio ->
                Section("Bio") {
                    Text(
                        text = bio,
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
                    )
                }
            }

            if (onVerify != null || onToggleBlock != null) {
                Section(
                    title = "Safety",
                    footnote = "Blocking is local: nothing is sent, so a blocked " +
                        "account cannot tell.",
                ) {
                    onVerify?.let {
                        ActionRow(
                            title = "Verify safety number",
                            detail = "Compare codes to confirm nobody is in the middle",
                            icon = Icons.Filled.Shield,
                            tint = TileBlue,
                            onClick = it,
                        )
                    }
                    if (onVerify != null && onToggleBlock != null) RowDivider()
                    onToggleBlock?.let {
                        ActionRow(
                            title = if (isBlocked) "Unblock" else "Block",
                            detail = if (isBlocked) {
                                "Messages from this account are dropped"
                            } else {
                                "Stop receiving messages from this account"
                            },
                            icon = Icons.Filled.Block,
                            tint = TileRed,
                            onClick = it,
                        )
                    }
                }
            }

            Spacer(Modifier.height(32.dp))
        }
    }
}
