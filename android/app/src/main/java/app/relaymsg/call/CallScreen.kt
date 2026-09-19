package app.relaymsg.call

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
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
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.ScreenShare
import androidx.compose.material.icons.filled.StopScreenShare
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.FlipCameraAndroid
import androidx.compose.material.icons.filled.Headset
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material.icons.filled.PhoneInTalk
import androidx.compose.material.icons.filled.VolumeDown
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.relaymsg.ui.Avatar
import androidx.compose.ui.viewinterop.AndroidView
import app.relaymsg.core.ActiveCall
import app.relaymsg.core.AudioRoute
import app.relaymsg.core.AudioRouteKind
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
    /** The peer's profile photo, if they have published one. */
    peerAvatar: ByteArray? = null,
    remoteVideo: VideoTrack?,
    localVideo: VideoTrack?,
    /** Mirrored only while the front camera is selected. */
    localMirror: Boolean = true,
    onAccept: () -> Unit,
    onHangUp: () -> Unit,
    onToggleMute: () -> Unit,
    onToggleSpeaker: () -> Unit,
    onSwitchCamera: () -> Unit = {},
    onToggleCamera: () -> Unit = {},
    onToggleScreenShare: () -> Unit = {},
    /** Queried when the user opens the picker: headsets come and go mid-call. */
    audioRoutes: () -> List<AudioRoute> = ::emptyList,
    onSelectRoute: (AudioRoute) -> Unit = {},
    /** Null when there is nowhere to minimise to, which hides the chevron. */
    onMinimise: (() -> Unit)? = null,
) {
    val hasVideo = call.isVideo && remoteVideo != null

    Surface(modifier = Modifier.fillMaxSize(), color = Color.Black) {
        Box(Modifier.fillMaxSize()) {
            // A voice call is tinted by whoever is on it; video fills the frame
            // itself and needs nothing behind it.
            if (!hasVideo) CallBackdrop(peerName, peerAvatar)
            if (hasVideo) {
                VideoSurface(
                    track = remoteVideo,
                    mirror = false,
                    modifier = Modifier.fillMaxSize(),
                )
                localVideo?.takeIf { call.isCameraOn }?.let { local ->
                    VideoSurface(
                        track = local,
                        // The front camera is mirrored, because a self-view that
                        // is not mirrored reads as somebody else's camera. The
                        // back camera is not: that one is showing the world.
                        mirror = localMirror,
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .padding(16.dp)
                            .width(108.dp)
                            .aspectRatio(3f / 4f)
                            .clip(RoundedCornerShape(12.dp)),
                    )
                }
            }

            onMinimise?.let { minimise ->
                IconButton(
                    onClick = minimise,
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .padding(start = 12.dp, top = 44.dp)
                        .size(44.dp),
                ) {
                    Icon(
                        Icons.Filled.KeyboardArrowDown,
                        contentDescription = "Minimise call",
                        tint = Color.White,
                        modifier = Modifier.size(30.dp),
                    )
                }
            }

            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.SpaceBetween,
            ) {
                if (hasVideo) {
                    Header(call, peerName, onBlack = true)
                } else {
                    Identity(call, peerName, peerAvatar)
                }
                Controls(
                    call = call,
                    onAccept = onAccept,
                    onHangUp = onHangUp,
                    onToggleMute = onToggleMute,
                    onToggleSpeaker = onToggleSpeaker,
                    onSwitchCamera = onSwitchCamera,
                    onToggleCamera = onToggleCamera,
                    onToggleScreenShare = onToggleScreenShare,
                    audioRoutes = audioRoutes,
                    onSelectRoute = onSelectRoute,
                )
            }
        }
    }
}

/**
 * Who you are talking to, on a voice call.
 *
 * Sized from iOS: a 160dp circle, a 30sp name, and the status underneath with a
 * handset glyph. It sits in the upper half rather than centred, because the
 * lower half belongs to the controls.
 */
@Composable
private fun ColumnScope.Identity(call: ActiveCall, peerName: String, peerAvatar: ByteArray?) {
    Column(
        modifier = Modifier.weight(1f),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Avatar(id = peerName, name = peerName, size = 160.dp, imageData = peerAvatar)
        Spacer(Modifier.size(20.dp))
        Text(
            text = peerName,
            fontSize = 30.sp,
            fontWeight = FontWeight.Bold,
            color = Color.White,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.size(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Filled.Call,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.60f),
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.size(6.dp))
            Text(
                text = statusLine(call),
                style = MaterialTheme.typography.bodyMedium,
                color = Color.White.copy(alpha = 0.65f),
            )
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
    onSwitchCamera: () -> Unit,
    onToggleCamera: () -> Unit,
    onToggleScreenShare: () -> Unit,
    audioRoutes: () -> List<AudioRoute>,
    onSelectRoute: (AudioRoute) -> Unit,
) {
    if (call.state == CallState.INCOMING_RINGING) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(bottom = 40.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Decline is the same action as hanging up; only the label differs.
            CallButton(Icons.Filled.CallEnd, "Decline", EndRed, Color.White, onHangUp)
            CallButton(Icons.Filled.Call, "Accept", AnswerGreen, Color.White, onAccept)
        }
        return
    }

    var routePicker by remember { mutableStateOf<List<AudioRoute>?>(null) }

    Column(
        modifier = Modifier.fillMaxWidth().padding(bottom = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // A video call needs its extra controls somewhere, and they do not fit
        // on the row below without shrinking everything; they get their own.
        if (call.isVideo) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically,
            ) {
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
                CallButton(
                    icon = if (call.isScreenSharing) {
                        Icons.Filled.StopScreenShare
                    } else {
                        Icons.Filled.ScreenShare
                    },
                    label = if (call.isScreenSharing) "Stop" else "Share",
                    background = if (call.isScreenSharing) GlassOn else Glass,
                    contentColor = Color.White,
                    onClick = onToggleScreenShare,
                )
            }
            Spacer(Modifier.size(20.dp))
        }

        // iOS's three: Speaker, Mute, End. Mute inverts to a solid white circle
        // when it is off rather than lighting up when it is on — the state worth
        // shouting about is "they cannot hear you".
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CallButton(
                // Not the route's own icon: that draws the earpiece as a
                // crossed-out speaker, which on a call screen reads as "your
                // audio is off" rather than "the speaker is not on". iOS shows
                // a quieter speaker against a louder one, so this does too.
                icon = if (call.audioRoute == AudioRouteKind.SPEAKER) {
                    Icons.Filled.VolumeUp
                } else {
                    Icons.Filled.VolumeDown
                },
                label = "Speaker",
                background = if (call.audioRoute == AudioRouteKind.SPEAKER) GlassOn else Glass,
                contentColor = Color.White,
                // With only the phone and the speaker to choose from, a picker
                // would be two taps to do what one should. A headset makes it a
                // real choice, so then it becomes one — which is how every phone
                // app behaves.
                onClick = {
                    val routes = audioRoutes()
                    if (routes.size > 2) routePicker = routes else onToggleSpeaker()
                },
            )
            CallButton(
                icon = if (call.isMuted) Icons.Filled.MicOff else Icons.Filled.Mic,
                label = if (call.isMuted) "Unmute" else "Mute",
                background = if (call.isMuted) Glass else Color.White,
                contentColor = if (call.isMuted) Color.White else Color.Black,
                onClick = onToggleMute,
            )
            CallButton(
                icon = Icons.Filled.CallEnd,
                label = "End",
                background = EndRed,
                contentColor = Color.White,
                onClick = onHangUp,
            )
        }
    }

    routePicker?.let { routes ->
        AlertDialog(
            onDismissRequest = { routePicker = null },
            title = { Text("Audio output") },
            text = {
                Column {
                    routes.forEach { route ->
                        TextButton(
                            onClick = { onSelectRoute(route); routePicker = null },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(
                                Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(route.kind.icon(), contentDescription = null)
                                Spacer(Modifier.size(12.dp))
                                Text(
                                    route.name,
                                    fontWeight = if (route.kind == call.audioRoute) {
                                        FontWeight.Bold
                                    } else {
                                        FontWeight.Normal
                                    },
                                )
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { routePicker = null }) { Text("Cancel") }
            },
        )
    }
}

internal fun AudioRouteKind.icon() = when (this) {
    AudioRouteKind.SPEAKER -> Icons.Filled.VolumeUp
    AudioRouteKind.BLUETOOTH -> Icons.Filled.Bluetooth
    AudioRouteKind.WIRED -> Icons.Filled.Headset
    // The handset, not a muted speaker: this names where the audio is going.
    AudioRouteKind.EARPIECE -> Icons.Filled.PhoneInTalk
}

/**
 * A call control: a 72dp circle with its label underneath, as iOS draws them.
 *
 * The label is text rather than only a content description — on a call screen
 * with no other furniture, an unlabelled circle is a guess.
 */
@Composable
internal fun CallButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    background: Color,
    contentColor: Color,
    onClick: () -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.width(88.dp),
    ) {
        androidx.compose.material3.IconButton(
            onClick = onClick,
            modifier = Modifier
                .size(72.dp)
                .clip(CircleShape)
                .background(background),
        ) {
            Icon(
                icon,
                contentDescription = label,
                tint = contentColor,
                modifier = Modifier.size(30.dp),
            )
        }
        Spacer(Modifier.size(10.dp))
        Text(
            text = label,
            style = MaterialTheme.typography.bodySmall,
            color = Color.White.copy(alpha = 0.82f),
            maxLines = 1,
            textAlign = TextAlign.Center,
        )
    }
}

/** The translucent white iOS uses for a control that is not lit. */
internal val Glass = Color.White.copy(alpha = 0.18f)

/** The same, lit. */
internal val GlassOn = Color.White.copy(alpha = 0.35f)

/** iOS's hang-up red, which is warmer than Material's error colour. */
internal val EndRed = Color(0xFFEE4733)

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
internal fun VideoSurface(track: VideoTrack, mirror: Boolean, modifier: Modifier) {
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
internal val AnswerGreen = Color(0xFF2E7D32)
