package app.relaymsg.core

import android.content.Context
import app.relaymsg.net.RelayApiClient
import app.relaymsg.net.RelayAuthenticator
import app.relaymsg.net.RelayCredentials
import app.relaymsg.net.RelayEvent
import app.relaymsg.net.RelayWebSocket
import app.relaymsg.net.RequestSigner
import app.relaymsg.net.SendOutcome
import app.relaymsg.storage.Conversation
import app.relaymsg.storage.DeviceAuthKey
import app.relaymsg.storage.MasterKeyStore
import app.relaymsg.storage.MessageStatus
import app.relaymsg.storage.SecureStore
import app.relaymsg.storage.StoredMessage
import java.security.SecureRandom
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Where the client is in its connection lifecycle, for the UI to reflect. */
enum class ConnectionState { DISCONNECTED, CONNECTING, CONNECTED }

/**
 * The app's composition root and orchestrator — roughly iOS's `AppModel` plus
 * the lifecycle half of `MessagingService`.
 *
 * Owns the account, the encrypted store, the socket and the receive loop, and
 * exposes state the UI observes. Everything here is deliberately plain
 * coroutines and flows; the Compose layer holds no protocol knowledge.
 */
class RelayService private constructor(
    private val context: Context,
    val credentials: RelayCredentials,
    val username: String,
    private val store: SecureStore,
    private val api: RelayApiClient,
    private val socket: RelayWebSocket,
    private val messenger: RelayMessenger,
    private val pipeline: EnvelopePipeline,
) {
    companion object {
        const val DEFAULT_SERVER = "https://api.relaymsg.app"

        /** The relay's sealed-sender trust root, baked in (PROTOCOL.md §1.6). */
        private const val TRUST_ROOT_BASE64 = "BUMHKPU9XPCdwHCVF8Eea8RxKLhbxq6BhpvYgBTo4IFU"

        private const val KV_ACCOUNT_ID = "account.id"
        private const val KV_DEVICE_ID = "account.device"
        private const val KV_PASSWORD = "account.password"
        private const val KV_USERNAME = "account.username"

        /**
         * Opens the store and restores a signed-in account, or returns null when
         * this install has none yet.
         *
         * Credentials live in the SQLCipher kv table rather than plain
         * preferences: the device password is a bearer secret, and the database
         * is already unlocked by a Keystore-wrapped key at this point.
         */
        suspend fun restore(context: Context, server: String = DEFAULT_SERVER): RelayService? =
            withContext(Dispatchers.IO) {
                val store = SecureStore.open(context)
                val kv = store.messages
                val accountId = kv.kvGet(KV_ACCOUNT_ID)?.decodeToString() ?: return@withContext null
                val deviceId = kv.kvGet(KV_DEVICE_ID)?.decodeToString()?.toIntOrNull()
                    ?: return@withContext null
                val password = kv.kvGet(KV_PASSWORD)?.decodeToString() ?: return@withContext null
                val username = kv.kvGet(KV_USERNAME)?.decodeToString().orEmpty()
                build(context, store, RelayCredentials(accountId, deviceId, password), username, server)
            }

        /** Registers a new account and brings it fully online. */
        suspend fun register(
            context: Context,
            username: String,
            server: String = DEFAULT_SERVER,
        ): RelayService = withContext(Dispatchers.IO) {
            val store = SecureStore.open(context)
            val password = UUID.randomUUID().toString()
            val (credentials, _, _) = RelayApiClient(server, auth = null)
                .register(username = username, password = password)

            store.messages.apply {
                kvPut(KV_ACCOUNT_ID, credentials.accountId.toByteArray())
                kvPut(KV_DEVICE_ID, credentials.deviceId.toString().toByteArray())
                kvPut(KV_PASSWORD, credentials.password.toByteArray())
                kvPut(KV_USERNAME, username.toByteArray())
            }

            val service = build(context, store, credentials, username, server)
            val accessKey = ByteArray(32).also { SecureRandom().nextBytes(it) }
            service.messenger.bootstrap(service.authKey.publicKey(), accessKey)
            service
        }

        private fun build(
            context: Context,
            store: SecureStore,
            credentials: RelayCredentials,
            username: String,
            server: String,
        ): RelayService {
            val authKey = DeviceAuthKey()
            val signer = object : RequestSigner {
                override fun sign(message: ByteArray) = authKey.sign(message)
                override fun publicKey() = authKey.publicKey()
            }
            val auth = RelayAuthenticator(credentials, signer)
            val api = RelayApiClient(server, auth)
            val engine = store.makeCryptoEngine(credentials.accountId, credentials.deviceId)
            val messenger = RelayMessenger(
                api = api,
                engine = engine,
                store = store,
                credentials = credentials,
                sealedSenderTrustRoot = android.util.Base64.decode(
                    TRUST_ROOT_BASE64, android.util.Base64.DEFAULT,
                ),
            )
            return RelayService(
                context = context,
                credentials = credentials,
                username = username,
                store = store,
                api = api,
                socket = RelayWebSocket(server, auth),
                messenger = messenger,
                pipeline = EnvelopePipeline(messenger, store.messages, credentials.accountId),
            )
        }
    }

    private val authKey = DeviceAuthKey()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _conversations = MutableStateFlow<List<Conversation>>(emptyList())
    val conversations: StateFlow<List<Conversation>> = _conversations.asStateFlow()

    private val _connection = MutableStateFlow(ConnectionState.DISCONNECTED)
    val connection: StateFlow<ConnectionState> = _connection.asStateFlow()

    private val _activeMessages = MutableStateFlow<List<StoredMessage>>(emptyList())
    val activeMessages: StateFlow<List<StoredMessage>> = _activeMessages.asStateFlow()

    private var activeConversationId: String? = null

    /** Connects and keeps reconnecting until [stop]. */
    fun start() {
        refreshConversations()
        scope.launch { runConnectionLoop() }
        scope.launch {
            // Keep the one-time prekey pool topped up; a depleted pool silently
            // degrades every new session to signed + Kyber only.
            runCatching { messenger.refreshKeys() }
        }
    }

    fun stop() {
        socket.disconnect()
        _connection.value = ConnectionState.DISCONNECTED
    }

    private suspend fun runConnectionLoop() {
        var backoffMs = 1_000L
        while (true) {
            _connection.value = ConnectionState.CONNECTING
            try {
                socket.connect().collect { event ->
                    when (event) {
                        is RelayEvent.QueueDrained -> {
                            _connection.value = ConnectionState.CONNECTED
                            backoffMs = 1_000L
                            refreshConversations()
                        }
                        is RelayEvent.Envelope -> handleEnvelope(event)
                        is RelayEvent.Disconnected ->
                            _connection.value = ConnectionState.DISCONNECTED
                        else -> Unit
                    }
                }
            } catch (_: Throwable) {
                _connection.value = ConnectionState.DISCONNECTED
            }
            delay(backoffMs)
            backoffMs = (backoffMs * 2).coerceAtMost(30_000L)
        }
    }

    private suspend fun handleEnvelope(event: RelayEvent.Envelope) {
        val envelope = event.envelope
        try {
            val outcome = pipeline.apply(envelope)
            outcome.deliveryReceiptFor?.let { timestamp ->
                outcome.peerAccount?.let { peer -> sendDeliveryReceipt(peer, timestamp) }
            }
            if (outcome.conversationId != null) {
                refreshConversations()
                if (outcome.conversationId == activeConversationId) {
                    refreshActiveMessages()
                }
            }
        } catch (_: Throwable) {
            // Poison-message protection: an envelope that cannot be decrypted is
            // acked and dropped rather than redelivered forever. The ack below
            // happens regardless of what went wrong here.
        } finally {
            runCatching { socket.ack(envelope.id) }
                .onFailure { runCatching { api.ackMessage(envelope.id) } }
        }
    }

    // ------------------------------------------------------------------ sending

    /** Resolves a username to an account id and opens (or finds) the conversation. */
    suspend fun startConversation(username: String): String = withContext(Dispatchers.IO) {
        // Blinded discovery is the private path, but the relay 503s when it is not
        // configured; fall back so the app still works on such a deployment.
        val accountId = runCatching { resolveViaDirectory(username) }
            .getOrElse { api.lookupAccountId(username) }
        store.messages.conversation(accountId, username)
    }

    private suspend fun resolveViaDirectory(username: String): String {
        throw UnsupportedOperationException("blinded discovery wired in a later stage")
    }

    suspend fun sendText(conversationId: String, body: String) = withContext(Dispatchers.IO) {
        val peer = store.messages.peerAccount(conversationId) ?: return@withContext
        val timestamp = System.currentTimeMillis()
        val localId = UUID.randomUUID().toString()

        // Show it immediately as "sending"; the wire send follows.
        store.messages.insertMessage(
            id = localId,
            conversationId = conversationId,
            isOutgoing = true,
            body = body,
            timestamp = timestamp,
            status = MessageStatus.SENDING,
        )
        refreshActiveMessages()
        refreshConversations()

        val content = messenger.buildTextContent(body, timestamp)
        val status = try {
            val outcome = messenger.sendOverWebSocket(
                socket = socket,
                account = peer,
                plaintext = content.toByteArray(),
                clientTimestamp = timestamp,
            )
            if (outcome is SendOutcome.Ok) MessageStatus.SENT else MessageStatus.FAILED
        } catch (_: Throwable) {
            MessageStatus.FAILED
        }
        store.messages.updateStatus(localId, status)
        refreshActiveMessages()
        refreshConversations()
    }

    private suspend fun sendDeliveryReceipt(peer: String, timestamp: Long) {
        runCatching {
            val content = relay.content.content {
                receipt = relay.content.receiptMessage {
                    type = relay.content.ContentOuterClass.ReceiptMessage.Type.TYPE_DELIVERY
                    messageTimestamps.add(timestamp)
                }
                senderAccountId = credentials.accountId
                senderDeviceId = credentials.deviceId
            }
            // Receipts are ephemeral: delivered only to connected devices, never
            // queued, and never padded.
            messenger.sendOverWebSocket(
                socket = socket,
                account = peer,
                plaintext = content.toByteArray(),
                clientTimestamp = System.currentTimeMillis(),
                ephemeral = true,
            )
        }
    }

    // -------------------------------------------------------------------- push

    /**
     * Registers this device's FCM token so the relay can wake it.
     *
     * The default remains a **content-free** wake: the relay sends no message
     * data and this client fetches the envelope itself. That is the whole point
     * of the design — Google's push infrastructure never carries message
     * content, even encrypted.
     */
    suspend fun registerPushToken(token: String) = withContext(Dispatchers.IO) {
        runCatching {
            api.setFcmToken(token)
            api.setPushIncludeContent(false)
        }
    }

    /**
     * Drains the offline queue over REST and applies everything in it.
     *
     * Used by the push path, and as a fallback when the WebSocket cannot
     * connect. Returns what was stored so a caller can raise a notification.
     * Safe to run concurrently with the socket: envelopes are claimed exactly
     * once, so whichever path arrives second simply finds nothing to do.
     */
    suspend fun drainQueue(): List<EnvelopePipeline.Outcome> = withContext(Dispatchers.IO) {
        val applied = mutableListOf<EnvelopePipeline.Outcome>()
        val envelopes = runCatching { api.fetchQueue() }.getOrDefault(emptyList())
        for (envelope in envelopes) {
            try {
                val outcome = pipeline.apply(envelope)
                if (!outcome.isDuplicate) applied += outcome
                outcome.deliveryReceiptFor?.let { timestamp ->
                    outcome.peerAccount?.let { peer -> sendDeliveryReceipt(peer, timestamp) }
                }
            } catch (_: Throwable) {
                // Undecryptable: ack and drop, same as the socket path.
            } finally {
                runCatching { api.ackMessage(envelope.id) }
            }
        }
        if (applied.isNotEmpty()) refreshConversations()
        applied
    }

    /** Applies a single envelope delivered inside a push payload (opt-in mode). */
    suspend fun applyPushedEnvelope(serialized: ByteArray): EnvelopePipeline.Outcome? =
        withContext(Dispatchers.IO) {
            val envelope = app.relaymsg.net.IncomingEnvelope.parse(serialized) ?: return@withContext null
            try {
                pipeline.apply(envelope).also { if (!it.isDuplicate) refreshConversations() }
            } catch (_: Throwable) {
                null
            } finally {
                runCatching { api.ackMessage(envelope.id) }
            }
        }

    /** A display name for a peer account, falling back to a short id. */
    fun displayName(account: String): String =
        conversations.value.firstOrNull { it.peerAccount == account }?.peerUsername
            ?: account.take(8)

    // ------------------------------------------------------------------- reads

    fun openConversation(conversationId: String) {
        activeConversationId = conversationId
        refreshActiveMessages()
        store.messages.markConversationRead(conversationId)
        refreshConversations()
    }

    fun closeConversation() {
        activeConversationId = null
        _activeMessages.value = emptyList()
    }

    fun refreshConversations() {
        _conversations.value = runCatching { store.messages.conversations() }.getOrDefault(emptyList())
    }

    private fun refreshActiveMessages() {
        val id = activeConversationId ?: return
        _activeMessages.value = runCatching { store.messages.messages(id) }.getOrDefault(emptyList())
    }

    fun conversationTitle(conversation: Conversation): String =
        conversation.peerUsername ?: conversation.peerAccount.take(8)

    /** Wipes every local secret. Irreversible. */
    fun signOut() {
        stop()
        store.wipe()
        authKey.delete()
    }
}
