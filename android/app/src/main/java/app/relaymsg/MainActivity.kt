package app.relaymsg

import android.content.Intent
import android.os.Bundle
import androidx.fragment.app.FragmentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxWidth
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
import app.relaymsg.core.CallState
import app.relaymsg.call.GroupCallScreen
import app.relaymsg.ui.BackupScreen
import app.relaymsg.ui.DevicesSettingsScreen
import app.relaymsg.ui.PrivacySettingsScreen
import app.relaymsg.ui.SecuritySettingsScreen
import app.relaymsg.ui.BlockedContactsScreen
import app.relaymsg.ui.CallLogScreen
import app.relaymsg.ui.AppearanceScreen
import app.relaymsg.ui.AuthScreen
import app.relaymsg.ui.ContactCardScreen
import app.relaymsg.ui.ContactSyncScreen
import app.relaymsg.ui.GroupInfoScreen
import app.relaymsg.ui.ChatScreen
import app.relaymsg.ui.ConversationListScreen
import app.relaymsg.ui.LinkDeviceScreen
import app.relaymsg.ui.MediaGalleryScreen
import app.relaymsg.ui.NotepadScreen
import app.relaymsg.ui.ScheduledMessagesScreen
import app.relaymsg.ui.ProfileScreen
import app.relaymsg.ui.ScanLinkScreen
import app.relaymsg.ui.VerificationScreen
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Person
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

class MainActivity : FragmentActivity() {

    private val viewModel: RelayViewModel by viewModels()

    /**
     * When the app last went to the background.
     *
     * The lock re-arms on time spent away, not on every glance at a
     * notification — otherwise a two-second detour to the shade demands a
     * fingerprint, and people turn the feature off.
     */
    private var backgroundedAt: Long? = null

    override fun onStop() {
        super.onStop()
        backgroundedAt = System.currentTimeMillis()
    }

    override fun onStart() {
        super.onStart()
        val away = backgroundedAt?.let { System.currentTimeMillis() - it } ?: 0L
        backgroundedAt = null
        viewModel.onForeground(away, this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // A cold start through the OAuth link: the browser tab handed back
        // before this activity existed.
        intent?.data?.let { handleLink(it) }
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
        intent.data?.let { handleLink(it) }
    }

    /** OAuth first, then contact links — the two never overlap. */
    private fun handleLink(uri: android.net.Uri) {
        if (viewModel.onOAuthRedirect(uri)) return
        viewModel.onContactLink(uri)
    }
}

@Composable
private fun RelayApp(viewModel: RelayViewModel) {
    val phase by viewModel.phase.collectAsState()
    val busy by viewModel.busy.collectAsState()

    val locked by viewModel.locked.collectAsState()
    if (locked) {
        val activity = androidx.compose.ui.platform.LocalContext.current as FragmentActivity
        LockedScreen { viewModel.unlock(activity) }
        return
    }

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
    var showBackup by remember { mutableStateOf(false) }
    var showPrivacy by remember { mutableStateOf(false) }
    var showSecurity by remember { mutableStateOf(false) }
    var showDevices by remember { mutableStateOf(false) }
    var showProfile by remember { mutableStateOf(false) }
    var verifyPeer by remember { mutableStateOf<String?>(null) }
    var galleryFor by remember { mutableStateOf<String?>(null) }
    var appearanceFor by remember { mutableStateOf<String?>(null) }
    var showContactCard by remember { mutableStateOf(false) }
    var showContactSync by remember { mutableStateOf(false) }
    var showScheduled by remember { mutableStateOf(false) }
    var notepadFor by remember { mutableStateOf<String?>(null) }
    var groupInfoFor by remember { mutableStateOf<String?>(null) }

    // A link or a scan resolves to a username; opening it lands in the thread.
    val pendingContact by viewModel.pendingContact.collectAsState()
    LaunchedEffect(pendingContact) {
        val username = pendingContact ?: return@LaunchedEffect
        viewModel.clearPendingContact()
        viewModel.startConversation(
            username,
            onOpened = { id ->
                showContactCard = false
                showContactSync = false
                viewModel.openConversation(id)
                openConversationId = id
            },
            onError = { },
        )
    }
    val blockedAccounts by viewModel.blockedAccounts.collectAsState()
    val panicEnabled by viewModel.panicEnabled.collectAsState()
    val profileForCard by viewModel.myProfile.collectAsState()
    val hiddenConversations by viewModel.hiddenConversations.collectAsState()
    val searchResults by viewModel.searchResults.collectAsState()
    var tab by rememberSaveable { mutableStateOf(Tab.CHATS) }

    // Every full-screen state below is a push onto the tab UI, so the system
    // back gesture has to pop it. Without this, back from any of them leaves
    // the app entirely — which reads as a crash.
    val onScreen = openConversationId != null || groupInfoFor != null || notepadFor != null ||
        showScheduled || galleryFor != null || appearanceFor != null || verifyPeer != null ||
        showProfile || showBlocked || showBackup || showScanner || showContactCard ||
        showContactSync || showPrivacy || showSecurity || showDevices
    BackHandler(enabled = onScreen) {
        when {
            // Innermost first: a sheet opened from inside a conversation closes
            // back to the conversation, not to the list.
            groupInfoFor != null -> groupInfoFor = null
            notepadFor != null -> notepadFor = null
            galleryFor != null -> galleryFor = null
            appearanceFor != null -> appearanceFor = null
            verifyPeer != null -> verifyPeer = null
            openConversationId != null -> {
                viewModel.closeConversation()
                openConversationId = null
            }
            showScheduled -> showScheduled = false
            showProfile -> showProfile = false
            showBlocked -> showBlocked = false
            showBackup -> showBackup = false
            showPrivacy -> showPrivacy = false
            showSecurity -> showSecurity = false
            showDevices -> showDevices = false
            showContactCard -> showContactCard = false
            showContactSync -> showContactSync = false
            showScanner -> showScanner = false
        }
    }

    Box(Modifier.fillMaxSize()) {
        val open = openConversationId
        when {
            // These five open from inside a conversation and sit on top of
            // it, so they have to be matched before the conversation branch —
            // below it they would never be reached, and their back action
            // returns to the chat because it stays open underneath.
            groupInfoFor != null -> {
                val id = groupInfoFor!!
                // Re-read on every conversation change, so a roster edit shows
                // immediately rather than after backing out and returning.
                val group = remember(id, conversations, busy) { viewModel.group(id) }
                if (group == null) {
                    groupInfoFor = null
                } else {
                    GroupInfoScreen(
                        group = group,
                        ownAccount = phase.service.credentials.accountId,
                        nameFor = viewModel::nameFor,
                        busy = busy,
                        onRename = { viewModel.renameGroup(id, it) },
                        onAddMember = { viewModel.addGroupMember(id, it) },
                        onRemoveMember = { viewModel.removeGroupMember(id, it) },
                        onSetAdmin = { account, admin ->
                            viewModel.setGroupAdmin(id, account, admin)
                        },
                        onSetAnnounceOnly = { viewModel.setGroupAnnounceOnly(id, it) },
                        onLeave = {
                            viewModel.leaveGroup(id)
                            groupInfoFor = null
                            openConversationId = null
                        },
                        onBack = { groupInfoFor = null },
                    )
                }
            }

            notepadFor != null -> {
                val id = notepadFor!!
                NotepadScreen(
                    title = conversations.firstOrNull { it.id == id }
                        ?.let(viewModel::titleFor) ?: "this chat",
                    initialContent = remember(id, messages) { viewModel.notepadContent(id) },
                    busy = busy,
                    onSave = { content -> viewModel.saveNotepad(id, content) },
                    onBack = { notepadFor = null },
                )
            }

            galleryFor != null -> {
                val id = galleryFor!!
                MediaGalleryScreen(
                    title = conversations.firstOrNull { it.id == id }
                        ?.let(viewModel::titleFor) ?: "conversation",
                    attachments = remember(id) { viewModel.attachmentsIn(id) },
                    load = { viewModel.attachmentBytes(it) },
                    onBack = { galleryFor = null },
                )
            }

            appearanceFor != null -> {
                val id = appearanceFor!!
                // Read once per entry and held locally, so each tap repaints
                // the preview without a round trip through the store.
                var chosen by remember(id) { mutableStateOf(viewModel.appearance(id)) }
                AppearanceScreen(
                    title = conversations.firstOrNull { it.id == id }
                        ?.let(viewModel::titleFor) ?: "this chat",
                    wallpaperId = chosen.first,
                    bubbleKey = chosen.second,
                    onPick = { wallpaper, bubble ->
                        chosen = wallpaper to bubble
                        viewModel.setAppearance(id, wallpaper, bubble)
                    },
                    onBack = { appearanceFor = null },
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

            // A conversation and the scanner both take the whole screen: the
            // tab bar would only offer a way to walk out of the middle of
            // something.
            open != null -> {
                val conversation = conversations.firstOrNull { it.id == open }
                val appearance = remember(open, appearanceFor) { viewModel.appearance(open) }
                val recording by viewModel.recording.collectAsState()
                val sharingLocation by viewModel.sharingLocation.collectAsState()
                val locationPermission = androidx.activity.compose.rememberLauncherForActivityResult(
                    androidx.activity.result.contract.ActivityResultContracts
                        .RequestMultiplePermissions(),
                ) { granted ->
                    if (granted.values.any { it }) viewModel.startLocationShare(open)
                }
                val context = androidx.compose.ui.platform.LocalContext.current
                val microphone = androidx.activity.compose.rememberLauncherForActivityResult(
                    androidx.activity.result.contract.ActivityResultContracts.RequestPermission(),
                ) { granted -> if (granted) viewModel.startRecording() }
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
                    wallpaperId = appearance.first,
                    bubbleKey = appearance.second,
                    onShowGallery = { galleryFor = open },
                    onShowAppearance = { appearanceFor = open },
                    onShowNotepad = { notepadFor = open },
                    onShowGroupInfo = conversation?.groupId?.let { id -> { groupInfoFor = id } },
                    liveLocation = remember(open, messages) { viewModel.liveLocation(open) }
                        ?.let { (who, payload) -> who to payload },
                    onOpenMap = { uri ->
                        runCatching {
                            context.startActivity(
                                Intent(Intent.ACTION_VIEW, android.net.Uri.parse(uri)),
                            )
                        }
                    },
                    sharingLocation = sharingLocation,
                    onToggleLocation = {
                        if (sharingLocation) {
                            viewModel.stopLocationShare(open)
                        } else if (hasLocation(context)) {
                            viewModel.startLocationShare(open)
                        } else {
                            locationPermission.launch(
                                arrayOf(
                                    android.Manifest.permission.ACCESS_FINE_LOCATION,
                                    android.Manifest.permission.ACCESS_COARSE_LOCATION,
                                ),
                            )
                        }
                    },
                    onSchedule = { body, at -> viewModel.scheduleMessage(open, body, at) },
                    recording = recording,
                    onStartRecording = {
                        if (hasMicrophone(context)) {
                            viewModel.startRecording()
                        } else {
                            microphone.launch(android.Manifest.permission.RECORD_AUDIO)
                        }
                    },
                    onFinishRecording = { viewModel.finishRecording(open) },
                    onCancelRecording = viewModel::cancelRecording,
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



            showScheduled -> {
                val queued by viewModel.scheduled.collectAsState()
                ScheduledMessagesScreen(
                    messages = queued,
                    titleFor = { id ->
                        conversations.firstOrNull { it.id == id }
                            ?.let(viewModel::titleFor) ?: "a conversation"
                    },
                    onCancel = viewModel::cancelScheduled,
                    onBack = { showScheduled = false },
                )
            }

            showContactCard -> ContactCardScreen(
                username = phase.service.username,
                displayName = profileForCard.displayName,
                accountId = phase.service.credentials.accountId,
                onBack = { showContactCard = false },
            )

            showContactSync -> ContactSyncScreen(
                onSync = { viewModel.discoverContacts(it) },
                onStart = { username -> viewModel.onScannedUsername(username) },
                onBack = { showContactSync = false },
            )




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

            showPrivacy -> {
                val privateCalls by viewModel.privateCallMode.collectAsState()
                val pushContent by viewModel.pushIncludesContent.collectAsState()
                PrivacySettingsScreen(
                    privateCallMode = privateCalls,
                    pushIncludesContent = pushContent,
                    onPrivateCallMode = viewModel::setPrivateCallMode,
                    onPushIncludesContent = viewModel::setPushIncludesContent,
                    onBack = { showPrivacy = false },
                )
            }

            showSecurity -> {
                val screenLock by viewModel.screenLock.collectAsState()
                val lockTimeout by viewModel.lockTimeout.collectAsState()
                val panic by viewModel.panicEnabled.collectAsState()
                SecuritySettingsScreen(
                    screenLock = screenLock,
                    lockTimeout = lockTimeout,
                    panicEnabled = panic,
                    onScreenLock = { viewModel.screenLockEnabled = it },
                    onLockTimeout = viewModel::setLockTimeout,
                    onEnablePanic = viewModel::enablePanic,
                    onDisablePanic = viewModel::disablePanic,
                    onBack = { showSecurity = false },
                )
            }

            showDevices -> {
                val devices by viewModel.devices.collectAsState()
                DevicesSettingsScreen(
                    devices = devices,
                    thisDeviceId = phase.service.credentials.deviceId,
                    onLinkDevice = { showDevices = false; showScanner = true },
                    onRemoveDevice = viewModel::removeDevice,
                    onBack = { showDevices = false },
                )
            }

            showBackup -> {
                val backupEnabled by viewModel.backupEnabled.collectAsState()
                val lastBackupAt by viewModel.lastBackupAt.collectAsState()
                BackupScreen(
                    enabled = backupEnabled,
                    lastBackupAt = lastBackupAt,
                    recoveryKey = viewModel::recoveryKey,
                    onSetEnabled = viewModel::setBackupEnabled,
                    onWriteBackup = viewModel::writeBackup,
                    onRestore = viewModel::restoreBackup,
                    onExportWithPassword = viewModel::exportPasswordBackup,
                    onImportWithPassword = viewModel::importPasswordBackup,
                    onBack = { showBackup = false },
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
                            panicEnabled = panicEnabled,
                            hiddenConversations = hiddenConversations,
                            onToggleHidden = viewModel::setConversationHidden,
                            searchResults = searchResults,
                            onSearch = viewModel::search,
                        )

                        Tab.CALLS -> {
                            val calls by viewModel.callLog.collectAsState()
                            CallLogScreen(
                                calls = calls,
                                onClear = viewModel::clearCallLog,
                                onCall = viewModel::placeCall,
                            )
                        }

                        Tab.PROFILE -> {
                            val privateCalls by viewModel.privateCallMode.collectAsState()
                            val pushContent by viewModel.pushIncludesContent.collectAsState()
                            val devices by viewModel.devices.collectAsState()
                            val inviteLink by viewModel.inviteLink.collectAsState()
                            val blocked by viewModel.blockedAccounts.collectAsState()
                            val profile by viewModel.myProfile.collectAsState()
                            val backupEnabled by viewModel.backupEnabled.collectAsState()
                            val scheduledCount by viewModel.scheduled.collectAsState()
                            val screenLock by viewModel.screenLock.collectAsState()
                            val lockTimeout by viewModel.lockTimeout.collectAsState()
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
                                screenLock = screenLock,
                                lockTimeout = lockTimeout,
                                onScreenLock = { viewModel.screenLockEnabled = it },
                                onLockTimeout = viewModel::setLockTimeout,
                                panicEnabled = panicEnabled,
                                onEnablePanic = viewModel::enablePanic,
                                onDisablePanic = viewModel::disablePanic,
                                onCreateInvite = { viewModel.shareInvite(context) },
                                onShowBlocked = { showBlocked = true },
                                onShowContactCard = { showContactCard = true },
                                onShowContactSync = { showContactSync = true },
                                scheduledCount = scheduledCount.size,
                                onShowScheduled = { showScheduled = true },
                                onEditProfile = { showProfile = true },
                                onRemoveDevice = viewModel::removeDevice,
                                onShowBackup = { showBackup = true },
                                backupEnabled = backupEnabled,
                                onShowPrivacy = { showPrivacy = true },
                                onShowSecurity = { showSecurity = true },
                                onShowDevices = { showDevices = true },
                            )
                        }
                    }
                }
                RelayTabBar(
                    selected = tab,
                    unread = conversations.sumOf { it.unreadCount },
                    avatarName = profileForCard.displayName.ifEmpty { phase.service.username },
                    avatarData = profileForCard.avatar,
                ) { tab = it }
            }
        }

        InCallOverlay(viewModel)
    }
}

private enum class Tab(val label: String) { CHATS("Chats"), CALLS("Calls"), PROFILE("Profile") }

/**
 * The tab bar.
 *
 * Material's own, deliberately: iOS floats a capsule here, but a navigation bar
 * is one of the places the two platforms genuinely differ, and an Android app
 * that fakes the iOS one just reads as wrong. The content above it matches;
 * this does not have to.
 *
 * The Profile tab carries the account's own avatar rather than a glyph, which
 * is both what iOS shows and what Android's own apps do — it is the quickest
 * way to see which account is signed in.
 */
@Composable
private fun RelayTabBar(
    selected: Tab,
    unread: Int,
    avatarName: String,
    avatarData: ByteArray?,
    onSelect: (Tab) -> Unit,
) {
    NavigationBar {
        Tab.entries.forEach { entry ->
            NavigationBarItem(
                selected = entry == selected,
                onClick = { onSelect(entry) },
                icon = {
                    BadgedBox(
                        badge = {
                            if (entry == Tab.CHATS && unread > 0) {
                                Badge { Text(if (unread > 99) "99+" else "$unread") }
                            }
                        },
                    ) {
                        if (entry == Tab.PROFILE) {
                            app.relaymsg.ui.Avatar(
                                id = avatarName,
                                name = avatarName,
                                size = 24.dp,
                                imageData = avatarData,
                            )
                        } else {
                            Icon(entry.icon(), contentDescription = null)
                        }
                    }
                },
                label = { Text(entry.label) },
            )
        }
    }
}


/**
 * The strip a minimised call leaves behind.
 *
 * Without it, minimising would hide a live call with no way back to it short of
 * hanging up from the notification — which is how people end up on a call they
 * think they left.
 */
@Composable
private fun OngoingCallBar(label: String, onClick: () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        Surface(
            color = app.relaymsg.call.AnswerGreen,
            contentColor = androidx.compose.ui.graphics.Color.White,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 28.dp)
                .clickable(onClick = onClick),
        ) {
            Text(
                text = "Tap to return to call with $label",
                style = MaterialTheme.typography.labelLarge,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
            )
        }
    }
}

private fun hasLocation(context: android.content.Context): Boolean =
    listOf(
        android.Manifest.permission.ACCESS_FINE_LOCATION,
        android.Manifest.permission.ACCESS_COARSE_LOCATION,
    ).any {
        androidx.core.content.ContextCompat.checkSelfPermission(context, it) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
    }

private fun hasMicrophone(context: android.content.Context): Boolean =
    androidx.core.content.ContextCompat.checkSelfPermission(
        context,
        android.Manifest.permission.RECORD_AUDIO,
    ) == android.content.pm.PackageManager.PERMISSION_GRANTED

/** The installed version, read from the package rather than hard-coded. */
private fun android.content.Context.appVersion(): String = runCatching {
    packageManager.getPackageInfo(packageName, 0).versionName.orEmpty()
}.getOrDefault("")

private fun Tab.icon() = when (this) {
    Tab.CHATS -> Icons.AutoMirrored.Filled.Chat
    Tab.CALLS -> Icons.Filled.Call
    Tab.PROFILE -> Icons.Filled.Person
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

    // Minimising keeps the call up but hands the app back; a bar stays on top so
    // there is always a way in. Keyed on the call, so the next one opens full.
    var minimised by remember(active.callId) { mutableStateOf(false) }
    if (minimised) {
        OngoingCallBar(
            label = viewModel.callerName(active),
            onClick = { minimised = false },
        )
        return
    }

    CallScreen(
        call = active,
        peerName = viewModel.callerName(active),
        peerAvatar = remember(active.callId) { viewModel.callerAvatar(active) },
        // Not while it is ringing at you: the only two answers to an incoming
        // call are accept and decline, and a third way out that leaves it
        // ringing is how people miss calls they meant to take.
        onMinimise = { minimised = true }
            .takeIf { active.state != CallState.INCOMING_RINGING },
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

/** What stands in for the app while it is locked. */
@Composable
private fun LockedScreen(onUnlock: () -> Unit) {
    // Prompts on arrival; the button is for when the prompt was dismissed.
    androidx.compose.runtime.LaunchedEffect(Unit) { onUnlock() }
    Centered {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Relay is locked", style = MaterialTheme.typography.headlineSmall)
            Button(onClick = onUnlock, modifier = Modifier.padding(top = 16.dp)) {
                Text("Unlock")
            }
        }
    }
}

@Composable
private fun Centered(content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { content() }
}
