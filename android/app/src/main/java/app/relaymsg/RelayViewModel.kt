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
import app.relaymsg.core.RelayService
import app.relaymsg.push.RelayRuntime
import app.relaymsg.storage.Conversation
import app.relaymsg.storage.StoredCall
import app.relaymsg.storage.StoredMessage
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
}

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
    fun sendImage(conversationId: String, uri: android.net.Uri) {
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

    fun send(conversationId: String, body: String) {
        val service = service ?: return
        viewModelScope.launch { service.sendText(conversationId, body) }
    }

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
        is app.relaymsg.net.RelayApiException -> when (status) {
            409 -> "That username is taken."
            404 -> "No such user."
            // The relay 503s the directory endpoints when it is started without
            // an OPRF key, which is a server configuration problem, not a typo.
            503 -> "The server has contact discovery disabled."
            else -> serverMessage.ifEmpty { "Server error ($status)." }
        }
        else -> message ?: "Something went wrong."
    }
}
