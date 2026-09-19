package app.relaymsg

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
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
import app.relaymsg.call.CallMedia
import app.relaymsg.call.CallScreen
import app.relaymsg.call.CallService
import app.relaymsg.call.GroupCallScreen
import app.relaymsg.ui.BlockedContactsScreen
import app.relaymsg.ui.CallLogScreen
import app.relaymsg.ui.AuthScreen
import app.relaymsg.ui.ChatScreen
import app.relaymsg.ui.ConversationListScreen
import app.relaymsg.ui.LinkDeviceScreen
import app.relaymsg.ui.ProfileScreen
import app.relaymsg.ui.ScanLinkScreen
import app.relaymsg.ui.VerificationScreen
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import app.relaymsg.ui.SettingsScreen
import app.relaymsg.ui.theme.RelayTheme

class MainActivity : ComponentActivity() {

    private val viewModel: RelayViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // A cold start through the OAuth link: the browser tab handed back
        // before this activity existed.
        intent?.data?.let(viewModel::onOAuthRedirect)
        setContent {
            RelayTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    RelayApp(viewModel)
                }
            }
        }
    }

    /** The usual path: the app was already running behind the browser tab. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.data?.let(viewModel::onOAuthRedirect)
    }
}

@Composable
private fun RelayApp(viewModel: RelayViewModel) {
    val phase by viewModel.phase.collectAsState()
    val busy by viewModel.busy.collectAsState()

    when (val current = phase) {
        is AppPhase.Loading -> Centered { CircularProgressIndicator() }

        is AppPhase.SignedOut -> {
            val step by viewModel.authStep.collectAsState()
            val authError by viewModel.authError.collectAsState()
            OpenOAuthTab(viewModel)
            AuthScreen(
                step = step,
                busy = busy,
                error = authError,
                onSignUp = viewModel::signUpWithEmail,
                onSignIn = viewModel::signInWithEmail,
                onSubmitUsername = viewModel::submitUsername,
                onShowSignUp = viewModel::showSignUp,
                onShowSignIn = viewModel::showSignIn,
                onGoogleSignIn = viewModel::startGoogleSignIn,
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

/**
 * Hands a pending OAuth URL to a Custom Tab.
 *
 * A Custom Tab rather than a WebView on purpose: it shares the browser's own
 * cookies (so an already-signed-in Google account is one tap), the address bar
 * is visible and verifiable, and the app never gets to see the page — which is
 * why providers reject in-app WebViews for sign-in.
 */
@Composable
private fun OpenOAuthTab(viewModel: RelayViewModel) {
    val url by viewModel.pendingAuthUrl.collectAsState()
    val context = androidx.compose.ui.platform.LocalContext.current
    androidx.compose.runtime.LaunchedEffect(url) {
        val target = url ?: return@LaunchedEffect
        runCatching {
            androidx.browser.customtabs.CustomTabsIntent.Builder()
                .setShowTitle(true)
                .build()
                .launchUrl(context, android.net.Uri.parse(target))
        }
        viewModel.authUrlOpened()
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
    var showScanner by remember { mutableStateOf(false) }
    var showBlocked by remember { mutableStateOf(false) }
    var showProfile by remember { mutableStateOf(false) }
    var verifyPeer by remember { mutableStateOf<String?>(null) }
    val blockedAccounts by viewModel.blockedAccounts.collectAsState()
    var tab by rememberSaveable { mutableStateOf(Tab.CHATS) }

    Box(Modifier.fillMaxSize()) {
        val open = openConversationId
        when {
            // A conversation and the scanner both take the whole screen: the tab
            // bar would only offer a way to walk out of the middle of something.
            open != null -> {
                val conversation = conversations.firstOrNull { it.id == open }
                ChatScreen(
                    title = conversation?.let(viewModel::titleFor) ?: "Conversation",
                    messages = messages,
                    ownAccount = phase.service.credentials.accountId,
                    // In a group each message carries its own sender; in a 1:1
                    // chat incoming ones do not, so the conversation's peer is
                    // the only thing that identifies the author.
                    peerAccount = conversation?.peerAccount.orEmpty(),
                    onSend = { body, quote -> viewModel.send(open, body, quote) },
                    onSendAttachment = { uri -> viewModel.sendAttachment(open, uri) },
                    onReact = { ts, author, emoji -> viewModel.react(open, ts, author, emoji) },
                    onEdit = { ts, body -> viewModel.editMessage(open, ts, body) },
                    onUnsend = { ts -> viewModel.unsend(open, ts) },
                    onDeleteLocally = viewModel::deleteLocally,
                    onToggleStar = viewModel::setStarred,
                    onCreatePoll = { question, options, multi ->
                        viewModel.createPoll(open, question, options, multi)
                    },
                    onVote = { author, ts, option ->
                        val multi = messages
                            .firstOrNull { it.timestamp == ts }
                            ?.let { app.relaymsg.core.PollPayload.fromBody(it.body) }
                            ?.multiSelect == true
                        viewModel.votePoll(open, author, ts, option, multi)
                    },
                    votesFor = { message ->
                        viewModel.pollVotes(
                            open,
                            message.senderAccount
                                ?: if (message.isOutgoing) {
                                    phase.service.credentials.accountId
                                } else {
                                    conversation?.peerAccount.orEmpty()
                                },
                            message.timestamp,
                        )
                    },
                    isBlocked = conversation?.peerAccount?.let { it in blockedAccounts } == true,
                    // A group has no single identity key, so no safety number.
                    onVerify = conversation
                        ?.takeIf { it.groupId == null }
                        ?.let { target -> { verifyPeer = target.peerAccount } },
                    disappearingSeconds = conversation?.disappearingSeconds ?: 0,
                    onSetDisappearing = { seconds -> viewModel.setDisappearing(open, seconds) },
                    // A group has no single account to block, so the action is
                    // hidden rather than shown doing nothing.
                    onToggleBlock = conversation
                        ?.takeIf { it.groupId == null }
                        ?.let { target ->
                            {
                                if (target.peerAccount in blockedAccounts) {
                                    viewModel.unblockAccount(target.peerAccount)
                                } else {
                                    viewModel.blockAccount(target.peerAccount)
                                }
                            }
                        },
                    onTogglePin = { id, pinned -> viewModel.setPinned(open, id, pinned) },
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

            verifyPeer != null -> {
                val account = verifyPeer!!
                val safety = remember(account) { viewModel.safetyNumber(account) }
                val scanResult by viewModel.scanResult.collectAsState()
                var scanning by remember { mutableStateOf(false) }

                if (scanning) {
                    ScanLinkScreen(
                        status = null,
                        error = null,
                        onScanned = { code ->
                            viewModel.verifyScanned(account, code)
                            scanning = false
                        },
                        onBack = { scanning = false },
                    )
                } else {
                    VerificationScreen(
                        peerName = viewModel.nameFor(account),
                        numeric = safety?.numeric,
                        scannableBase64 = safety?.scannable
                            ?.let { java.util.Base64.getEncoder().encodeToString(it) },
                        state = viewModel.verification(account),
                        onSetVerified = { viewModel.setVerified(account, it) },
                        onScan = { scanning = true },
                        scanResult = scanResult,
                        onDismissResult = viewModel::dismissScanResult,
                        onBack = { viewModel.dismissScanResult(); verifyPeer = null },
                    )
                }
            }

            showProfile -> {
                val profile by viewModel.myProfile.collectAsState()
                val pending by viewModel.pendingAvatar.collectAsState()
                val pickAvatar = androidx.activity.compose.rememberLauncherForActivityResult(
                    androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia(),
                ) { uri -> uri?.let(viewModel::pickAvatar) }
                ProfileScreen(
                    accountId = phase.service.credentials.accountId,
                    username = phase.service.username,
                    displayName = profile.displayName,
                    // The picked photo wins until it is saved, so the preview
                    // shows what pressing Save would actually publish.
                    avatar = pending ?: profile.avatar,
                    busy = busy,
                    onPickAvatar = {
                        pickAvatar.launch(
                            androidx.activity.result.PickVisualMediaRequest(
                                androidx.activity.result.contract.ActivityResultContracts
                                    .PickVisualMedia.ImageOnly,
                            ),
                        )
                    },
                    onSave = { name, avatar ->
                        viewModel.saveProfile(name, avatar)
                        showProfile = false
                    },
                    onBack = { showProfile = false },
                )
            }

            showBlocked -> {
                val blocked by viewModel.blockedAccounts.collectAsState()
                BlockedContactsScreen(
                    blocked = blocked.sorted(),
                    nameFor = viewModel::nameFor,
                    onUnblock = viewModel::unblockAccount,
                    onBack = { showBlocked = false },
                )
            }

            showScanner -> {
                val scanStatus by viewModel.scanStatus.collectAsState()
                val scanError by viewModel.scanError.collectAsState()
                ScanLinkScreen(
                    status = scanStatus,
                    error = scanError,
                    onScanned = viewModel::provisionScanned,
                    onBack = { viewModel.resetScan(); showScanner = false },
                )
            }

            else -> Column(Modifier.fillMaxSize()) {
                // Each tab keeps its own Scaffold and top bar, so the bar sits
                // beside them rather than wrapping them in a second Scaffold.
                Box(Modifier.weight(1f)) {
                    when (tab) {
                        Tab.CHATS -> ConversationListScreen(
                            connection = connection,
                            conversations = conversations,
                            titleFor = viewModel::titleFor,
                            busy = busy,
                            onOpen = { id -> viewModel.openConversation(id); openConversationId = id },
                            onStartConversation = viewModel::startConversation,
                            onPin = viewModel::setConversationPinned,
                            onArchive = viewModel::setConversationArchived,
                            onMarkUnread = viewModel::markConversationUnread,
                            onDelete = viewModel::deleteConversation,
                        )

                        Tab.CALLS -> {
                            val calls by viewModel.callLog.collectAsState()
                            CallLogScreen(
                                calls = calls,
                                onClear = viewModel::clearCallLog,
                                onCall = viewModel::placeCall,
                            )
                        }

                        Tab.SETTINGS -> {
                            val privateCalls by viewModel.privateCallMode.collectAsState()
                            val pushContent by viewModel.pushIncludesContent.collectAsState()
                            val devices by viewModel.devices.collectAsState()
                            val inviteLink by viewModel.inviteLink.collectAsState()
                            val blocked by viewModel.blockedAccounts.collectAsState()
                            val profile by viewModel.myProfile.collectAsState()
                            val context = androidx.compose.ui.platform.LocalContext.current
                            // Read live each time the tab opens: another device
                            // may have been linked since it was last shown.
                            LaunchedEffect(Unit) { viewModel.refreshSettings() }
                            SettingsScreen(
                                username = phase.service.username,
                                displayName = profile.displayName,
                                avatar = profile.avatar,
                                accountId = phase.service.credentials.accountId,
                                deviceId = phase.service.credentials.deviceId,
                                server = phase.service.server,
                                privateCallMode = privateCalls,
                                pushIncludesContent = pushContent,
                                devices = devices,
                                onPrivateCallMode = viewModel::setPrivateCallMode,
                                onPushIncludesContent = viewModel::setPushIncludesContent,
                                onLinkDevice = { viewModel.resetScan(); showScanner = true },
                                onClearCallLog = viewModel::clearCallLog,
                                onSignOut = viewModel::signOut,
                                publicLink = phase.service.publicLink,
                                inviteLink = inviteLink,
                                appVersion = remember { context.appVersion() },
                                blockedCount = blocked.size,
                                onCreateInvite = { viewModel.shareInvite(context) },
                                onShowBlocked = { showBlocked = true },
                                onEditProfile = { showProfile = true },
                                onRemoveDevice = viewModel::removeDevice,
                            )
                        }
                    }
                }
                RelayTabBar(tab, unread = conversations.sumOf { it.unreadCount }) { tab = it }
            }
        }

        InCallOverlay(viewModel)
    }
}

private enum class Tab(val label: String) { CHATS("Chats"), CALLS("Calls"), SETTINGS("Settings") }

@Composable
private fun RelayTabBar(selected: Tab, unread: Int, onSelect: (Tab) -> Unit) {
    NavigationBar {
        Tab.entries.forEach { entry ->
            NavigationBarItem(
                selected = entry == selected,
                onClick = { onSelect(entry) },
                icon = {
                    if (entry == Tab.CHATS && unread > 0) {
                        BadgedBox(
                            badge = {
                                Badge { Text(if (unread > 99) "99+" else "$unread") }
                            },
                        ) { Icon(entry.icon(), contentDescription = null) }
                    } else {
                        Icon(entry.icon(), contentDescription = null)
                    }
                },
                label = { Text(entry.label) },
            )
        }
    }
}

/** The installed version, read from the package rather than hard-coded. */
private fun android.content.Context.appVersion(): String = runCatching {
    packageManager.getPackageInfo(packageName, 0).versionName.orEmpty()
}.getOrDefault("")

private fun Tab.icon() = when (this) {
    Tab.CHATS -> Icons.AutoMirrored.Filled.Chat
    Tab.CALLS -> Icons.Filled.Call
    Tab.SETTINGS -> Icons.Filled.Settings
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

    val context = androidx.compose.ui.platform.LocalContext.current
    val projection = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        result.data
            ?.takeIf { result.resultCode == android.app.Activity.RESULT_OK }
            ?.let(viewModel::startScreenShare)
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
        onToggleScreenShare = {
            if (active.isScreenSharing) {
                viewModel.stopScreenShare()
            } else {
                CallService.prepareProjection(context)
                projection.launch(
                    (context.getSystemService(android.media.projection.MediaProjectionManager::class.java))
                        .createScreenCaptureIntent(),
                )
            }
        },
        audioRoutes = viewModel::audioRoutes,
        onSelectRoute = viewModel::selectAudioRoute,
    )
}

@Composable
private fun Centered(content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { content() }
}
