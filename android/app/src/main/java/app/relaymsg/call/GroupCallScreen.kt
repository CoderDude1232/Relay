package app.relaymsg.call

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.FlipCameraAndroid
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.relaymsg.core.ActiveGroupCall
import app.relaymsg.core.GroupCallPeer
import app.relaymsg.core.MediaConnectionState
import org.webrtc.VideoTrack

/**
 * A group call: a tile per member, plus this device's own preview.
 *
 * Members appear as they connect rather than as they were invited — the mesh
 * builds itself one leg at a time, and a tile for someone who never picked up
 * would be a lie about who is in the room.
 */
@Composable
fun GroupCallScreen(
    call: ActiveGroupCall,
    remoteVideo: Map<String, VideoTrack>,
    localVideo: VideoTrack?,
    localMirror: Boolean,
    onJoin: () -> Unit,
    onLeave: () -> Unit,
    onToggleMute: () -> Unit,
    onToggleCamera: () -> Unit,
    onSwitchCamera: () -> Unit,
) {
    Surface(
        modifier = Modifier.fillMaxSize(),
        color = if (call.isVideo) Color.Black else MaterialTheme.colorScheme.surface,
    ) {
        Column(
            Modifier.fillMaxSize().padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Header(call)

            Box(Modifier.weight(1f).fillMaxWidth()) {
                if (call.isRinging) {
                    Text(
                        text = "${call.participants.size + 1} people invited",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.align(Alignment.Center),
                    )
                } else {
                    PeerGrid(call, remoteVideo, onBlack = call.isVideo)
                }

                localVideo?.takeIf { call.isCameraOn && !call.isRinging }?.let { local ->
                    VideoSurface(
                        track = local,
                        mirror = localMirror,
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .padding(8.dp)
                            .width(96.dp)
                            .aspectRatio(3f / 4f)
                            .clip(RoundedCornerShape(12.dp)),
                    )
                }
            }

            Controls(call, onJoin, onLeave, onToggleMute, onToggleCamera, onSwitchCamera)
        }
    }
}

@Composable
private fun Header(call: ActiveGroupCall) {
    val tint = if (call.isVideo) Color.White else MaterialTheme.colorScheme.onSurface
    Column(
        Modifier.padding(top = 40.dp, bottom = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = call.groupName,
            style = MaterialTheme.typography.headlineSmall,
            color = tint,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.size(4.dp))
        Text(
            text = when {
                call.isRinging -> "Incoming group call"
                call.peers.isEmpty() -> "Waiting for others…"
                else -> "${call.peers.size + 1} in the call"
            },
            style = MaterialTheme.typography.bodyMedium,
            color = tint.copy(alpha = 0.7f),
        )
    }
}

@Composable
private fun PeerGrid(
    call: ActiveGroupCall,
    remoteVideo: Map<String, VideoTrack>,
    onBlack: Boolean,
) {
    if (call.peers.isEmpty()) return
    LazyVerticalGrid(
        // Two columns up to four people, three beyond that: past that point a
        // bigger tile is worth less than seeing everyone at once.
        columns = GridCells.Fixed(if (call.peers.size > 4) 3 else 2),
        modifier = Modifier.fillMaxSize(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(call.peers, key = { it.account }) { peer ->
            PeerTile(peer, remoteVideo[peer.account], onBlack)
        }
    }
}

@Composable
private fun PeerTile(peer: GroupCallPeer, video: VideoTrack?, onBlack: Boolean) {
    Box(
        Modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(12.dp))
            .background(
                if (onBlack) Color(0xFF1C1C1C) else MaterialTheme.colorScheme.surfaceVariant,
            ),
    ) {
        if (video != null) {
            VideoSurface(video, mirror = false, modifier = Modifier.fillMaxSize())
        }
        Column(
            Modifier.align(Alignment.BottomStart).padding(8.dp),
        ) {
            Text(
                text = peer.name,
                style = MaterialTheme.typography.labelLarge,
                color = if (onBlack || video != null) Color.White else Color.Unspecified,
            )
            // Only while it is still trying: labelling a working connection
            // "connected" is noise, but silence with no explanation is worse.
            if (peer.media != MediaConnectionState.CONNECTED) {
                Text(
                    text = "Connecting…",
                    style = MaterialTheme.typography.labelSmall,
                    color = if (onBlack || video != null) {
                        Color.White.copy(alpha = 0.7f)
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
            }
        }
    }
}

@Composable
private fun Controls(
    call: ActiveGroupCall,
    onJoin: () -> Unit,
    onLeave: () -> Unit,
    onToggleMute: () -> Unit,
    onToggleCamera: () -> Unit,
    onSwitchCamera: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 24.dp),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (call.isRinging) {
            CallButton(Icons.Filled.CallEnd, "Decline", EndRed, Color.White, onLeave)
            CallButton(Icons.Filled.Call, "Join", AnswerGreen, Color.White, onJoin)
            return@Row
        }

        CallButton(
            icon = if (call.isMuted) Icons.Filled.MicOff else Icons.Filled.Mic,
            label = if (call.isMuted) "Unmute" else "Mute",
            background = if (call.isMuted) Glass else Color.White,
            contentColor = if (call.isMuted) Color.White else Color.Black,
            onClick = onToggleMute,
        )
        if (call.isVideo) {
            CallButton(
                icon = if (call.isCameraOn) Icons.Filled.Videocam else Icons.Filled.VideocamOff,
                label = if (call.isCameraOn) "Camera" else "Camera off",
                background = if (call.isCameraOn) GlassOn else Glass,
                contentColor = Color.White,
                onClick = onToggleCamera,
            )
            CallButton(
                icon = Icons.Filled.FlipCameraAndroid,
                label = "Flip",
                background = Glass,
                contentColor = Color.White,
                onClick = onSwitchCamera,
            )
        }
        CallButton(Icons.Filled.CallEnd, "Leave", EndRed, Color.White, onLeave)
    }
}
