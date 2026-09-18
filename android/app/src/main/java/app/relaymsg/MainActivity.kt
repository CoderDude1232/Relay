package app.relaymsg

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import app.relaymsg.call.CallMedia
import app.relaymsg.call.CallScreen
import app.relaymsg.call.GroupCallScreen
import app.relaymsg.ui.CallLogScreen
import app.relaymsg.ui.AuthScreen
import app.relaymsg.ui.ChatScreen
import app.relaymsg.ui.ConversationListScreen
import app.relaymsg.ui.LinkDeviceScreen
import app.relaymsg.ui.ScanLinkScreen
import app.relaymsg.ui.theme.RelayTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            RelayTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    RelayApp()
                }
            }
        }
    }
}

@Composable
private fun RelayApp(viewModel: RelayViewModel = viewModel()) {
    val phase by viewModel.phase.collectAsState()
    val busy by viewModel.busy.collectAsState()

    when (val current = phase) {
        is AppPhase.Loading -> Centered { CircularProgressIndicator() }

        is AppPhase.SignedOut -> {
            val step by viewModel.authStep.collectAsState()
            val authError by viewModel.authError.collectAsState()
            AuthScreen(
                step = step,
                busy = busy,
                error = authError,
                onSignUp = viewModel::signUpWithEmail,
                onSignIn = viewModel::signInWithEmail,
                onSubmitUsername = viewModel::submitUsername,
                onShowSignUp = viewModel::showSignUp,
                onShowSignIn = viewModel::showSignIn,
                onLinkDevice = viewModel::startLinking,
                onBack = viewModel::authBack,
            )
        }

        is AppPhase.Linking -> LinkDeviceScreen(
            qr = current.qr,
            error = current.error,
            onCancel = viewModel::cancelLinking,
            onRetry = viewModel::startLinking,
        )

        is AppPhase.Failed -> Centered {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(current.message, style = MaterialTheme.typography.bodyLarge)
                Button(onClick = viewModel::retry, modifier = Modifier.padding(top = 12.dp)) {
                    Text("Try again")
                }
            }
        }

        is AppPhase.Ready -> SignedIn(viewModel, current)
    }
}

@Composable
private fun SignedIn(viewModel: RelayViewModel, phase: AppPhase.Ready) {
    // Asked once on first reach of the signed-in UI.
    //  - Notifications (API 33+): declining costs only the banner, not delivery.
    //  - Microphone: asked up front rather than mid-call, because the first time
    //    it is needed may well be a call answered from the lock screen.
    val permissionLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions(),
    ) { }
    androidx.compose.runtime.LaunchedEffect(Unit) {
        val wanted = buildList {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                add(android.Manifest.permission.POST_NOTIFICATIONS)
            }
            add(android.Manifest.permission.RECORD_AUDIO)
        }
        permissionLauncher.launch(wanted.toTypedArray())
    }

    val conversations by viewModel.conversations.collectAsState()
    val messages by viewModel.activeMessages.collectAsState()
    val connection by viewModel.connection.collectAsState()
    val busy by viewModel.busy.collectAsState()

    var openConversationId by remember { mutableStateOf<String?>(null) }
    var showCalls by remember { mutableStateOf(false) }
    var showScanner by remember { mutableStateOf(false) }

    Box(Modifier.fillMaxSize()) {
        val open = openConversationId
        if (showScanner) {
            val scanStatus by viewModel.scanStatus.collectAsState()
            val scanError by viewModel.scanError.collectAsState()
            ScanLinkScreen(
                status = scanStatus,
                error = scanError,
                onScanned = viewModel::provisionScanned,
                onBack = { viewModel.resetScan(); showScanner = false },
            )
        } else if (showCalls) {
            val calls by viewModel.callLog.collectAsState()
            CallLogScreen(
                calls = calls,
                onBack = { showCalls = false },
                onClear = viewModel::clearCallLog,
                onCall = { peer, video -> showCalls = false; viewModel.placeCall(peer, video) },
            )
        } else if (open == null) {
            ConversationListScreen(
                username = phase.service.username,
                connection = connection,
                conversations = conversations,
                titleFor = viewModel::titleFor,
                busy = busy,
                onOpen = { id -> viewModel.openConversation(id); openConversationId = id },
                onStartConversation = viewModel::startConversation,
                onShowCalls = { showCalls = true },
                onLinkDevice = { viewModel.resetScan(); showScanner = true },
            )
        } else {
            val conversation = conversations.firstOrNull { it.id == open }
            ChatScreen(
                title = conversation?.let(viewModel::titleFor) ?: "Conversation",
                messages = messages,
                onSend = { body -> viewModel.send(open, body) },
                onSendImage = { uri -> viewModel.sendImage(open, uri) },
                loadAttachment = { viewModel.attachmentBytes(it) },
                onBack = { viewModel.closeConversation(); openConversationId = null },
                // A group conversation's "peer" is its group id, which rings
                // everyone rather than one account.
                onCall = conversation?.let { target ->
                    { video ->
                        val group = target.groupId
                        if (group != null) {
                            viewModel.startGroupCall(group, video)
                        } else {
                            viewModel.placeCall(target.peerAccount, video)
                        }
                    }
                },
            )
        }

        InCallOverlay(viewModel)
    }
}

/**
 * The call UI, on top of whatever the app was showing.
 *
 * Covers calls placed from here and calls that arrived over the socket while the
 * app was open — the ones no push wake ever fires for. A call that came in as a
 * wake is already on screen in [app.relaymsg.call.IncomingCallActivity], which is
 * what `CallMedia.fullScreen` reports, and rendering both would attach two
 * renderers to one video track.
 */
@Composable
private fun InCallOverlay(viewModel: RelayViewModel) {
    val call by viewModel.call.collectAsState()
    val fullScreenElsewhere by CallMedia.fullScreen.collectAsState()
    val remoteVideo by CallMedia.remoteVideo.collectAsState()
    val localVideo by CallMedia.localVideo.collectAsState()
    val localMirror by CallMedia.localMirror.collectAsState()

    val groupCall by viewModel.groupCall.collectAsState()
    val groupVideo by CallMedia.groupVideo.collectAsState()

    groupCall?.let { group ->
        GroupCallScreen(
            call = group,
            remoteVideo = groupVideo,
            localVideo = localVideo,
            localMirror = localMirror,
            onJoin = viewModel::joinGroupCall,
            onLeave = viewModel::leaveGroupCall,
            onToggleMute = viewModel::toggleGroupMute,
            onToggleCamera = viewModel::toggleGroupCamera,
            onSwitchCamera = viewModel::switchGroupCamera,
        )
        return
    }

    val active = call ?: return
    if (fullScreenElsewhere) return

    CallScreen(
        call = active,
        peerName = viewModel.callerName(active),
        remoteVideo = remoteVideo,
        localVideo = localVideo,
        localMirror = localMirror,
        onAccept = viewModel::acceptCall,
        onHangUp = viewModel::hangUp,
        onToggleMute = viewModel::toggleMute,
        onToggleSpeaker = viewModel::toggleSpeaker,
        onSwitchCamera = viewModel::switchCamera,
        onToggleCamera = viewModel::toggleCamera,
        audioRoutes = viewModel::audioRoutes,
        onSelectRoute = viewModel::selectAudioRoute,
    )
}

@Composable
private fun Centered(content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { content() }
}
