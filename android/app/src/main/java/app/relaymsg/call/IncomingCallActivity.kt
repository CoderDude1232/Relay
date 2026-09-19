package app.relaymsg.call

import android.Manifest
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import app.relaymsg.core.ActiveCall
import app.relaymsg.core.AudioRouteKind
import app.relaymsg.core.CallState
import app.relaymsg.core.RelayService
import app.relaymsg.push.RelayRuntime
import app.relaymsg.ui.theme.RelayTheme

/**
 * The screen a call's full-screen intent raises.
 *
 * It shows over the lock screen and turns the display on, which is the closest
 * Android gets to CallKit's incoming-call UI, and then hosts the call for its
 * whole life — the same [CallScreen] the app shows in-place, so the two paths
 * cannot drift.
 *
 * It opens before the OFFER has been fetched, so it starts from the push
 * metadata alone and swaps to the real call state the moment [CallService]
 * drains it out of the queue.
 */
class IncomingCallActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverLockScreen()

        val wake = CallWake.fromIntent(intent)
        if (wake == null) {
            finish()
            return
        }

        // Answering is the first moment the microphone is actually needed, and a
        // call woken from the lock screen may be the first time the app has ever
        // asked for it. Requested here rather than failing inside the transport.
        val microphone = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            dispatch(
                if (granted) CallService.ACTION_ACCEPT else CallService.ACTION_DECLINE,
                wake,
            )
        }

        setContent {
            RelayTheme {
                val relay by produceState<RelayService?>(null) {
                    value = RelayRuntime.require(this@IncomingCallActivity)
                }
                val call by produceState<ActiveCall?>(null, relay) {
                    relay?.calls?.call?.collect { value = it }
                }
                val remoteVideo by CallMedia.remoteVideo.collectAsState()
                val localVideo by CallMedia.localVideo.collectAsState()
                val localMirror by CallMedia.localMirror.collectAsState()

                // Before the OFFER lands there is no call object, only what the
                // push said. Showing a placeholder keeps the screen from
                // flickering empty while the queue drain finishes.
                val shown = call ?: placeholder(wake)

                CallScreen(
                    call = shown,
                    peerName = wake.displayName,
                    // The same tint the in-app screen uses, so a call answered
                    // from the lock screen does not change colour when the app
                    // comes forward behind it.
                    peerAvatar = remember(shown.peerAccount, relay) {
                        relay?.peerAvatar(shown.peerAccount)
                    },
                    remoteVideo = remoteVideo,
                    localVideo = localVideo,
                    localMirror = localMirror,
                    onAccept = {
                        if (hasMicrophone()) {
                            dispatch(CallService.ACTION_ACCEPT, wake)
                        } else {
                            microphone.launch(Manifest.permission.RECORD_AUDIO)
                        }
                    },
                    onHangUp = { dispatch(CallService.ACTION_DECLINE, wake) },
                    onToggleMute = { relay?.calls?.setMuted(!shown.isMuted) },
                    onToggleSpeaker = {
                        relay?.calls?.setSpeakerOn(shown.audioRoute != AudioRouteKind.SPEAKER)
                    },
                    onSwitchCamera = { relay?.calls?.switchCamera() },
                    onToggleCamera = { relay?.calls?.setCameraEnabled(!shown.isCameraOn) },
                    audioRoutes = { relay?.calls?.audioRoutes().orEmpty() },
                    onSelectRoute = { route -> relay?.calls?.selectAudioRoute(route) },
                )

                // The call existing and then not existing is the only reliable
                // "it's over" signal — it covers hangup, decline, BUSY and a
                // failure to connect without enumerating them.
                FinishWhenCallEnds(call, onFinish = ::finish)
            }
        }
    }

    /** A second call wake replaces the one on screen rather than stacking. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun onStart() {
        super.onStart()
        CallMedia.setFullScreen(true)
    }

    override fun onStop() {
        CallMedia.setFullScreen(false)
        super.onStop()
    }

    private fun dispatch(action: String, wake: CallWake) {
        startService(
            wake.putInto(Intent(this, CallService::class.java)).setAction(action),
        )
    }

    private fun hasMicrophone(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun showOverLockScreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            // Asks the system to dismiss a *non-secure* keyguard. A PIN or
            // biometric lock stays up, and the call rings on top of it — the same
            // as the phone app.
            (getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager)
                .requestDismissKeyguard(this, null)
        }
    }

    /** What to show between the push arriving and the OFFER being decrypted. */
    private fun placeholder(wake: CallWake) = ActiveCall(
        callId = wake.callId,
        peerAccount = wake.callerAccount,
        isOutgoing = false,
        isVideo = wake.isVideo,
        state = CallState.INCOMING_RINGING,
        startedAt = System.currentTimeMillis(),
    )
}

@Composable
private fun FinishWhenCallEnds(call: ActiveCall?, onFinish: () -> Unit) {
    // Only after a real call has existed: null also means "the OFFER has not
    // arrived yet", and finishing then would close the screen mid-ring.
    var seen by remember { mutableStateOf(false) }
    LaunchedEffect(call) {
        if (call != null) seen = true else if (seen) onFinish()
    }
}
