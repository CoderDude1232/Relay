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
import androidx.core.content.ContextCompat
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.relaymsg.ui.theme.RelayTheme

/**
 * The screen a call's full-screen intent raises.
 *
 * It shows over the lock screen and turns the display on, which is the closest
 * Android gets to CallKit's incoming-call UI. It is deliberately dumb: the call
 * itself lives in [IncomingCallService], and both buttons just send it an
 * intent, so answering from the lock screen and answering from the heads-up
 * notification take exactly the same path.
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
        // asked. Requested here rather than failing the call in the transport.
        val microphone = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            dispatch(
                if (granted) IncomingCallService.ACTION_ACCEPT else IncomingCallService.ACTION_DECLINE,
                wake,
            )
        }

        setContent {
            RelayTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    IncomingCall(
                        wake = wake,
                        onAccept = {
                            if (hasMicrophone()) {
                                dispatch(IncomingCallService.ACTION_ACCEPT, wake)
                            } else {
                                microphone.launch(Manifest.permission.RECORD_AUDIO)
                            }
                        },
                        onDecline = { dispatch(IncomingCallService.ACTION_DECLINE, wake) },
                    )
                }
            }
        }
    }

    /** A second call wake replaces the one on screen rather than stacking. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    private fun dispatch(action: String, wake: CallWake) {
        startService(
            wake.putInto(Intent(this, IncomingCallService::class.java)).setAction(action),
        )
        finish()
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
}

@Composable
private fun IncomingCall(wake: CallWake, onAccept: () -> Unit, onDecline: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.SpaceBetween,
    ) {
        Column(
            modifier = Modifier.padding(top = 72.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = wake.displayName,
                style = MaterialTheme.typography.headlineMedium,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.size(8.dp))
            Text(
                text = if (wake.isVideo) "Incoming Relay video call" else "Incoming Relay call",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 48.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
        ) {
            Button(
                onClick = onDecline,
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.error,
                    contentColor = Color.White,
                ),
            ) {
                Text("Decline")
            }
            Button(onClick = onAccept) {
                Text("Accept")
            }
        }
    }
}
