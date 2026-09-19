package app.relaymsg

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import app.relaymsg.call.CallService
import app.relaymsg.call.CallWake
import app.relaymsg.core.ActiveCall
import app.relaymsg.core.ActiveGroupCall
import app.relaymsg.core.AudioRoute
import app.relaymsg.core.AudioRouteKind
import app.relaymsg.core.ConnectionState
import app.relaymsg.core.EmailAuthResult
import app.relaymsg.core.RelayService
import app.relaymsg.net.LinkedDevice
import app.relaymsg.net.PkcePair
import app.relaymsg.net.SupabaseAuth
import app.relaymsg.push.RelayRuntime
import app.relaymsg.storage.Conversation
import app.relaymsg.storage.QuotedMessage
import app.relaymsg.ui.AuthStep
import app.relaymsg.storage.StoredCall
import app.relaymsg.storage.StoredMessage
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

/** What the app is currently showing. */
sealed interface AppPhase {
    data object Loading : AppPhase
    data object SignedOut : AppPhase
    data class Ready(val service: RelayService) : AppPhase
    data class Failed(val message: String) : AppPhase

    /**
     * Showing a linking QR and waiting for the primary.
     *
     * A null [qr] means the rendezvous session is still being created; a
     * non-null [error] means the attempt failed and can be retried.
     */
    data class Linking(val qr: String?, val error: String?) : AppPhase
}

/** Must also be listed in Supabase → Authentication → URL Configuration. */
private const val OAUTH_REDIRECT = "app.relaymsg://auth-callback"

class RelayViewModel(application: Application) : AndroidViewModel(application) {

    private val _phase = MutableStateFlow<AppPhase>(AppPhase.Loading)
    val phase: StateFlow<AppPhase> = _phase.asStateFlow()

    private val _busy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = _busy.asStateFlow()

    private val service: RelayService? get() = (_phase.value as? AppPhase.Ready)?.service

    @Suppress("OPT_IN_USAGE")
    val conversations: StateFlow<List<Conversation>> = _phase
        .flatMapLatest { (it as? AppPhase.Ready)?.service?.conversations ?: flowOf(emptyList()) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    @Suppress("OPT_IN_USAGE")
    val activeMessages: StateFlow<List<StoredMessage>> = _phase
        .flatMapLatest { (it as? AppPhase.Ready)?.service?.activeMessages ?: flowOf(emptyList()) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    @Suppress("OPT_IN_USAGE")
    val connection: StateFlow<ConnectionState> = _phase
        .flatMapLatest {
            (it as? AppPhase.Ready)?.service?.connection ?: flowOf(ConnectionState.DISCONNECTED)
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), ConnectionState.DISCONNECTED)

    init {
        viewModelScope.launch {
            _phase.value = runCatching { RelayService.restore(getApplication()) }
                .fold(
                    onSuccess = { restored ->
                        restored?.let { it.startUp(); AppPhase.Ready(it) } ?: AppPhase.SignedOut
                    },
                    onFailure = { AppPhase.Failed(it.friendlyMessage()) },
                )
        }
    }

    fun register(username: String) {
        if (_busy.value) return
        _busy.value = true
        viewModelScope.launch {
            _phase.value = runCatching { RelayService.register(getApplication(), username) }
                .fold(
                    onSuccess = { it.startUp(); AppPhase.Ready(it) },
                    onFailure = { AppPhase.Failed(it.friendlyMessage()) },
                )
            _busy.value = false
        }
    }

    private val _authStep = MutableStateFlow(AuthStep.WELCOME)

    /** Which part of onboarding is showing. Only meaningful while signed out. */
    val authStep: StateFlow<AuthStep> = _authStep.asStateFlow()

    private val _authError = MutableStateFlow<String?>(null)
    val authError: StateFlow<String?> = _authError.asStateFlow()

    /**
     * A Supabase session waiting for a username.
     *
     * Held so choosing a username retries only the relay call — going back to
     * Supabase would fail, because by then the email is registered there.
     */
    private var pendingUsername: EmailAuthResult.UsernameRequired? = null

    fun showSignUp() = moveTo(AuthStep.SIGN_UP)

    fun showSignIn() = moveTo(AuthStep.SIGN_IN)

    fun authBack() {
        pendingUsername = null
        moveTo(AuthStep.WELCOME)
    }

    private fun moveTo(step: AuthStep) {
        _authError.value = null
        _authStep.value = step
    }

    private val _pendingAuthUrl = MutableStateFlow<String?>(null)

    /** Set when a browser tab should be opened for OAuth; cleared once it is. */
    val pendingAuthUrl: StateFlow<String?> = _pendingAuthUrl.asStateFlow()

    /**
     * The PKCE verifier for the sign-in currently in flight.
     *
     * In memory only, deliberately: it is the secret half of the exchange, and
     * writing it to disk would outlive the one attempt it belongs to. The cost
     * is that process death while the browser tab is in front loses it — see
     * [onOAuthRedirect], which reports that rather than failing silently.
     */
    private var pkce: PkcePair? = null

    fun startGoogleSignIn() {
        if (_busy.value) return
        _authError.value = null
        val pair = PkcePair.generate()
        pkce = pair
        _pendingAuthUrl.value = SupabaseAuth().authorizeUrl(
            provider = "google",
            redirectUri = OAUTH_REDIRECT,
            codeChallenge = pair.challenge,
        )
    }

    fun authUrlOpened() {
        _pendingAuthUrl.value = null
    }

    /**
     * Handles the redirect back from the browser.
     *
     * Returns false for anything that is not our callback, so the caller can
     * leave other intents alone.
     */
    fun onOAuthRedirect(uri: android.net.Uri): Boolean {
        if (uri.scheme != "app.relaymsg" || uri.host != "auth-callback") return false

        val verifier = pkce
        pkce = null
        if (verifier == null) {
            // The verifier lives in memory only, so it is gone if the process was
            // killed while the browser tab was in front. Say so: the alternative
            // is the user completing a Google sign-in, returning to the welcome
            // screen, and being told nothing at all.
            _authError.value = "Sign-in couldn't be completed. Please try again."
            return true
        }

        val code = uri.getQueryParameter("code")
        if (code == null) {
            // Supabase reports a refusal in the query string rather than an HTTP
            // status, since this arrives as a browser redirect.
            _authError.value = uri.getQueryParameter("error_description")
                ?: uri.getQueryParameter("error")
                        ?: "Sign-in was cancelled."
            return true
        }

        authenticate {
            val session = SupabaseAuth().exchangeOAuthCode(code, verifier.verifier)
            RelayService.signInWithOAuth(getApplication(), session)
        }
        return true
    }

    fun signUpWithEmail(email: String, password: String) =
        authenticate { RelayService.signUpWithEmail(getApplication(), email, password, null) }

    fun signInWithEmail(email: String, password: String) =
        authenticate { RelayService.signInWithEmail(getApplication(), email, password) }

    fun submitUsername(username: String) {
        val pending = pendingUsername ?: return authBack()

        authenticate { RelayService.completeWithUsername(getApplication(), pending, username) }
    }

    private fun authenticate(attempt: suspend () -> EmailAuthResult) {
        if (_busy.value) return
        _busy.value = true
        _authError.value = null
        viewModelScope.launch {
            runCatching { attempt() }
                .onSuccess { result ->
                    when (result) {
                        is EmailAuthResult.Ready -> {
                            pendingUsername = null
                            result.service.startUp()
                            _phase.value = AppPhase.Ready(result.service)
                        }
                        is EmailAuthResult.UsernameRequired -> {
                            pendingUsername = result
                            moveTo(AuthStep.USERNAME)
                        }
                    }
                }
                .onFailure { _authError.value = it.friendlyMessage() }
            _busy.value = false
        }
    }

    private val _scanStatus = MutableStateFlow<String?>(null)

    /** Non-null once a code has been read: progress, then the outcome. */
    val scanStatus: StateFlow<String?> = _scanStatus.asStateFlow()

    private val _scanError = MutableStateFlow<String?>(null)
    val scanError: StateFlow<String?> = _scanError.asStateFlow()

    /** Provisions a device whose QR we just scanned. Primary side of linking. */
    fun provisionScanned(qr: String) {
        val service = service ?: return
        if (_scanStatus.value != null) return
        _scanStatus.value = "Linking…"
        _scanError.value = null
        viewModelScope.launch {
            runCatching { service.linkOtherDevice(qr) }
                .onSuccess { _scanStatus.value = "Linked. The other device is signing in." }
                .onFailure {
                    _scanStatus.value = null
                    _scanError.value = it.friendlyMessage()
                }
        }
    }

    fun resetScan() {
        _scanStatus.value = null
        _scanError.value = null
    }

    private var linking: Job? = null

    /**
     * Links this device to an existing account instead of creating a new one.
     *
     * Runs to completion in one job: the relay deletes the rendezvous session on
     * the first successful fetch of the sealed payload, so abandoning it midway
     * means starting over with a new code.
     */
    fun startLinking() {
        if (linking?.isActive == true) return
        _phase.value = AppPhase.Linking(qr = null, error = null)
        linking = viewModelScope.launch {
            runCatching {
                val session = RelayService.beginLinking()
                _phase.value = AppPhase.Linking(qr = session.qr, error = null)
                RelayService.completeLinking(getApplication(), session)
            }.fold(
                onSuccess = { service -> service.startUp(); _phase.value = AppPhase.Ready(service) },
                onFailure = { failure ->
                    _phase.value = AppPhase.Linking(qr = null, error = failure.friendlyMessage())
                },
            )
        }
    }

    fun cancelLinking() {
        linking?.cancel()
        linking = null
        _phase.value = AppPhase.SignedOut
    }

    fun retry() {
        _phase.value = AppPhase.SignedOut
    }

    fun openConversation(conversationId: String) = service?.openConversation(conversationId)

    fun closeConversation() = service?.closeConversation()

    /**
     * Sends a picked image. The bytes are read here rather than in the service
     * so the content resolver (and the permission that came with the picker)
     * stays in the UI layer.
     */
    /** Sends any file the picker returns; the relay stores ciphertext either way. */
    fun sendAttachment(conversationId: String, uri: android.net.Uri) {
        val service = service ?: return
        viewModelScope.launch {
            runCatching {
                val resolver = getApplication<Application>().contentResolver
                val bytes = resolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: return@launch
                val type = resolver.getType(uri) ?: "application/octet-stream"
                service.sendAttachments(
                    conversationId = conversationId,
                    body = "",
                    attachments = listOf(
                        RelayService.OutgoingAttachment(
                            bytes = bytes,
                            contentType = type,
                            filename = uri.lastPathSegment,
                        ),
                    ),
                )
            }
        }
    }

    /** Decrypts an attachment for display, downloading it if needed. */
    suspend fun attachmentBytes(attachment: app.relaymsg.storage.StoredAttachment): ByteArray? =
        service?.attachmentBytes(attachment)

    fun send(conversationId: String, body: String, quote: QuotedMessage? = null) {
        val service = service ?: return
        viewModelScope.launch { service.sendText(conversationId, body, quote) }
    }

    fun react(conversationId: String, targetTimestamp: Long, targetAuthor: String, emoji: String) {
        val service = service ?: return
        viewModelScope.launch {
            service.toggleReaction(conversationId, targetTimestamp, targetAuthor, emoji)
        }
    }

    fun editMessage(conversationId: String, targetTimestamp: Long, newBody: String) {
        val service = service ?: return
        viewModelScope.launch { service.editMessage(conversationId, targetTimestamp, newBody) }
    }

    fun unsend(conversationId: String, targetTimestamp: Long) {
        val service = service ?: return
        viewModelScope.launch { service.unsendMessage(conversationId, targetTimestamp) }
    }

    fun deleteLocally(messageId: String) = service?.deleteMessageLocally(messageId)

    /** Resolves a username and opens the conversation, invoking [onOpened] with its id. */
    fun startConversation(username: String, onOpened: (String) -> Unit, onError: (String) -> Unit) {
        val service = service ?: return
        if (_busy.value) return
        _busy.value = true
        viewModelScope.launch {
            runCatching { service.startConversation(username.trim()) }
                .onSuccess { id -> service.refreshConversations(); onOpened(id) }
                .onFailure { onError(it.friendlyMessage()) }
            _busy.value = false
        }
    }

    // ----------------------------------------------------------------- calls

    @Suppress("OPT_IN_USAGE")
    val call: StateFlow<ActiveCall?> = _phase
        .flatMapLatest { (it as? AppPhase.Ready)?.service?.calls?.call ?: flowOf(null) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    fun placeCall(peerAccount: String, isVideo: Boolean = false) {
        val service = service ?: return
        viewModelScope.launch {
            val callId = service.calls.placeCall(peerAccount, isVideo) ?: return@launch
            holdProcessOpen(service, peerAccount, callId, isVideo)
        }
    }

    fun acceptCall() {
        val service = service ?: return
        val call = call.value ?: return
        viewModelScope.launch {
            if (service.calls.accept()) {
                holdProcessOpen(service, call.peerAccount, call.callId, call.isVideo)
            }
        }
    }

    /**
     * Puts the call behind a foreground service.
     *
     * Only needed for calls that started in the UI: one woken by a push is
     * already inside [CallService]. Without it, backgrounding the app during a
     * call lets the system freeze the process, which drops the call.
     */
    /**
     * [subject] is the peer's account for a 1:1 call and the group id for a group
     * one; [CallWake] only uses it to label the notification, so it does not care
     * which.
     */
    private fun holdProcessOpen(
        service: RelayService,
        subject: String,
        callId: String,
        isVideo: Boolean,
    ) = CallService.ongoing(
        getApplication(),
        CallWake(callId, subject, service.displayName(subject), isVideo),
    )

    fun hangUp() {
        val service = service ?: return
        viewModelScope.launch { service.calls.hangUp() }
    }

    fun toggleMute() {
        val service = service ?: return
        service.calls.setMuted(!(call.value?.isMuted ?: false))
    }

    fun toggleSpeaker() {
        val service = service ?: return
        service.calls.setSpeakerOn(call.value?.audioRoute != AudioRouteKind.SPEAKER)
    }

    /** The outputs available right now; only meaningful during a call. */
    fun audioRoutes(): List<AudioRoute> = service?.calls?.audioRoutes().orEmpty()

    fun selectAudioRoute(route: AudioRoute) {
        service?.calls?.selectAudioRoute(route)
    }

    fun switchCamera() {
        service?.calls?.switchCamera()
    }

    fun toggleCamera() {
        val service = service ?: return
        service.calls.setCameraEnabled(!(call.value?.isCameraOn ?: true))
    }

    /** The call history, newest first. */
    @Suppress("OPT_IN_USAGE")
    val callLog: StateFlow<List<StoredCall>> = _phase
        .flatMapLatest { (it as? AppPhase.Ready)?.service?.callLog ?: flowOf(emptyList()) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    fun clearCallLog() = service?.clearCallLog()

    // ----------------------------------------------------------- group calls

    @Suppress("OPT_IN_USAGE")
    val groupCall: StateFlow<ActiveGroupCall?> = _phase
        .flatMapLatest { (it as? AppPhase.Ready)?.service?.groupCalls?.call ?: flowOf(null) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    fun startGroupCall(groupId: String, isVideo: Boolean) {
        val service = service ?: return
        viewModelScope.launch {
            val callId = service.startGroupCall(groupId, isVideo) ?: return@launch
            holdProcessOpen(service, groupId, callId, isVideo)
        }
    }

    fun joinGroupCall() {
        val service = service ?: return
        val call = groupCall.value ?: return
        viewModelScope.launch {
            service.groupCalls.join()
            holdProcessOpen(service, call.groupId, call.callId, call.isVideo)
        }
    }

    /** Declines a ring, or leaves a call already joined — the same button either way. */
    fun leaveGroupCall() {
        val service = service ?: return
        val call = groupCall.value ?: return
        viewModelScope.launch {
            if (call.isRinging) service.groupCalls.decline() else service.groupCalls.leave()
        }
    }

    fun toggleGroupMute() {
        val service = service ?: return
        service.groupCalls.setMuted(!(groupCall.value?.isMuted ?: false))
    }

    fun toggleGroupCamera() {
        val service = service ?: return
        service.groupCalls.setCameraEnabled(!(groupCall.value?.isCameraOn ?: true))
    }

    fun switchGroupCamera() = service?.groupCalls?.switchCamera()

    /** The name to show on a call, which is the conversation title if we have one. */
    fun callerName(call: ActiveCall): String =
        service?.displayName(call.peerAccount) ?: call.peerAccount.take(8)

    // -------------------------------------------------------------- settings

    private val _privateCallMode = MutableStateFlow(true)
    val privateCallMode: StateFlow<Boolean> = _privateCallMode.asStateFlow()

    private val _pushIncludesContent = MutableStateFlow(false)
    val pushIncludesContent: StateFlow<Boolean> = _pushIncludesContent.asStateFlow()

    private val _devices = MutableStateFlow<List<LinkedDevice>>(emptyList())
    val devices: StateFlow<List<LinkedDevice>> = _devices.asStateFlow()

    /** Reads the live values. Called when the settings tab is opened. */
    fun refreshSettings() {
        val service = service ?: return
        _privateCallMode.value = service.privateCallMode
        _pushIncludesContent.value = service.pushIncludesContent
        viewModelScope.launch {
            _devices.value = runCatching { service.linkedDevices() }.getOrDefault(emptyList())
        }
    }

    fun setPrivateCallMode(enabled: Boolean) {
        val service = service ?: return
        service.privateCallMode = enabled
        _privateCallMode.value = enabled
    }

    fun setPushIncludesContent(enabled: Boolean) {
        val service = service ?: return
        // Shown optimistically, then corrected: the switch must not end up
        // claiming a setting the relay rejected.
        _pushIncludesContent.value = enabled
        viewModelScope.launch {
            runCatching { service.setPushIncludesContent(enabled) }
                .onFailure { _pushIncludesContent.value = service.pushIncludesContent }
        }
    }

    private val _inviteLink = MutableStateFlow<String?>(null)

    /** The last invite created this session, so "share again" does not mint another. */
    val inviteLink: StateFlow<String?> = _inviteLink.asStateFlow()

    /**
     * Creates a one-time invite link and opens the share sheet.
     *
     * Reuses the one already minted this session: each call to the relay burns a
     * fresh single-use token, and leaving a trail of unused ones behind is
     * pointless.
     */
    fun shareInvite(context: android.content.Context) {
        val service = service ?: return
        viewModelScope.launch {
            val link = _inviteLink.value
                ?: runCatching { service.createInviteLink() }.getOrNull()
                ?: return@launch
            _inviteLink.value = link
            val send = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(android.content.Intent.EXTRA_TEXT, "Message me on Relay: $link")
            }
            runCatching {
                context.startActivity(android.content.Intent.createChooser(send, "Invite to Relay"))
            }
        }
    }

    fun signOut() {
        val service = service ?: return
        service.signOut()
        pendingUsername = null
        _inviteLink.value = null
        _authStep.value = AuthStep.WELCOME
        _phase.value = AppPhase.SignedOut
    }

    fun titleFor(conversation: Conversation): String =
        service?.conversationTitle(conversation) ?: conversation.peerAccount.take(8)

    /**
     * Starts the service, publishes it process-wide so the push handler reuses
     * it, and registers this device's FCM token.
     */
    private fun RelayService.startUp() {
        start()
        RelayRuntime.attach(getApplication(), this)
        viewModelScope.launch { registerCurrentPushToken(this@startUp) }
    }

    /**
     * Fetches the FCM token and hands it to the relay.
     *
     * Quietly does nothing when Firebase has no configuration — the app is
     * fully usable without push, it just won't wake in the background.
     */
    private suspend fun registerCurrentPushToken(service: RelayService) {
        runCatching {
            val token = com.google.firebase.messaging.FirebaseMessaging.getInstance().token.await()
            // Log a prefix only: the token is a device-addressable identifier, and
            // a full one sitting in a shared log is worth avoiding.
            android.util.Log.i("RelayPush", "FCM token acquired (" + token.take(12) + "...)")
            service.registerPushToken(token)
                .onSuccess { android.util.Log.i("RelayPush", "token registered with relay") }
                .onFailure {
                    // Do NOT claim success here. The relay rejects this endpoint
                    // entirely until it is redeployed with the FCM sender, and a
                    // log that says "registered" either way hides that completely.
                    android.util.Log.w("RelayPush", "relay rejected the token: " + it.message)
                }
        }.onFailure { android.util.Log.w("RelayPush", "could not obtain an FCM token: " + it.message) }
    }

    private fun Throwable.friendlyMessage(): String = when (this) {
        is app.relaymsg.net.SupabaseAuthException -> reason.ifEmpty { "Couldn't sign in." }
        is app.relaymsg.net.RelayApiException -> when (status) {
            409 -> "That username is taken."
            404 -> "No such user."
            // The oauth account endpoint 503s when the relay was started without
            // -supabase-url / -supabase-anon-key. That is server configuration,
            // not anything the user can fix by retrying.
            503 -> if (_authStep.value != AuthStep.WELCOME) {
                "Email sign-in isn't enabled on this server."
            } else {
                "The server has contact discovery disabled."
            }
            else -> serverMessage.ifEmpty { "Server error ($status)." }
        }
        else -> message ?: "Something went wrong."
    }
}
