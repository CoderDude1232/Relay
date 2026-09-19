package app.relaymsg.core

import android.content.Context
import app.relaymsg.crypto.AttachmentCipher
import app.relaymsg.crypto.BlindedDiscovery
import app.relaymsg.crypto.ProvisioningCipher
import app.relaymsg.net.RelayApiClient
import app.relaymsg.net.RelayApiException
import app.relaymsg.net.RelayAuthenticator
import app.relaymsg.net.RelayCredentials
import app.relaymsg.net.LinkedDevice
import app.relaymsg.net.RelayEvent
import app.relaymsg.net.RelayWebSocket
import app.relaymsg.net.SignedPayloads
import app.relaymsg.net.RequestSigner
import app.relaymsg.net.OAuthAccountResult
import app.relaymsg.net.SendOutcome
import app.relaymsg.net.SupabaseAuth
import app.relaymsg.net.SupabaseSession
import app.relaymsg.net.TurnCredentials
import app.relaymsg.storage.Conversation
import app.relaymsg.storage.DeviceAuthKey
import app.relaymsg.storage.MasterKeyStore
import app.relaymsg.storage.MessageStatus
import app.relaymsg.storage.QuotedMessage
import app.relaymsg.storage.SecureStore
import app.relaymsg.storage.StoredAttachment
import app.relaymsg.storage.StoredCall
import app.relaymsg.storage.StoredCallDirection
import app.relaymsg.storage.StoredCallKind
import app.relaymsg.storage.StoredCallOutcome
import app.relaymsg.storage.StoredMessage
import java.security.SecureRandom
import org.json.JSONArray
import org.json.JSONObject
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

/** How an email sign-in or sign-up ended. */
sealed interface EmailAuthResult {
    data class Ready(val service: RelayService) : EmailAuthResult

    /**
     * Supabase knows this user, but the relay has no account yet.
     *
     * Carries the session so picking a username retries only the relay call —
     * asking Supabase again would fail, since the email is now registered there.
     */
    class UsernameRequired internal constructor(
        internal val session: SupabaseSession,
        internal val accountPassword: String?,
    ) : EmailAuthResult
}

/** The linking window closed before the primary provisioned this device. */
class LinkingExpiredException : Exception("the linking code expired")

/** Linking failed in a way retrying will not fix. */
class LinkingFailedException(message: String) : Exception(message)

/**
 * A linking session in progress on the device being linked.
 *
 * [qr] is what to render; [ephemeral] holds the private half and must not
 * outlive the attempt, which is why it is not persisted anywhere.
 */
class LinkingSession internal constructor(
    val qr: String,
    val sessionId: String,
    val expiresAt: Long,
    internal val ephemeral: ProvisioningCipher.EphemeralKeyPair,
    internal val server: String,
)

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
    /** The relay this account lives on; needed when provisioning another device. */
    val server: String,
    private val store: SecureStore,
    private val api: RelayApiClient,
    private val socket: RelayWebSocket,
    private val messenger: RelayMessenger,
    private val pipeline: EnvelopePipeline,
    /** Held for safety numbers; everything else goes through [messenger]. */
    private val engine: app.relaymsg.crypto.CryptoEngine,
) {
    companion object {
        const val DEFAULT_SERVER = "https://api.relaymsg.app"

        /** Often enough that an open conversation clears within half a minute. */
        private const val EXPIRY_SWEEP_MS = 30_000L

        /** The relay's sealed-sender trust root, baked in (PROTOCOL.md §1.6). */
        private const val TRUST_ROOT_BASE64 = "BUMHKPU9XPCdwHCVF8Eea8RxKLhbxq6BhpvYgBTo4IFU"

        private const val KV_ACCOUNT_ID = "account.id"
        private const val KV_DEVICE_ID = "account.device"
        private const val KV_PASSWORD = "account.password"
        private const val KV_USERNAME = "account.username"
        private const val KV_PRIVATE_CALLS = "calls.private"
        private const val KV_PUSH_CONTENT = "push.includeContent"

        /** iOS's key, so the list means the same thing on both clients. */
        private const val KV_BLOCKED = "relay.blockedAccounts"

        // iOS's own key names, so a shared backup reads the same on both.
        private const val KV_MY_NAME = "me:name"
        private const val KV_MY_AVATAR = "me:avatar"
        private const val KV_MY_REVISION = "me:rev"
        private const val KV_MY_AVATAR_POINTER = "me:aptr"
        private const val KV_MY_AVATAR_POINTER_REV = "me:aptrrev"
        private const val KV_PROFILE_SENT = "pfsent:"
        private const val KV_SCREEN_LOCK = "lock.enabled"
        private const val KV_SCREEN_LOCK_AFTER = "lock.afterSeconds"
        private const val KV_WALLPAPER = "chat.wallpaper."
        private const val KV_BUBBLE = "chat.bubbleTint."

        /** iOS's key prefix, so a linked device reads the same queue. */
        private const val KV_SCHEDULED = "sched:"

        /** iOS's marker. A message body starting with this is the notepad. */
        const val NOTEPAD_PREFIX = "__relay_notepad__"
        private const val KV_SUPABASE_REFRESH = "supabase.refresh"
        private const val KV_SUPABASE_USER = "supabase.user"

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

        /**
         * Starts linking this device to an existing account.
         *
         * Step one of the reversed flow: this device mints a rendezvous session
         * and an ephemeral key pair, and shows both in a QR for the primary to
         * scan. The private half stays in memory here and is used once.
         */
        suspend fun beginLinking(server: String = DEFAULT_SERVER): LinkingSession =
            withContext(Dispatchers.IO) {
                val ephemeral = ProvisioningCipher.EphemeralKeyPair.generate()
                val session = RelayApiClient(server, auth = null).createProvisioningSession()
                LinkingSession(
                    qr = DeviceLinking.LinkQrPayload(
                        sessionId = session.sessionId,
                        ephemeralPublicKey = ephemeral.publicKey,
                        serverUrl = server,
                    ).encode(),
                    sessionId = session.sessionId,
                    expiresAt = session.expiresAt,
                    ephemeral = ephemeral,
                    server = server,
                )
            }

        /**
         * Waits for the primary to provision this device, then brings it online.
         *
         * Polls until the blob appears or the session expires. The relay deletes
         * the session on the first successful fetch, so everything after that
         * point has to succeed or the user must start again — hence the identity
         * key and credentials are written before anything touches the network.
         */
        suspend fun completeLinking(
            context: Context,
            session: LinkingSession,
            pollInterval: Long = 2_000L,
        ): RelayService = withContext(Dispatchers.IO) {
            val api = RelayApiClient(session.server, auth = null)
            var blob: ByteArray? = null
            while (blob == null) {
                if (System.currentTimeMillis() > session.expiresAt) {
                    throw LinkingExpiredException()
                }
                blob = runCatching { api.fetchProvisioningBlob(session.sessionId) }.getOrNull()
                if (blob == null) delay(pollInterval)
            }

            val plaintext = ProvisioningCipher.open(blob, session.ephemeral)
            val payload = DeviceLinking.LinkProvisioningPayload.decode(plaintext)
                ?: throw LinkingFailedException("the provisioning payload was unreadable")

            val store = SecureStore.open(context)
            // The account's shared identity, not a fresh one. Written before the
            // stores are used, because the first read would otherwise generate a
            // new identity and this device would be a stranger to every peer.
            store.keys.storeIdentityKeyPair(payload.identityKeyPair)

            val credentials = RelayCredentials(payload.accountId, payload.deviceId, payload.password)
            store.messages.apply {
                kvPut(KV_ACCOUNT_ID, credentials.accountId.toByteArray())
                kvPut(KV_DEVICE_ID, credentials.deviceId.toString().toByteArray())
                kvPut(KV_PASSWORD, credentials.password.toByteArray())
                kvPut(KV_USERNAME, payload.username.orEmpty().toByteArray())
            }
            // Contacts the primary passed along, so the linked device is not blank.
            payload.peers.forEach { peer ->
                runCatching { store.messages.conversation(peer.account, peer.username) }
            }

            val service = build(
                context, store, credentials, payload.username.orEmpty(), payload.serverUrl,
            )
            service.messenger.bootstrapLinkedDevice(service.authKey.publicKey())
            service
        }

        /**
         * Creates an account from an email sign-up.
         *
         * Two hops: Supabase issues a session for the email and password, then
         * the relay verifies that token server-to-server and mints the account.
         * The password is also handed to the relay as the **account** password so
         * recovery works later; the *device* password is separate and random.
         */
        suspend fun signUpWithEmail(
            context: Context,
            email: String,
            password: String,
            username: String?,
            server: String = DEFAULT_SERVER,
        ): EmailAuthResult = withContext(Dispatchers.IO) {
            val session = SupabaseAuth().signUp(email.trim(), password)
            completeEmailAuth(context, session, username, password, server)
        }

        /**
         * Signs in to an existing account.
         *
         * A returning user is recovered by the relay from their verified Supabase
         * token, so no username is needed — but note what this does **not**
         * restore: the E2EE identity key. A device signed in this way generates a
         * fresh one, and everyone who has messaged this account will see a
         * safety-number change. Device linking (§7.9) is the path that preserves
         * identity.
         */
        suspend fun signInWithEmail(
            context: Context,
            email: String,
            password: String,
            username: String? = null,
            server: String = DEFAULT_SERVER,
        ): EmailAuthResult = withContext(Dispatchers.IO) {
            val session = SupabaseAuth().signIn(email.trim(), password)
            completeEmailAuth(context, session, username, accountPassword = null, server = server)
        }

        /**
         * Finishes a sign-in that came from an OAuth provider.
         *
         * Identical to the email path once a Supabase session exists — the relay
         * only ever sees the token, and does not care how it was obtained.
         */
        suspend fun signInWithOAuth(
            context: Context,
            session: SupabaseSession,
            username: String? = null,
            server: String = DEFAULT_SERVER,
        ): EmailAuthResult = withContext(Dispatchers.IO) {
            completeEmailAuth(context, session, username, accountPassword = null, server = server)
        }

        /** Retries the relay half with a username the user has now chosen. */
        suspend fun completeWithUsername(
            context: Context,
            pending: EmailAuthResult.UsernameRequired,
            username: String,
            server: String = DEFAULT_SERVER,
        ): EmailAuthResult = withContext(Dispatchers.IO) {
            completeEmailAuth(
                context, pending.session, username.trim(), pending.accountPassword, server,
            )
        }

        private suspend fun completeEmailAuth(
            context: Context,
            session: SupabaseSession,
            username: String?,
            accountPassword: String?,
            server: String,
        ): EmailAuthResult {
            val devicePassword = UUID.randomUUID().toString()
            val result = RelayApiClient(server, auth = null).registerWithOAuth(
                accessToken = session.accessToken,
                devicePassword = devicePassword,
                username = username,
                accountPassword = accountPassword,
            )
            if (result !is OAuthAccountResult.SignedIn) {
                return EmailAuthResult.UsernameRequired(session, accountPassword)
            }

            val store = SecureStore.open(context)
            store.messages.apply {
                kvPut(KV_ACCOUNT_ID, result.credentials.accountId.toByteArray())
                kvPut(KV_DEVICE_ID, result.credentials.deviceId.toString().toByteArray())
                kvPut(KV_PASSWORD, result.credentials.password.toByteArray())
                kvPut(KV_USERNAME, result.username.toByteArray())
                // Kept so a later 401 can be refreshed without asking for the
                // password again. It lives in the SQLCipher store, not prefs.
                kvPut(KV_SUPABASE_REFRESH, session.refreshToken.toByteArray())
                kvPut(KV_SUPABASE_USER, session.userId.toByteArray())
            }

            val service = build(context, store, result.credentials, result.username, server)
            if (result.created) {
                val accessKey = ByteArray(32).also { SecureRandom().nextBytes(it) }
                service.messenger.bootstrap(service.authKey.publicKey(), accessKey)
            } else {
                // Joining an account that already exists: publishing keys is
                // right, rotating its access key is not — that would revoke every
                // sender who already holds it.
                service.messenger.bootstrapLinkedDevice(service.authKey.publicKey())
            }
            return EmailAuthResult.Ready(service)
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
                server = server,
                store = store,
                api = api,
                socket = RelayWebSocket(server, auth),
                messenger = messenger,
                pipeline = EnvelopePipeline(messenger, store.messages, credentials.accountId),
                engine = engine,

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
    private val started = java.util.concurrent.atomic.AtomicBoolean(false)

    /**
     * Supplies the media transport for calls.
     *
     * WebRTC is a large native dependency and lives in the app module, so the app
     * installs the real factory at start-up; until then calls signal correctly
     * (and interoperate with iOS) but carry no media. See PROTOCOL.md §7.6.
     */
    @Volatile
    var callTransportFactory: () -> CallTransport = { NoMediaTransport() }

    /**
     * The call state machine. Signals reach it from both receive paths — the
     * socket while the app is running, and the queue drain a push wake triggers.
     */
    val calls = CallManager(
        ownAccount = credentials.accountId,
        ownDevice = credentials.deviceId,
        newTransport = { callTransportFactory() },
        send = ::sendCallSignal,
        scope = scope,
        onEnded = ::recordCall,
    )

    /**
     * Writes a finished call to the log.
     *
     * The outcome is inferred the way iOS does (`inferredTerminalOutcome`): what
     * distinguishes a completed call from a failed one is whether media ever
     * connected, not whether the signalling went cleanly.
     */
    private fun recordCall(call: ActiveCall, reason: CallEndReason) {
        val outcome = when (reason) {
            CallEndReason.MISSED -> StoredCallOutcome.MISSED
            CallEndReason.DECLINED -> StoredCallOutcome.DECLINED
            CallEndReason.HUNG_UP ->
                if (call.connectedAt != null) StoredCallOutcome.COMPLETED else StoredCallOutcome.FAILED
            CallEndReason.BUSY, CallEndReason.FAILED -> StoredCallOutcome.FAILED
        }
        runCatching {
            store.messages.upsertCall(
                StoredCall(
                    id = call.callId,
                    peerAccount = call.peerAccount,
                    peerName = displayName(call.peerAccount),
                    direction = if (call.isOutgoing) {
                        StoredCallDirection.OUTGOING
                    } else {
                        StoredCallDirection.INCOMING
                    },
                    kind = if (call.isVideo) StoredCallKind.VIDEO else StoredCallKind.AUDIO,
                    startedAt = call.startedAt,
                    connectedAt = call.connectedAt,
                    endedAt = System.currentTimeMillis(),
                    outcome = outcome,
                ),
            )
        }
        refreshCallLog()
    }

    private val _callLog = MutableStateFlow<List<StoredCall>>(emptyList())

    /** The call history, newest first. */
    val callLog: StateFlow<List<StoredCall>> = _callLog.asStateFlow()

    fun refreshCallLog() {
        scope.launch { _callLog.value = runCatching { store.messages.calls() }.getOrDefault(emptyList()) }
    }

    fun clearCallLog() {
        scope.launch {
            runCatching { store.messages.clearCalls() }
            refreshCallLog()
        }
    }

    /**
     * TURN-only calling, on by default exactly as on iOS.
     *
     * With it on, no candidate carrying this device's address is ever offered, so
     * the peer learns nothing about where the call is coming from. It costs
     * latency and relay bandwidth, which is why it is a setting at all.
     */
    var privateCallMode: Boolean
        get() = store.messages.kvGet(KV_PRIVATE_CALLS)?.decodeToString() != "0"
        set(value) = store.messages.kvPut(KV_PRIVATE_CALLS, (if (value) "1" else "0").toByteArray())

    // -------------------------------------------------------------- profile

    private val _myProfile = MutableStateFlow(MyProfile("", null))

    /** This account's own display name and avatar, as peers will see them. */
    val myProfile: StateFlow<MyProfile> = _myProfile.asStateFlow()

    /** A profile others see. Kept per account, newest revision wins. */
    data class MyProfile(val displayName: String, val avatar: ByteArray?) {
        override fun equals(other: Any?): Boolean = this === other || (
            other is MyProfile && displayName == other.displayName &&
                avatar.contentEquals(other.avatar)
            )

        override fun hashCode(): Int = displayName.hashCode() * 31 + (avatar?.contentHashCode() ?: 0)
    }

    private fun loadMyProfile() {
        _myProfile.value = MyProfile(
            displayName = store.messages.kvGet(KV_MY_NAME)?.decodeToString().orEmpty(),
            avatar = store.messages.kvGet(KV_MY_AVATAR),
        )
    }

    /**
     * Changes this account's profile and pushes it to everyone who knows us.
     *
     * The revision is bumped to now, which both orders it against whatever a
     * peer already has and re-arms sending: `pfsent:<peer>` is compared against
     * it, so every peer is re-sent exactly once per change.
     */
    suspend fun updateProfile(
        displayName: String,
        avatar: ByteArray?,
    ) = withContext(Dispatchers.IO) {
        store.messages.kvPut(KV_MY_NAME, displayName.toByteArray())
        if (avatar == null) {
            store.messages.kvDelete(KV_MY_AVATAR)
        } else {
            store.messages.kvPut(KV_MY_AVATAR, avatar)
        }
        // The cached upload belongs to the old revision; a new avatar must not
        // be advertised with the previous pointer.
        store.messages.kvDelete(KV_MY_AVATAR_POINTER)
        store.messages.kvPut(KV_MY_REVISION, System.currentTimeMillis().toString().toByteArray())
        loadMyProfile()
        distributeProfile()
    }

    private val myRevision: Long
        get() = store.messages.kvGet(KV_MY_REVISION)?.decodeToString()?.toLongOrNull() ?: 0L

    /**
     * Pushes the profile to every peer we know: direct contacts and every
     * member of every group we are in, minus ourselves.
     */
    private suspend fun distributeProfile() {
        val conversations = store.messages.conversations(includeArchived = true)
        val direct = conversations.filter { it.groupId == null }.map { it.peerAccount }
        val members = conversations.mapNotNull { it.groupId }
            .mapNotNull { store.messages.group(it) }
            .flatMap { it.members }
        (direct + members).toSet()
            .filter { it.isNotEmpty() && it != credentials.accountId }
            .forEach { peer -> runCatching { sendProfileTo(peer) } }
    }

    /**
     * Sends the profile to one peer if they do not already have this revision.
     *
     * Called when a conversation opens as well as on change, so a contact added
     * later still learns the name without waiting for the next edit.
     */
    suspend fun sendProfileIfNeeded(peer: String) = withContext(Dispatchers.IO) {
        val revision = myRevision
        if (revision == 0L) return@withContext
        val sent = store.messages.kvGet(KV_PROFILE_SENT + peer)
            ?.decodeToString()?.toLongOrNull() ?: 0L
        if (sent >= revision) return@withContext
        runCatching { sendProfileTo(peer) }
    }

    private suspend fun sendProfileTo(peer: String) {
        val revision = myRevision
        if (revision == 0L) return
        val content = messenger.buildProfile(
            displayName = _myProfile.value.displayName,
            avatar = myAvatarPointer(),
            revision = revision,
        )
        val outcome = messenger.sendOverWebSocket(
            socket = socket,
            account = peer,
            plaintext = content.toByteArray(),
            clientTimestamp = revision,
        )
        if (outcome is SendOutcome.Ok) {
            store.messages.kvPut(KV_PROFILE_SENT + peer, revision.toString().toByteArray())
        }
    }

    /**
     * Uploads the avatar once per revision and reuses the pointer.
     *
     * Without the cache a ten-person group would upload the same picture ten
     * times, and each copy would be a separate blob on the relay.
     */
    private suspend fun myAvatarPointer(): relay.content.ContentOuterClass.AttachmentPointer? {
        val avatar = _myProfile.value.avatar ?: return null
        val revision = myRevision
        val cachedRevision = store.messages.kvGet(KV_MY_AVATAR_POINTER_REV)
            ?.decodeToString()?.toLongOrNull()
        if (cachedRevision == revision) {
            store.messages.kvGet(KV_MY_AVATAR_POINTER)?.let { raw ->
                return runCatching {
                    relay.content.ContentOuterClass.AttachmentPointer.parseFrom(raw)
                }.getOrNull()
            }
        }

        val sealed = AttachmentCipher.seal(avatar)
        val id = runCatching { api.uploadAttachment(sealed.ciphertext) }.getOrNull() ?: return null
        blobs.write(id, sealed.ciphertext)
        val pointer = relay.content.attachmentPointer {
            this.id = id
            key = com.google.protobuf.ByteString.copyFrom(sealed.key)
            digest = com.google.protobuf.ByteString.copyFrom(sealed.digest)
            contentType = "image/jpeg"
            size = sealed.ciphertext.size.toLong()
        }
        store.messages.kvPut(KV_MY_AVATAR_POINTER, pointer.toByteArray())
        store.messages.kvPut(KV_MY_AVATAR_POINTER_REV, revision.toString().toByteArray())
        return pointer
    }

    /** Fetches a peer's avatar after their profile arrived carrying a pointer. */
    private suspend fun fetchPeerAvatar(
        account: String,
        pointer: relay.content.ContentOuterClass.AttachmentPointer,
    ) {
        val ciphertext = blobs.read(pointer.id)
            ?: runCatching { api.downloadAttachment(pointer.id) }.getOrNull()
                ?.also { blobs.write(pointer.id, it) }
            ?: return
        val bytes = runCatching {
            AttachmentCipher.open(
                ciphertext,
                pointer.key.toByteArray(),
                pointer.digest.toByteArray(),
            )
        }.getOrNull() ?: return

        val existing = store.messages.peerProfile(account)
        store.messages.upsertProfile(
            account = account,
            displayName = existing?.displayName,
            avatarId = pointer.id,
            avatarData = bytes,
            // Same revision the name arrived with, or upsertProfile's
            // newest-wins guard would reject the picture it belongs to.
            revision = existing?.revision ?: 0L,
        )
        refreshConversations()
    }

    // ------------------------------------------------------------ block list

    private val _blocked = MutableStateFlow<Set<String>>(emptySet())

    init {
        // The pipeline decrypts before it can know who sent it, so the check has
        // to live there while the list belongs here. Wired at construction, not
        // in start(): a push wake drains the queue without ever calling start().
        // Declared after _blocked so the order is obvious rather than merely
        // lucky.
        pipeline.isBlocked = ::isBlocked
        // Loaded here too, and for the same reason: a wake that drains the queue
        // without start() would otherwise run with an empty block list and
        // deliver exactly the messages the user asked not to see.
        loadBlocked()
        loadMyProfile()
    }

    /** Accounts whose messages are dropped on arrival. */
    val blockedAccounts: StateFlow<Set<String>> = _blocked.asStateFlow()

    fun isBlocked(account: String): Boolean = account in _blocked.value

    fun blockAccount(account: String) = setBlocked(_blocked.value + account)

    fun unblockAccount(account: String) = setBlocked(_blocked.value - account)

    private fun setBlocked(accounts: Set<String>) {
        _blocked.value = accounts
        // Same kv key and JSON shape iOS uses, so a shared backup would read on
        // either client.
        val array = JSONArray().apply { accounts.sorted().forEach(::put) }
        runCatching { store.messages.kvPut(KV_BLOCKED, array.toString().toByteArray()) }
        refreshConversations()
    }

    private fun loadBlocked() {
        val raw = runCatching { store.messages.kvGet(KV_BLOCKED) }.getOrNull() ?: return
        val parsed = runCatching {
            val array = JSONArray(raw.decodeToString())
            (0 until array.length()).map { array.getString(it) }.toSet()
        }.getOrNull() ?: return
        _blocked.value = parsed
    }

    /**
     * Removes another device from this account.
     *
     * Refuses to remove the device it is running on: that would leave this
     * phone holding keys it can no longer authenticate with, which looks like
     * a broken app rather than a deliberate act. Signing out is that.
     */
    suspend fun removeDevice(deviceId: Int): Boolean = withContext(Dispatchers.IO) {
        if (deviceId == credentials.deviceId) return@withContext false
        runCatching {
            val (_, version) = api.listDevices()
            api.removeDevice(
                deviceId = deviceId,
                expectedVersion = version,
                signerDeviceId = credentials.deviceId,
                signature = authKey.sign(
                    SignedPayloads.deviceMutation(
                        accountId = credentials.accountId,
                        expectedVersion = version,
                        action = "remove",
                        targetDeviceId = deviceId,
                        // Empty for a removal; only add and link carry one.
                        password = "",
                    ),
                ),
            )
        }.isSuccess
    }

    /**
     * Every device on this account, newest id last.
     *
     */
    suspend fun linkedDevices(): List<LinkedDevice> = withContext(Dispatchers.IO) {
        api.listDevices().first.sortedBy { it.deviceId }
    }

    /**
     * Whether the relay may put the encrypted envelope inside the push.
     *
     * Off by default, which is the contentless wake: the push says only that
     * *something* arrived and this device fetches and decrypts it. Turning it on
     * is faster and costs a little metadata — Google carries the ciphertext,
     * and its size, rather than an empty tap on the shoulder.
     */
    val pushIncludesContent: Boolean
        get() = store.messages.kvGet(KV_PUSH_CONTENT)?.decodeToString() == "1"

    suspend fun setPushIncludesContent(include: Boolean) = withContext(Dispatchers.IO) {
        api.setPushIncludeContent(include)
        // Only recorded once the relay has accepted it, so the switch cannot
        // claim a setting the server does not actually have.
        store.messages.kvPut(KV_PUSH_CONTENT, (if (include) "1" else "0").toByteArray())
    }

    /**
     * A one-time invite link.
     *
     * Single-use and expiring, unlike the permanent `/add/<username>` link:
     * handing one out does not publish who you are to anyone who later finds
     * the message it was sent in.
     */
    suspend fun createInviteLink(): String = withContext(Dispatchers.IO) {
        val (token, _) = api.createContactInvite()
        "https://relaymsg.app/c/$token"
    }

    /**
     * Redeems a one-time invite, returning the username behind it.
     *
     * Single-use on the relay, so a link that has already been claimed fails
     * here rather than silently opening a conversation with nobody.
     */
    suspend fun claimInvite(token: String): String = withContext(Dispatchers.IO) {
        val (accountId, username) = api.claimContactInvite(token)
        store.messages.conversation(accountId, username)
        refreshConversations()
        username
    }

    /** The permanent link to this account. Safe to print on a card. */
    val publicLink: String get() = "https://relaymsg.app/add/$username"

    /** Credentials and the wall-clock ms at which they stop being usable. */
    private var cachedTurn: Pair<TurnCredentials, Long>? = null

    /**
     * The ICE configuration for a new peer connection.
     *
     * Credentials are cached for their TTL less a minute, so a call started right
     * on the boundary does not begin with an expired TURN password. A failed
     * fetch is not fatal: the call proceeds without TURN rather than not at all.
     */
    suspend fun icePlan(): IcePlan = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        val cached = cachedTurn?.takeIf { it.second > now }?.first
        val credentials = cached ?: runCatching { api.turnCredentials() }
            .getOrNull()
            ?.also { fresh ->
                val ttlMs = (maxOf(fresh.ttl, 60L) - 60L) * 1000L
                cachedTurn = fresh to (now + ttlMs)
            }
        IceServerPolicy.plan(credentials, privateCallMode)
    }

    /**
     * Supplies one transport per mesh leg of a group call.
     *
     * Separate from [callTransportFactory] because the legs must share capture:
     * a camera can only be opened once per process.
     */
    @Volatile
    var groupCallTransportFactory: (peer: String) -> CallTransport = { NoMediaTransport() }

    /** Group calls: a full mesh, and a different lifecycle from 1:1 (see [GroupCallManager]). */
    val groupCalls = GroupCallManager(
        ownAccount = credentials.accountId,
        ownDevice = credentials.deviceId,
        newTransport = { peer -> groupCallTransportFactory(peer) },
        send = ::sendCallSignal,
        nameOf = ::displayName,
        groupNameOf = { groupId -> store.messages.group(groupId)?.name ?: "Group call" },
    )

    /**
     * Provisions another device from a scanned QR. **Primary side** of linking.
     *
     * Creates the device on this account, then seals this account's identity key
     * and the new device's credentials to the ephemeral key in the QR and leaves
     * the ciphertext on the relay. The relay cannot read it.
     *
     * The order matters: the device row is created first, because the payload has
     * to carry its id — and a device created but never provisioned is harmless
     * (it can never authenticate), whereas a payload for a device that does not
     * exist is not.
     */
    suspend fun linkOtherDevice(qrText: String): Int = withContext(Dispatchers.IO) {
        val qr = DeviceLinking.LinkQrPayload.decode(qrText)
            ?: throw LinkingFailedException("That isn't a Relay linking code.")
        // A code pointing at another relay would send this account's identity key
        // somewhere it does not belong. Cheap check, serious consequence.
        if (qr.serverUrl.trimEnd('/') != server.trimEnd('/')) {
            throw LinkingFailedException("That code is for a different Relay server.")
        }

        val (_, deviceListVersion) = api.listDevices()
        val devicePassword = UUID.randomUUID().toString()
        // Signed over the CANONICAL payload, not a digest: the key signs with
        // SHA256withECDSA and hashes for us. The password is part of what is
        // signed, so it cannot be swapped in flight.
        val signature = authKey.sign(
            SignedPayloads.deviceMutation(
                accountId = credentials.accountId,
                expectedVersion = deviceListVersion,
                action = "link",
                targetDeviceId = 0,
                password = devicePassword,
            ),
        )
        val newDeviceId = api.linkDevice(
            password = devicePassword,
            expectedVersion = deviceListVersion,
            signerDeviceId = credentials.deviceId,
            signature = signature,
        )

        val payload = DeviceLinking.LinkProvisioningPayload(
            // The shared account identity — the whole point of linking rather
            // than signing in, which would mint a new one and change every
            // safety number.
            identityKeyPair = store.signalStore.identityKeyPair.serialize(),
            accountId = credentials.accountId,
            username = username.ifEmpty { null },
            deviceId = newDeviceId,
            password = devicePassword,
            serverUrl = server,
            // Contacts, so the new device is not a blank slate. Groups are left
            // out: their state rebuilds from GroupUpdate, and a group's "peer" is
            // its group id, which is not a contact.
            peers = store.messages.conversations()
                .filter { it.groupId == null }
                .map { DeviceLinking.PeerStub(it.peerAccount, it.peerUsername) },
            historyId = null,
            historyKey = null,
            historyDigest = null,
        )

        api.storeProvisioningBlob(
            sessionId = qr.sessionId,
            blob = ProvisioningCipher.seal(payload.encode().toByteArray(), qr.ephemeralPublicKey),
        )
        newDeviceId
    }

    /** Starts a group call with everyone in [groupId] except this account. */
    suspend fun startGroupCall(groupId: String, isVideo: Boolean): String? =
        withContext(Dispatchers.IO) {
            val group = store.messages.group(groupId) ?: return@withContext null
            groupCalls.start(groupId, group.name, group.members, isVideo)
        }

    /**
     * Call signalling rides the same encrypted envelope as a message; only the
     * queueing differs, and [CallSignalling.isEphemeral] decides that.
     */
    /**
     * Sends a call signal to the state machine that owns it.
     *
     * A group mesh carries plain OFFER / ANSWER / ICE between members, so the
     * type alone cannot decide this — only `group_id` separates a mesh leg from
     * a 1:1 call. Same rule as iOS's `handleCallMessage`.
     */
    private suspend fun routeCallSignal(signal: CallSignal) {
        if (CallSignalling.isGroupSignal(signal)) groupCalls.onSignal(signal) else calls.onSignal(signal)
    }

    private suspend fun sendCallSignal(
        peer: String,
        content: relay.content.ContentOuterClass.Content,
        ephemeral: Boolean,
    ) {
        messenger.sendOverWebSocket(
            socket = socket,
            account = peer,
            plaintext = content.toByteArray(),
            clientTimestamp = System.currentTimeMillis(),
            ephemeral = ephemeral,
        )
    }

    /**
     * Deletes messages whose disappearing timer has elapsed.
     *
     * Runs on a timer rather than only at startup: a conversation left open for
     * an hour would otherwise keep showing messages that expired forty minutes
     * ago, which is precisely the guarantee the feature makes.
     */
    private suspend fun sweepExpired() {
        while (true) {
            runCatching { flushScheduled() }
            val removed = runCatching { store.messages.deleteExpiredMessages() }.getOrDefault(0)
            if (removed > 0) {
                refreshActiveMessages()
                refreshConversations()
            }
            delay(EXPIRY_SWEEP_MS)
        }
    }

    // ---------------------------------------------------------- panic mode

    /**
     * Hidden conversations, behind a second PIN.
     *
     * Separate from the screen lock: that keeps a stranger out of the app,
     * this keeps a particular thread out of the list while someone you handed
     * the phone to is scrolling.
     */
    val panic = PanicMode(
        object : KeyValueStore {
            override fun get(key: String) = store.messages.kvGet(key)
            override fun put(key: String, value: ByteArray) = store.messages.kvPut(key, value)
            override fun delete(key: String) = store.messages.kvDelete(key)
        },
    )

    fun setConversationHidden(conversationId: String, hidden: Boolean) {
        panic.setHidden(conversationId, hidden)
        refreshConversations()
    }

    // ------------------------------------------------------------ app lock

    /**
     * Whether to require the device unlock before showing the app.
     *
     * Not a second secret: the database key is already wrapped by a Keystore
     * key. This only decides whether to show the UI to whoever is holding an
     * already-unlocked phone.
     */
    var screenLockEnabled: Boolean
        get() = store.messages.kvGet(KV_SCREEN_LOCK)?.decodeToString() == "1"
        set(value) = store.messages.kvPut(KV_SCREEN_LOCK, (if (value) "1" else "0").toByteArray())

    /** Seconds in the background before the lock re-arms. 0 means immediately. */
    var screenLockTimeoutSeconds: Long
        get() = store.messages.kvGet(KV_SCREEN_LOCK_AFTER)?.decodeToString()?.toLongOrNull() ?: 0L
        set(value) = store.messages.kvPut(KV_SCREEN_LOCK_AFTER, value.toString().toByteArray())

    // -------------------------------------------------------- verification

    /**
     * The 60 digits for a peer, or null when no session exists yet.
     *
     * Derived from the two identity keys and the two account ids, so both sides
     * compute the same number without either sending anything — which is the
     * whole point: a relay that wanted to lie would have to produce a matching
     * number for a key it does not hold.
     */
    fun safetyNumber(account: String) = engine.safetyNumber(account)

    fun verificationState(account: String) = store.signalStore.verificationState(account)

    /** A peer's avatar bytes, for a notification or a row. Null if they have none. */
    fun peerAvatar(account: String): ByteArray? =
        runCatching { store.messages.peerProfile(account)?.avatarData }.getOrNull()

    fun setVerified(account: String, verified: Boolean) {
        store.signalStore.setVerified(verified, account)
        refreshConversations()
    }

    /**
     * Checks a scanned code against the local number.
     *
     * The code carries the peer's own fingerprint encoding, so a match proves
     * the two devices agree about both identity keys. A mismatch means someone
     * is between them, and is worth saying loudly.
     */
    fun verifyScanned(account: String, scannedBase64: String): Boolean {
        val bytes = runCatching {
            java.util.Base64.getDecoder().decode(scannedBase64.trim())
        }.getOrNull() ?: return false
        return runCatching { engine.verifyScannedSafetyNumber(bytes, account) }.getOrDefault(false)
    }

    // --------------------------------------------------------- conversations

    fun setConversationPinned(conversationId: String, pinned: Boolean) {
        store.messages.setConversationPinned(conversationId, pinned)
        refreshConversations()
    }

    fun setConversationArchived(conversationId: String, archived: Boolean) {
        store.messages.setConversationArchived(conversationId, archived)
        refreshConversations()
    }

    fun markConversationUnread(conversationId: String) {
        store.messages.markConversationUnread(conversationId)
        refreshConversations()
    }

    /** Deletes a conversation and everything in it, on this device only. */
    fun deleteConversation(conversationId: String) {
        if (activeConversationId == conversationId) closeConversation()
        store.messages.deleteConversation(conversationId)
        refreshConversations()
    }

    /**
     * Sets how long messages live in a conversation, and tells the peer.
     *
     * The timer belongs to the conversation rather than the message, so both
     * sides have to agree — sending the change is what keeps them in step, and
     * the receiver applies it before storing whatever it arrived with.
     */
    suspend fun setDisappearing(
        conversationId: String,
        seconds: Long,
    ) = withContext(Dispatchers.IO) {
        store.messages.setDisappearingSeconds(conversationId, seconds)
        refreshConversations()
        val timestamp = System.currentTimeMillis()
        sendMessageAction(conversationId, timestamp) { groupId ->
            messenger.buildDisappearing(seconds, timestamp, groupId)
        }
    }

    /**
     * Per-conversation appearance. Local only — nothing is sent, so two people
     * in one conversation can and will see different colours.
     */
    fun appearance(conversationId: String): Pair<String?, String?> {
        val wallpaper = store.messages.kvGet(KV_WALLPAPER + conversationId)?.decodeToString()
        val bubble = store.messages.kvGet(KV_BUBBLE + conversationId)?.decodeToString()
        return wallpaper to bubble
    }

    fun setAppearance(conversationId: String, wallpaperId: String?, bubbleKey: String?) {
        if (wallpaperId == null) {
            store.messages.kvDelete(KV_WALLPAPER + conversationId)
        } else {
            store.messages.kvPut(KV_WALLPAPER + conversationId, wallpaperId.toByteArray())
        }
        if (bubbleKey == null) {
            store.messages.kvDelete(KV_BUBBLE + conversationId)
        } else {
            store.messages.kvPut(KV_BUBBLE + conversationId, bubbleKey.toByteArray())
        }
    }

    /** Every attachment in a conversation, newest first, for the gallery. */
    fun conversationAttachments(conversationId: String): List<StoredAttachment> =
        store.messages.messages(conversationId, limit = 2_000)
            .flatMap { it.attachments }
            .reversed()

    /** Sends a recorded voice note. */
    suspend fun sendVoiceNote(
        conversationId: String,
        bytes: ByteArray,
    ) = withContext(Dispatchers.IO) {
        sendAttachments(
            conversationId = conversationId,
            body = "",
            attachments = listOf(
                OutgoingAttachment(
                    bytes = bytes,
                    // The type iOS records, so its player picks it up without
                    // guessing from the extension.
                    contentType = "audio/m4a",
                    filename = "voice-note.m4a",
                ),
            ),
        )
    }

    // -------------------------------------------------- scheduled messages

    /** A message waiting for its moment. [scheduledAt] is seconds, as on iOS. */
    data class ScheduledMessage(
        val id: String,
        val conversationId: String,
        val body: String,
        val scheduledAt: Double,
    )

    /**
     * Queues a message to send later.
     *
     * Stored in kv under `sched:<id>` with iOS's own JSON field names, so a
     * linked device reads the same queue rather than its own.
     *
     * The send still needs this device awake and connected: nothing wakes the
     * app to deliver one, so a message scheduled for 3am goes out when the app
     * next runs. iOS has the same limit.
     */
    fun scheduleMessage(conversationId: String, body: String, atSeconds: Double) {
        val id = UUID.randomUUID().toString()
        val json = JSONObject()
            .put("id", id)
            .put("conversationId", conversationId)
            .put("body", body)
            .put("scheduledAt", atSeconds)
        store.messages.kvPut(KV_SCHEDULED + id, json.toString().toByteArray())
        refreshScheduled()
    }

    private val _scheduled = MutableStateFlow<List<ScheduledMessage>>(emptyList())
    val scheduled: StateFlow<List<ScheduledMessage>> = _scheduled.asStateFlow()

    fun refreshScheduled() {
        _scheduled.value = runCatching {
            store.messages.kvPrefix(KV_SCHEDULED).mapNotNull { (_, value) ->
                val json = JSONObject(value.decodeToString())
                ScheduledMessage(
                    id = json.getString("id"),
                    conversationId = json.getString("conversationId"),
                    body = json.getString("body"),
                    scheduledAt = json.getDouble("scheduledAt"),
                )
            }.sortedBy { it.scheduledAt }
        }.getOrDefault(emptyList())
    }

    fun cancelScheduled(id: String) {
        store.messages.kvDelete(KV_SCHEDULED + id)
        refreshScheduled()
    }

    /** Sends anything now due. Removed before sending, so a failure cannot loop. */
    private suspend fun flushScheduled() {
        val now = System.currentTimeMillis() / 1000.0
        _scheduled.value.filter { it.scheduledAt <= now }.forEach { message ->
            cancelScheduled(message.id)
            runCatching { sendText(message.conversationId, message.body) }
        }
    }

    // ---------------------------------------------------------- the notepad

    /**
     * A shared scratchpad per conversation.
     *
     * Not a separate channel: it is an ordinary encrypted message whose body
     * carries a marker, so the relay cannot tell one from a chat message and
     * the newest one simply wins. Marker matches iOS exactly.
     */
    fun notepadContent(conversationId: String): String =
        store.messages.messages(conversationId, limit = 500)
            .lastOrNull { it.body.startsWith(NOTEPAD_PREFIX) }
            ?.body
            ?.removePrefix(NOTEPAD_PREFIX)
            .orEmpty()

    suspend fun saveNotepad(
        conversationId: String,
        content: String,
    ) = sendText(conversationId, NOTEPAD_PREFIX + content)

    fun searchMessages(query: String) = store.messages.searchMessages(query)

    fun starredMessages(conversationId: String) = store.messages.starredMessages(conversationId)

    fun pinnedMessage(conversationId: String) = store.messages.pinnedMessage(conversationId)

    /**
     * Connects and keeps reconnecting until [stop].
     *
     * Idempotent: the UI starts it when the app opens, and a background call
     * wake starts it again because signalling after the OFFER (ANSWER, ICE) is
     * ephemeral and only reaches a connected socket. A second connection loop
     * would advance the Double Ratchet concurrently with the first.
     */
    fun start() {
        if (!started.compareAndSet(false, true)) return
        refreshConversations()
        refreshCallLog()
        refreshScheduled()
        scope.launch { runConnectionLoop() }
        scope.launch { sweepExpired() }
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
            // Before the store refreshes: a ringing phone is latency-sensitive.
            outcome.callSignal?.let { routeCallSignal(it) }
            outcome.profileAvatar?.let { pointer ->
                outcome.peerAccount?.let { fetchPeerAvatar(it, pointer) }
            }
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

    /** One address-book entry that turned out to be on Relay. */
    data class DiscoveredContact(
        val identifier: String,
        val accountId: String,
        val username: String,
    )

    /**
     * Looks up a batch of identifiers through the blinded directory.
     *
     * Batched in one round trip rather than one call per contact, which is both
     * far faster over an address book and better for privacy: the relay sees a
     * set of blinded elements at once and cannot time individual lookups.
     *
     * It never learns the addresses themselves — each is blinded here, the
     * relay evaluates its OPRF over the blinded element, and only the resulting
     * token is presented for matching.
     */
    suspend fun discoverContacts(
        identifiers: List<String>,
    ): List<DiscoveredContact> = withContext(Dispatchers.IO) {
        val cleaned = identifiers.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        if (cleaned.isEmpty()) return@withContext emptyList()

        val blinded = cleaned.mapNotNull { id ->
            runCatching { id to discovery.blind(id) }.getOrNull()
        }
        if (blinded.isEmpty()) return@withContext emptyList()

        val evaluated = runCatching { api.directoryEvaluate(blinded.map { it.second.element }) }
            .getOrElse { return@withContext emptyList() }
        if (evaluated.size != blinded.size) return@withContext emptyList()

        // Tokens are kept alongside their identifier so a match can be reported
        // back against the address-book entry it came from.
        val tokens = blinded.mapIndexed { index, (identifier, blind) ->
            identifier to discovery.token(blind, evaluated[index])
        }
        val matches = runCatching { api.directoryResolve(tokens.map { it.second }) }
            .getOrElse { return@withContext emptyList() }

        matches.mapNotNull { match ->
            val identifier = tokens
                .firstOrNull { it.second.contentEquals(match.token) }
                ?.first
                ?: return@mapNotNull null
            DiscoveredContact(identifier, match.accountId, match.username)
        }
    }

    suspend fun sendText(
        conversationId: String,
        body: String,
        quote: QuotedMessage? = null,
    ) = withContext(Dispatchers.IO) {
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
            replyTo = quote,
        )
        refreshActiveMessages()
        refreshConversations()

        val content = messenger.buildTextContent(body, timestamp, quote = quote)
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

    /**
     * Sends something that modifies an existing message — a reaction, an edit,
     * an unsend.
     *
     * Routed exactly as a message is: over the group's sender key when the
     * conversation is a group, pairwise otherwise, and mirrored to our own
     * devices in the pairwise case so the change shows up everywhere we are
     * signed in. All three are **non-ephemeral**: a reaction that only reached
     * the devices that happened to be online would be worse than none.
     */
    private suspend fun sendMessageAction(
        conversationId: String,
        timestamp: Long,
        build: (groupId: String?) -> relay.content.ContentOuterClass.Content,
    ): Boolean {
        val peer = store.messages.peerAccount(conversationId) ?: return false
        val group = store.messages.group(peer)

        return if (group != null) {
            val content = build(group.id)
            runCatching {
                messenger.sendGroupMessage(
                    socket = socket,
                    groupId = group.id,
                    distributionId = group.distributionId,
                    members = group.members,
                    plaintext = content.toByteArray(),
                    clientTimestamp = timestamp,
                )
            }.getOrNull() is SendOutcome.Ok
        } else {
            val content = build(null)
            val ok = runCatching {
                messenger.sendOverWebSocket(socket, peer, content.toByteArray(), timestamp)
            }.getOrNull() is SendOutcome.Ok
            if (ok) {
                runCatching { messenger.sendSyncToOwnDevices(socket, content, peer, timestamp) }
            }
            ok
        }
    }

    /**
     * Adds or removes our reaction to a message.
     *
     * Reacting again with the same emoji takes it back, which is what every
     * messenger does and what the protocol's `remove` flag is for. The local
     * store is updated first so the tap feels instant; the send follows.
     */
    suspend fun toggleReaction(
        conversationId: String,
        targetTimestamp: Long,
        targetAuthor: String,
        emoji: String,
    ) = withContext(Dispatchers.IO) {
        val existing = store.messages.messages(conversationId, limit = 200)
            .firstOrNull { it.timestamp == targetTimestamp }
            ?.reactions
            ?.firstOrNull { it.isOutgoing }
        val remove = existing?.emoji == emoji

        store.messages.setReaction(
            conversationId = conversationId,
            targetTimestamp = targetTimestamp,
            author = credentials.accountId,
            isOutgoing = true,
            emoji = emoji,
            remove = remove,
        )
        refreshActiveMessages()

        val now = System.currentTimeMillis()
        sendMessageAction(conversationId, now) { groupId ->
            messenger.buildReaction(targetAuthor, targetTimestamp, emoji, remove, now, groupId)
        }
    }

    /** Rewrites one of our own messages. Attachments are not editable. */
    suspend fun editMessage(
        conversationId: String,
        targetTimestamp: Long,
        newBody: String,
    ) = withContext(Dispatchers.IO) {
        store.messages.editMessage(conversationId, targetTimestamp, newBody)
        refreshActiveMessages(); refreshConversations()
        sendMessageAction(conversationId, System.currentTimeMillis()) { groupId ->
            messenger.buildEdit(targetTimestamp, newBody, groupId)
        }
    }

    /**
     * Unsends one of our own messages for everyone.
     *
     * Leaves a tombstone rather than erasing the row: a message that silently
     * vanishes from the middle of a conversation is more confusing than one
     * marked as withdrawn.
     */
    suspend fun unsendMessage(
        conversationId: String,
        targetTimestamp: Long,
    ) = withContext(Dispatchers.IO) {
        store.messages.markDeleted(conversationId, targetTimestamp)
        refreshActiveMessages(); refreshConversations()
        sendMessageAction(conversationId, System.currentTimeMillis()) { groupId ->
            messenger.buildDelete(targetTimestamp, groupId)
        }
    }

    /**
     * Creates a poll in a conversation.
     *
     * Stored locally as the same `__poll__:` message everyone else will store,
     * so the author's thread and the recipients' agree without a special case.
     */
    suspend fun sendPoll(
        conversationId: String,
        question: String,
        options: List<String>,
        multiSelect: Boolean,
    ) = withContext(Dispatchers.IO) {
        val timestamp = System.currentTimeMillis()
        store.messages.insertMessage(
            id = UUID.randomUUID().toString(),
            conversationId = conversationId,
            isOutgoing = true,
            body = PollPayload(question, options, multiSelect).encodeBody(),
            timestamp = timestamp,
            status = MessageStatus.SENDING,
            senderAccount = credentials.accountId,
        )
        refreshActiveMessages(); refreshConversations()
        sendMessageAction(conversationId, timestamp) { groupId ->
            messenger.buildPoll(question, options, multiSelect, timestamp, groupId)
        }
    }

    /** Casts or changes our vote. A later vote replaces the earlier one. */
    suspend fun sendPollVote(
        conversationId: String,
        pollAuthor: String,
        pollTimestamp: Long,
        selected: List<Int>,
    ) = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        store.messages.upsertPollVote(
            conversationId = conversationId,
            pollAuthor = pollAuthor,
            pollTimestamp = pollTimestamp,
            voterAccount = credentials.accountId,
            selectedOptions = selected,
            votedAt = now,
        )
        refreshActiveMessages()
        sendMessageAction(conversationId, now) { groupId ->
            messenger.buildPollVote(pollAuthor, pollTimestamp, selected, now, groupId)
        }
    }

    /** Every vote cast on one poll, for tallying. */
    fun pollVotes(conversationId: String, pollAuthor: String, pollTimestamp: Long) =
        store.messages.pollVotes(conversationId, pollAuthor, pollTimestamp)

    /** Stars or unstars a message. Local only; iOS keeps its own stars too. */
    fun setStarred(messageId: String, starred: Boolean) {
        store.messages.setMessageStarred(messageId, starred)
        refreshActiveMessages()
    }

    /** Pins a message to the top of its conversation, replacing any previous pin. */
    fun setPinned(conversationId: String, messageId: String, pinned: Boolean) {
        store.messages.setMessagePinned(conversationId, messageId, pinned)
        refreshActiveMessages()
    }

    /**
     * Removes a message from this device only.
     *
     * Nothing is sent: the other side keeps their copy, which is the honest
     * behaviour and the one the label promises.
     */
    fun deleteMessageLocally(messageId: String) {
        store.messages.deleteMessage(messageId)
        refreshActiveMessages(); refreshConversations()
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
                // The durable OFFER arrives this way after a call push wake.
                outcome.callSignal?.let { routeCallSignal(it) }
                outcome.profileAvatar?.let { pointer ->
                    outcome.peerAccount?.let { fetchPeerAvatar(it, pointer) }
                }
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
                pipeline.apply(envelope).also { outcome ->
                    outcome.callSignal?.let { routeCallSignal(it) }
                    if (!outcome.isDuplicate) refreshConversations()
                }
            } catch (_: Throwable) {
                null
            } finally {
                runCatching { api.ackMessage(envelope.id) }
            }
        }

    /** A display name for a peer account, falling back to a short id. */
    fun displayName(account: String): String =
        // Their own chosen name first: it is what they asked to be called, and
        // the username is only a handle.
        store.messages.peerProfile(account)?.displayName?.takeIf { it.isNotBlank() }
            ?: conversations.value.firstOrNull { it.peerAccount == account }?.peerUsername
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
     * Sends a file another app handed us, resolving its bytes and type.
     *
     * Reads the whole stream into memory, which is what the attachment cipher
     * needs anyway — it seals in one pass, and a share large enough to trouble
     * the heap would fail the relay's size limit first.
     */
    suspend fun sendSharedFile(
        context: Context,
        conversationId: String,
        uri: android.net.Uri,
    ) = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val bytes = resolver.openInputStream(uri)?.use { it.readBytes() } ?: return@withContext
        sendAttachments(
            conversationId = conversationId,
            body = "",
            attachments = listOf(
                OutgoingAttachment(
                    bytes = bytes,
                    contentType = resolver.getType(uri) ?: "application/octet-stream",
                    filename = uri.lastPathSegment,
                ),
            ),
        )
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

    /**
     * Applies a group change locally and announces it.
     *
     * The relay stores no group state, so `GroupUpdate` **is** the group: every
     * member's copy is built from the updates they have seen, and an update
     * that is stored but not sent leaves this device believing something none
     * of the others do. Both halves happen here, in that order, so a send
     * failure leaves a roster that is ahead rather than one that is behind.
     *
     * Announced to the roster *before* the change where someone is being
     * removed — they are told they are out, which they could not be told after.
     */
    private suspend fun mutateGroup(
        groupId: String,
        action: relay.content.ContentOuterClass.GroupUpdate.Action,
        name: String = "",
        target: String = "",
        transform: (app.relaymsg.storage.StoredGroup) -> app.relaymsg.storage.StoredGroup,
    ): Boolean = withContext(Dispatchers.IO) {
        val group = store.messages.group(groupId) ?: return@withContext false
        val updated = transform(group)
        val revision = group.revision + 1

        // Removing someone rotates the distribution id, which forces fresh
        // sender keys they cannot derive — otherwise they could still read the
        // group with the key they already hold.
        val rotate = action == relay.content.ContentOuterClass.GroupUpdate.Action.REMOVE
        val distributionId = if (rotate) UUID.randomUUID().toString() else updated.distributionId

        store.messages.upsertGroup(
            id = groupId,
            name = updated.name,
            distributionId = distributionId,
            revision = revision,
            members = updated.members,
            admins = updated.admins,
            isAnnounceOnly = updated.isAnnounceOnly,
        )

        val update = messenger.buildGroupUpdate(
            groupId = groupId,
            action = action,
            revision = revision,
            name = name,
            members = updated.members,
            admins = updated.admins,
            target = target,
            distributionId = distributionId,
            announceOnly = updated.isAnnounceOnly,
        )
        // The old roster, so a removed member learns they were removed.
        val audience = (group.members + updated.members).distinct()
        runCatching {
            messenger.sendToGroupMembers(
                socket, audience, update.toByteArray(), System.currentTimeMillis(),
            )
        }
        refreshConversations()
        true
    }

    suspend fun addGroupMember(groupId: String, username: String): Boolean {
        val account = runCatching { resolveAccount(username.trim()) }.getOrNull() ?: return false
        val group = store.messages.group(groupId) ?: return false
        if (account in group.members) return true
        return mutateGroup(
            groupId,
            relay.content.ContentOuterClass.GroupUpdate.Action.ADD,
            target = account,
        ) { it.copy(members = it.members + account) }
    }

    suspend fun removeGroupMember(groupId: String, account: String): Boolean = mutateGroup(
        groupId,
        relay.content.ContentOuterClass.GroupUpdate.Action.REMOVE,
        target = account,
    ) { group ->
        group.copy(
            members = group.members - account,
            // Removing an admin removes their admin rights with them.
            admins = group.admins - account,
        )
    }

    suspend fun renameGroup(groupId: String, name: String): Boolean = mutateGroup(
        groupId,
        relay.content.ContentOuterClass.GroupUpdate.Action.RENAME,
        name = name.trim(),
    ) { it.copy(name = name.trim()) }

    suspend fun setGroupAdmin(groupId: String, account: String, admin: Boolean): Boolean =
        mutateGroup(
            groupId,
            // Distinct actions rather than one "admins changed": the receiver
            // applies the whole list either way, but iOS reads the action to
            // phrase what it shows in the thread.
            if (admin) {
                relay.content.ContentOuterClass.GroupUpdate.Action.PROMOTE_ADMIN
            } else {
                relay.content.ContentOuterClass.GroupUpdate.Action.DEMOTE_ADMIN
            },
            target = account,
        ) { group ->
            group.copy(
                admins = if (admin) (group.admins + account).distinct() else group.admins - account,
            )
        }

    /** Only an admin may set this, and the relay cannot enforce it — the roster is ours. */
    suspend fun setGroupAnnounceOnly(groupId: String, announceOnly: Boolean): Boolean =
        mutateGroup(
            groupId,
            relay.content.ContentOuterClass.GroupUpdate.Action.SET_ANNOUNCE_ONLY,
        ) { it.copy(isAnnounceOnly = announceOnly) }

    /**
     * Leaves a group: announce first, then drop the local copy.
     *
     * LEAVE rather than REMOVE, because the two mean different things to the
     * people still in the group, and it does not rotate the distribution id —
     * nobody was ejected, so there is no key to keep away from anyone.
     */
    suspend fun leaveGroup(groupId: String): Boolean {
        val left = mutateGroup(
            groupId,
            relay.content.ContentOuterClass.GroupUpdate.Action.LEAVE,
            target = credentials.accountId,
        ) { group ->
            group.copy(
                members = group.members - credentials.accountId,
                admins = group.admins - credentials.accountId,
            )
        }
        if (left) {
            store.messages.groupConversationId(groupId)?.let { deleteConversation(it) }
        }
        return left
    }

    fun group(groupId: String) = store.messages.group(groupId)

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
        // Same moment iOS picks: a contact added after the last edit still gets
        // the name without waiting for the next one.
        scope.launch {
            store.messages.peerAccount(conversationId)
                ?.takeIf { store.messages.group(it) == null }
                ?.let { runCatching { sendProfileIfNeeded(it) } }
        }
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
        _conversations.value = runCatching { store.messages.conversations() }
            .getOrDefault(emptyList())
            // Filtered here rather than in the query, so every caller — the
            // list, the widget, the share sheet, the shortcuts — drops them
            // without each having to remember to.
            .filterNot { panic.shouldHide(it.id) }
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
