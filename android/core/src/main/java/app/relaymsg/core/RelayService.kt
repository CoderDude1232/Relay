package app.relaymsg.core

import android.content.Context
import app.relaymsg.crypto.AttachmentCipher
import app.relaymsg.crypto.BlindedDiscovery
import app.relaymsg.net.RelayApiClient
import app.relaymsg.net.RelayApiException
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
import app.relaymsg.storage.StoredAttachment
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
    private val blobs = AttachmentBlobStore(context)

    /**
     * ristretto255 for blinded discovery, via libsodium. Created lazily so a
     * device that never starts a conversation never loads the native library.
     */
    private val discovery by lazy {
        BlindedDiscovery(
            com.goterl.lazysodium.LazySodiumAndroid(com.goterl.lazysodium.SodiumAndroid()),
        )
    }
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
        val accountId = resolveAccount(username)
        store.messages.conversation(accountId, username)
    }

    /**
     * Resolves a username **without telling the relay which username we asked
     * for**: blind it, let the server evaluate the OPRF under its secret key,
     * unblind, and look the resulting token up (PROTOCOL.md §1.7).
     *
     * Falls back to the legacy plaintext endpoint only when the relay reports
     * discovery unconfigured (503). That fallback is a genuine privacy
     * downgrade — the username crosses the wire in the clear — so it is narrow
     * and deliberate rather than a catch-all: any other failure, including "no
     * such user", propagates.
     */
    suspend fun resolveUsername(username: String): String = withContext(Dispatchers.IO) {
        resolveAccount(username)
    }

    private suspend fun resolveAccount(username: String): String {
        val blinded = try {
            discovery.blind(username)
        } catch (e: Throwable) {
            throw IllegalStateException("could not blind the username", e)
        }
        val evaluated = try {
            api.directoryEvaluate(listOf(blinded.element)).firstOrNull()
                ?: throw RelayApiException(404, "no such user")
        } catch (e: RelayApiException) {
            if (e.status == 503) return api.lookupAccountId(username) else throw e
        }
        val token = discovery.token(blinded, evaluated)
        val match = api.directoryResolve(listOf(token)).firstOrNull()
            ?: throw RelayApiException(404, "no such user")
        return match.accountId
    }

    suspend fun sendText(conversationId: String, body: String) = withContext(Dispatchers.IO) {
        val peer = store.messages.peerAccount(conversationId) ?: return@withContext
        // A group conversation's "peer" IS the group id; route it accordingly.
        store.messages.group(peer)?.let {
            sendGroupText(conversationId, peer, body)
            return@withContext
        }
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

        // Mirror to our own linked devices so the thread stays consistent
        // everywhere. After the real send, and never allowed to fail it.
        if (status == MessageStatus.SENT) {
            messenger.sendSyncToOwnDevices(socket, content, peer, timestamp)
        }
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
    suspend fun registerPushToken(token: String): Result<Unit> = withContext(Dispatchers.IO) {
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

    // ------------------------------------------------------------ attachments

    /** An attachment chosen by the user, before encryption. */
    data class OutgoingAttachment(
        val bytes: ByteArray,
        val contentType: String,
        val filename: String? = null,
        val width: Int = 0,
        val height: Int = 0,
    )

    /**
     * Sends a message carrying attachments.
     *
     * Each blob gets a **fresh** AES-256-GCM key; the ciphertext goes to the
     * relay and the key plus a digest of that ciphertext travel end-to-end
     * inside the encrypted Content. The relay therefore stores bytes it can
     * never read and cannot link to a conversation.
     */
    suspend fun sendAttachments(
        conversationId: String,
        body: String,
        attachments: List<OutgoingAttachment>,
    ) = withContext(Dispatchers.IO) {
        val peer = store.messages.peerAccount(conversationId) ?: return@withContext
        val timestamp = System.currentTimeMillis()
        val localId = UUID.randomUUID().toString()

        val stored = mutableListOf<StoredAttachment>()
        val pointers = mutableListOf<relay.content.ContentOuterClass.AttachmentPointer>()
        for (item in attachments) {
            val sealed = AttachmentCipher.seal(item.bytes)
            val id = api.uploadAttachment(sealed.ciphertext)
            // Cache our own copy so the sender can view it without re-fetching.
            blobs.write(id, sealed.ciphertext)

            stored += StoredAttachment(
                id = id,
                key = sealed.key,
                digest = sealed.digest,
                contentType = item.contentType,
                size = sealed.ciphertext.size.toLong(),
                filename = item.filename,
                width = item.width,
                height = item.height,
                isDownloaded = true,
            )
            pointers += relay.content.attachmentPointer {
                this.id = id
                key = com.google.protobuf.ByteString.copyFrom(sealed.key)
                digest = com.google.protobuf.ByteString.copyFrom(sealed.digest)
                contentType = item.contentType
                // The pointer's size is the CIPHERTEXT length, not the plaintext.
                size = sealed.ciphertext.size.toLong()
                item.filename?.let { filename = it }
                width = item.width
                height = item.height
            }
        }

        store.messages.insertMessage(
            id = localId,
            conversationId = conversationId,
            isOutgoing = true,
            body = body,
            timestamp = timestamp,
            status = MessageStatus.SENDING,
            attachments = stored,
        )
        refreshActiveMessages(); refreshConversations()

        val content = relay.content.content {
            text = relay.content.textMessage {
                this.body = body
                this.timestamp = timestamp
                this.attachments.addAll(pointers)
            }
            senderAccountId = credentials.accountId
            senderDeviceId = credentials.deviceId
        }
        val status = try {
            val outcome = messenger.sendOverWebSocket(
                socket, peer, content.toByteArray(), timestamp,
            )
            if (outcome is SendOutcome.Ok) MessageStatus.SENT else MessageStatus.FAILED
        } catch (_: Throwable) {
            MessageStatus.FAILED
        }
        store.messages.updateStatus(localId, status)
        refreshActiveMessages(); refreshConversations()
    }

    /**
     * Returns an attachment's plaintext, downloading it if not cached.
     *
     * The digest is checked against the pointer **before** decryption is
     * attempted, so a tampered or corrupted blob fails closed rather than being
     * fed to the cipher.
     */
    suspend fun attachmentBytes(attachment: StoredAttachment): ByteArray? =
        withContext(Dispatchers.IO) {
            val ciphertext = blobs.read(attachment.id)
                ?: runCatching { api.downloadAttachment(attachment.id) }
                    .getOrNull()
                    ?.also { blobs.write(attachment.id, it) }
                ?: return@withContext null

            runCatching {
                AttachmentCipher.open(ciphertext, attachment.key, attachment.digest)
            }.onSuccess {
                store.messages.markAttachmentDownloaded(attachment.id)
            }.onFailure {
                // A digest mismatch means the cached copy is bad; drop it so a
                // retry re-fetches rather than failing forever on the same bytes.
                blobs.delete(attachment.id)
            }.getOrNull()
        }

    // ---------------------------------------------------------------- groups

    /**
     * Creates a group and announces it to its members.
     *
     * The group id and the sender-key epoch are both generated here: the relay
     * holds no group state whatsoever, so there is nothing to ask and nothing to
     * reserve. Members learn of the group only from the CREATE update.
     */
    suspend fun createGroup(name: String, memberUsernames: List<String>): String =
        withContext(Dispatchers.IO) {
            val members = memberUsernames.map { resolveAccount(it.trim()) }.toMutableList()
            if (credentials.accountId !in members) members += credentials.accountId

            val groupId = UUID.randomUUID().toString()
            val distributionId = UUID.randomUUID().toString()

            store.messages.upsertGroup(
                id = groupId,
                name = name,
                distributionId = distributionId,
                revision = 1,
                members = members,
                // The creator is the only admin until they promote someone.
                admins = listOf(credentials.accountId),
            )

            val update = messenger.buildGroupUpdate(
                groupId = groupId,
                action = relay.content.ContentOuterClass.GroupUpdate.Action.CREATE,
                revision = 1,
                name = name,
                members = members,
                admins = listOf(credentials.accountId),
                distributionId = distributionId,
            )
            messenger.sendToGroupMembers(
                socket, members, update.toByteArray(), System.currentTimeMillis(),
            )
            refreshConversations()
            store.messages.groupConversationId(groupId).orEmpty()
        }

    /** Sends a message to a group, encrypted once under our sender key. */
    private suspend fun sendGroupText(conversationId: String, groupId: String, body: String) {
        val group = store.messages.group(groupId) ?: return
        if (group.isAnnounceOnly && credentials.accountId !in group.admins) return

        val timestamp = System.currentTimeMillis()
        val localId = UUID.randomUUID().toString()
        store.messages.insertMessage(
            id = localId,
            conversationId = conversationId,
            isOutgoing = true,
            body = body,
            timestamp = timestamp,
            status = MessageStatus.SENDING,
            senderAccount = credentials.accountId,
        )
        refreshActiveMessages(); refreshConversations()

        val content = messenger.buildGroupTextContent(groupId, body, timestamp)
        val status = try {
            val outcome = messenger.sendGroupMessage(
                socket = socket,
                groupId = groupId,
                distributionId = group.distributionId,
                members = group.members,
                plaintext = content.toByteArray(),
                clientTimestamp = timestamp,
            )
            if (outcome is SendOutcome.Ok) MessageStatus.SENT else MessageStatus.FAILED
        } catch (_: Throwable) {
            MessageStatus.FAILED
        }
        store.messages.updateStatus(localId, status)
        refreshActiveMessages(); refreshConversations()
    }

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
        blobs.clear()
        authKey.delete()
    }
}
