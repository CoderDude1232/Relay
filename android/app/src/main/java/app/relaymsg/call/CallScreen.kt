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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalInspectionMode
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import app.relaymsg.core.ActiveCall
import app.relaymsg.core.CallState
import kotlinx.coroutines.delay
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack

/**
 * The one screen a call is shown on, wherever it started.
 *
 * `MainActivity` hosts it as an overlay for calls placed or received while the
 * app is open; [IncomingCallActivity] hosts the same composable over the lock
 * screen for a call that arrived as a push wake. Sharing it is what keeps the
 * two paths from drifting.
 */
@Composable
fun CallScreen(
    call: ActiveCall,
    peerName: String,
    remoteVideo: VideoTrack?,
    localVideo: VideoTrack?,
    onAccept: () -> Unit,
    onHangUp: () -> Unit,
    onToggleMute: () -> Unit,
    onToggleSpeaker: () -> Unit,
) {
    val hasVideo = call.isVideo && remoteVideo != null

    Surface(
        modifier = Modifier.fillMaxSize(),
        // Video reads better against black; an audio call keeps the app's own
        // surface so it does not look like a different application.
        color = if (hasVideo) Color.Black else MaterialTheme.colorScheme.surface,
    ) {
        Box(Modifier.fillMaxSize()) {
            if (hasVideo) {
                VideoSurface(
                    track = remoteVideo,
                    mirror = false,
                    modifier = Modifier.fillMaxSize(),
                )
                localVideo?.let { local ->
                    VideoSurface(
                        track = local,
                        // Mirrored, because a self-view that is not mirrored
                        // reads as somebody else's camera.
                        mirror = true,
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .padding(16.dp)
                            .width(108.dp)
                            .aspectRatio(3f / 4f)
                            .clip(RoundedCornerShape(12.dp)),
                    )
                }
            }

            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.SpaceBetween,
            ) {
                Header(call, peerName, onBlack = hasVideo)
                Controls(call, onAccept, onHangUp, onToggleMute, onToggleSpeaker)
            }
        }
    }
}

@Composable
private fun Header(call: ActiveCall, peerName: String, onBlack: Boolean) {
    val tint = if (onBlack) Color.White else MaterialTheme.colorScheme.onSurface
    Column(
        modifier = Modifier.padding(top = 56.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = peerName,
            style = MaterialTheme.typography.headlineMedium,
            color = tint,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.size(8.dp))
        Text(
            text = statusLine(call),
            style = MaterialTheme.typography.bodyLarge,
            color = tint.copy(alpha = 0.7f),
        )
    }
}

@Composable
private fun Controls(
    call: ActiveCall,
    onAccept: () -> Unit,
    onHangUp: () -> Unit,
    onToggleMute: () -> Unit,
    onToggleSpeaker: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 40.dp),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (call.state == CallState.INCOMING_RINGING) {
            // Decline is the same action as hanging up; only the label differs.
            CircleButton(Icons.Filled.CallEnd, "Decline", MaterialTheme.colorScheme.error, onHangUp)
            CircleButton(Icons.Filled.Call, "Accept", AnswerGreen, onAccept)
        } else {
            CircleButton(
                icon = if (call.isMuted) Icons.Filled.MicOff else Icons.Filled.Mic,
                label = if (call.isMuted) "Unmute" else "Mute",
                background = MaterialTheme.colorScheme.surfaceVariant,
                onClick = onToggleMute,
                contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            CircleButton(Icons.Filled.CallEnd, "Hang up", MaterialTheme.colorScheme.error, onHangUp)
            CircleButton(
                icon = if (call.isSpeakerOn) Icons.Filled.VolumeUp else Icons.Filled.VolumeOff,
                label = if (call.isSpeakerOn) "Speaker on" else "Speaker off",
                background = MaterialTheme.colorScheme.surfaceVariant,
                onClick = onToggleSpeaker,
                contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun CircleButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    background: Color,
    onClick: () -> Unit,
    contentColor: Color = Color.White,
) {
    androidx.compose.material3.IconButton(
        onClick = onClick,
        modifier = Modifier
            .size(64.dp)
            .clip(CircleShape)
            .background(background),
    ) {
        Icon(icon, contentDescription = label, tint = contentColor, modifier = Modifier.size(28.dp))
    }
}

/**
 * What the call is doing, in words.
 *
 * Once connected this becomes the running duration, which is also the only
 * honest "is this actually working" signal the user has.
 */
@Composable
private fun statusLine(call: ActiveCall): String = when (call.state) {
    CallState.OUTGOING_RINGING -> "Ringing…"
    CallState.INCOMING_RINGING ->
        if (call.isVideo) "Incoming video call" else "Incoming call"
    CallState.CONNECTING -> "Connecting…"
    CallState.ACTIVE -> elapsed(call.connectedAt)
    CallState.ENDED, CallState.IDLE -> "Call ended"
}

/** A ticking mm:ss since [since]. */
@Composable
private fun elapsed(since: Long?): String {
    if (since == null) return "Connected"
    var now by remember(since) { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(since) {
        while (true) {
            delay(1_000)
            now = System.currentTimeMillis()
        }
    }
    val seconds = ((now - since).coerceAtLeast(0L)) / 1000
    return "%d:%02d".format(seconds / 60, seconds % 60)
}

/**
 * A WebRTC video track, rendered.
 *
 * The sink is attached and detached by a [DisposableEffect] keyed on both the
 * track and the view: a renderer left attached to a disposed track, or a track
 * rendered into a released surface, crashes in native code where there is
 * nothing useful to read in the stack trace.
 */
@Composable
private fun VideoSurface(track: VideoTrack, mirror: Boolean, modifier: Modifier) {
    // Previews and screenshot tests have no EGL context and no native library.
    if (LocalInspectionMode.current) {
        Box(modifier.background(Color.DarkGray))
        return
    }

    var renderer by remember { mutableStateOf<SurfaceViewRenderer?>(null) }

    AndroidView(
        modifier = modifier,
        factory = { context ->
            SurfaceViewRenderer(context).apply {
                init(WebRtc.eglContext(), null)
                setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FILL)
                setMirror(mirror)
                setEnableHardwareScaler(true)
                renderer = this
            }
        },
        onRelease = { view ->
            renderer = null
            view.release()
        },
    )

    val view = renderer
    DisposableEffect(view, track) {
        if (view != null) track.addSink(view)
        onDispose { if (view != null) runCatching { track.removeSink(view) } }
    }
}

/** Not in the Material palette: "answer" is green everywhere, so it is green here. */
private val AnswerGreen = Color(0xFF2E7D32)
