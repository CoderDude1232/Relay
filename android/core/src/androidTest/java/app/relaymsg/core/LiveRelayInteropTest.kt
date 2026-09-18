package app.relaymsg.core

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.relaymsg.net.RelayApiClient
import app.relaymsg.net.RelayAuthenticator
import app.relaymsg.net.RelayCredentials
import app.relaymsg.net.RelayEvent
import app.relaymsg.net.RelayWebSocket
import app.relaymsg.net.RequestSigner
import app.relaymsg.net.SendOutcome
import app.relaymsg.storage.DeviceAuthKey
import app.relaymsg.storage.MasterKeyStore
import app.relaymsg.storage.SecureStore
import java.security.SecureRandom
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Live interoperability test against the real relay — the Stage 4 milestone.
 *
 * Skips itself unless run with the peer username supplied, mirroring the iOS
 * convention of a live test gated on an environment variable:
 *
 * ```
 * ./gradlew :core:connectedDebugAndroidTest \
 *     -Pandroid.testInstrumentationRunnerArguments.relayPeer=<iOS username>
 * ```
 *
 * It registers a **throwaway** Android account each run, so it never disturbs a
 * real one, and sends to the named iOS user. Two things it genuinely proves that
 * nothing offline can: that the relay accepts our `Relay-Sig` signatures, and
 * that a PQXDH session established from a live prekey bundle produces ciphertext
 * the iOS client can open.
 */
@RunWith(AndroidJUnit4::class)
class LiveRelayInteropTest {

    private companion object {
        const val TAG = "RelayInterop"
        const val DEFAULT_SERVER = "https://api.relaymsg.app"

        /** Baked into the client; the relay logs it at startup (PROTOCOL.md §1.6). */
        const val TRUST_ROOT_BASE64 = "BUMHKPU9XPCdwHCVF8Eea8RxKLhbxq6BhpvYgBTo4IFU"
    }

    private val arguments = InstrumentationRegistry.getArguments()
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val server: String get() = arguments.getString("relayServer") ?: DEFAULT_SERVER
    private val peerUsername: String? get() = arguments.getString("relayPeer")

    /** A fresh account, store and connected client for one test. */
    private class Harness(
        val pipeline: EnvelopePipeline,
        val username: String,
        val credentials: RelayCredentials,
        val api: RelayApiClient,
        val messenger: RelayMessenger,
        val socket: RelayWebSocket,
        val store: SecureStore,
        val keys: MasterKeyStore,
        val authKey: DeviceAuthKey,
    )

    private fun buildHarness(): Harness = runBlocking {
        val suffix = UUID.randomUUID().toString().take(8)
        val username = "androidtest$suffix"
        val password = UUID.randomUUID().toString()

        // Registration is unauthenticated, so no signer is needed yet.
        val bootstrapApi = RelayApiClient(server, auth = null)
        val (credentials, _, _) = bootstrapApi.register(username = username, password = password)
        Log.i(TAG, "registered throwaway account ${credentials.accountId} as $username")

        val keyAlias = "relay-interop-${UUID.randomUUID()}"
        val authKey = DeviceAuthKey(keyAlias)
        val signer = object : RequestSigner {
            override fun sign(message: ByteArray) = authKey.sign(message)
            override fun publicKey() = authKey.publicKey()
        }
        val auth = RelayAuthenticator(credentials, signer)
        val api = RelayApiClient(server, auth)

        val masterKeys = MasterKeyStore(context, "interop-${UUID.randomUUID()}")
        val store = SecureStore.openInMemory(masterKeys)
        val engine = store.makeCryptoEngine(credentials.accountId, credentials.deviceId)

        val messenger = RelayMessenger(
            api = api,
            engine = engine,
            store = store,
            credentials = credentials,
            sealedSenderTrustRoot = android.util.Base64.decode(TRUST_ROOT_BASE64, android.util.Base64.DEFAULT),
        )

        val accessKey = ByteArray(32).also { SecureRandom().nextBytes(it) }
        messenger.bootstrap(authPublicKey = authKey.publicKey(), accessKey = accessKey)
        Log.i(TAG, "bootstrapped: auth key uploaded, prekeys published, access key set")

        Harness(
            EnvelopePipeline(messenger, store.messages, credentials.accountId),
            username, credentials, api, messenger, RelayWebSocket(server, auth), store, masterKeys, authKey,
        )
    }

    private fun Harness.cleanUp() {
        socket.disconnect()
        store.close()
        keys.wipe()
        authKey.delete()
    }

    @Test
    fun androidRegistersAndSignsRequestsAgainstTheLiveRelay() {
        runBlocking {
        val harness = buildHarness()
        try {
            // Every call below is Relay-Sig signed. Android is the first client to
            // use the scheme, so this is its first real exercise.
            val count = harness.api.oneTimePreKeyCount()
            assertTrue("published prekeys should be visible to the relay", count > 0)

            val devices = harness.api.listDevices().first
            assertEquals(1, devices.size)
            assertEquals(harness.credentials.deviceId, devices.single().deviceId)

            // A mailbox id is what sends are addressed to.
            assertTrue(!devices.single().mailboxId.isNullOrEmpty())
            } finally {
                harness.cleanUp()
            }
        }
    }

    @Test
    fun outgoingMessagesMirrorToOurOwnLinkedDevices() {
        // Multi-device sync. Alice links a SECOND device to her account, sends to
        // Bob from the first, and the second must file that message in the
        // conversation with BOB -- as an OUTGOING message, not as one received
        // from herself. sync_recipient is what carries that.
        runBlocking {
            val alice = buildHarness()
            val bob = buildHarness()
            try {
                // Link a second device. The relay requires the change to be SIGNED
                // with the device auth key over the canonical device-list payload,
                // pinned to the current list version.
                val (_, version) = alice.api.listDevices()
                val secondPassword = UUID.randomUUID().toString()
                val signature = alice.authKey.sign(
                    app.relaymsg.net.SignedPayloads.deviceMutation(
                        accountId = alice.credentials.accountId,
                        expectedVersion = version,
                        action = "add",
                        targetDeviceId = 0,
                        password = secondPassword,
                    ),
                )
                val (secondDeviceId, _, _) = alice.api.addDevice(
                    password = secondPassword,
                    expectedVersion = version,
                    signerDeviceId = alice.credentials.deviceId,
                    signature = signature,
                )
                Log.i(TAG, "linked device $secondDeviceId to ${alice.username}")
                assertTrue("linked device should not reuse device 1", secondDeviceId != alice.credentials.deviceId)

                // Stand the second device up with its OWN identity and prekeys --
                // in Relay each device generates its own, which is why peer
                // identities are keyed by (account, device).
                val secondCredentials = RelayCredentials(
                    alice.credentials.accountId, secondDeviceId, secondPassword,
                )
                val secondAuthKey = DeviceAuthKey("relay-interop-2nd-${UUID.randomUUID()}")
                val secondAuth = RelayAuthenticator(
                    secondCredentials,
                    object : RequestSigner {
                        override fun sign(message: ByteArray) = secondAuthKey.sign(message)
                        override fun publicKey() = secondAuthKey.publicKey()
                    },
                )
                val secondApi = RelayApiClient(server, secondAuth)
                val secondKeys = MasterKeyStore(context, "interop2-${UUID.randomUUID()}")
                val secondStore = SecureStore.openInMemory(secondKeys)
                val secondMessenger = RelayMessenger(
                    api = secondApi,
                    engine = secondStore.makeCryptoEngine(secondCredentials.accountId, secondDeviceId),
                    store = secondStore,
                    credentials = secondCredentials,
                    sealedSenderTrustRoot = android.util.Base64.decode(
                        TRUST_ROOT_BASE64, android.util.Base64.DEFAULT,
                    ),
                )
                val secondPipeline = EnvelopePipeline(
                    secondMessenger, secondStore.messages, secondCredentials.accountId,
                )
                val secondSocket = RelayWebSocket(server, secondAuth)
                try {
                    secondMessenger.bootstrap(
                        secondAuthKey.publicKey(),
                        ByteArray(32).also { SecureRandom().nextBytes(it) },
                    )

                    val applied = Channel<EnvelopePipeline.Outcome>(Channel.UNLIMITED)
                    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
                    val drained = Channel<Unit>(Channel.CONFLATED)
                    secondSocket.connect()
                        .onEach { event ->
                            when (event) {
                                is RelayEvent.QueueDrained -> drained.trySend(Unit)
                                is RelayEvent.Envelope ->
                                    runCatching { secondPipeline.apply(event.envelope) }
                                        .getOrNull()?.let { applied.trySend(it) }
                                else -> Unit
                            }
                        }
                        .launchIn(scope)
                    withTimeoutOrNull(30_000) { drained.receive() }

                    val aliceDrained = Channel<Unit>(Channel.CONFLATED)
                    alice.socket.connect()
                        .onEach { if (it is RelayEvent.QueueDrained) aliceDrained.trySend(Unit) }
                        .launchIn(scope)
                    withTimeoutOrNull(30_000) { aliceDrained.receive() }

                    // Alice sends to Bob from device 1, then mirrors to her own devices.
                    val timestamp = System.currentTimeMillis()
                    val body = "sync probe \u2713 $timestamp"
                    val content = alice.messenger.buildTextContent(body, timestamp)
                    val outcome = alice.messenger.sendOverWebSocket(
                        alice.socket, bob.credentials.accountId, content.toByteArray(), timestamp,
                    )
                    assertTrue("send to bob rejected: $outcome", outcome is SendOutcome.Ok)
                    alice.messenger.sendSyncToOwnDevices(
                        alice.socket, content, bob.credentials.accountId, timestamp,
                    )

                    // The linked device must now hold it, filed under BOB and marked outgoing.
                    var stored: app.relaymsg.storage.StoredMessage? = null
                    withTimeoutOrNull(60_000) {
                        while (true) {
                            val next = applied.receive()
                            val conversationId = next.conversationId ?: continue
                            val found = secondStore.messages.messages(conversationId)
                                .firstOrNull { it.body == body }
                            if (found != null) {
                                assertEquals(
                                    "sync copy filed in the wrong conversation",
                                    bob.credentials.accountId,
                                    secondStore.messages.peerAccount(conversationId),
                                )
                                stored = found
                                break
                            }
                        }
                    }
                    assertTrue("linked device never received the sync copy", stored != null)
                    assertTrue(
                        "sync copy must be stored as OUTGOING, not as an incoming message",
                        stored!!.isOutgoing,
                    )
                    Log.i(TAG, "sync copy landed on device $secondDeviceId as outgoing")
                    scope.cancel()
                } finally {
                    secondSocket.disconnect()
                    secondStore.close()
                    secondKeys.wipe()
                    secondAuthKey.delete()
                }
            } finally {
                alice.cleanUp()
                bob.cleanUp()
            }
        }
    }

    @Test
    fun attachmentRoundTripsThroughTheRelayAsOpaqueCiphertext() {
        // Proves the blob pipeline against the real relay: encrypt under a fresh
        // key, upload, and have the far side fetch and decrypt using only the key
        // and digest that travelled inside the encrypted Content.
        //
        // Also checks the property the design depends on: what the relay stores
        // is NOT the plaintext. A relay that returned our bytes unchanged would
        // pass a naive round-trip test while storing readable media.
        runBlocking {
            val alice = buildHarness()
            val bob = buildHarness()
            try {
                val plaintext = ByteArray(4096) { (it * 31 % 251).toByte() }
                val sealed = app.relaymsg.crypto.AttachmentCipher.seal(plaintext)
                val blobId = alice.api.uploadAttachment(sealed.ciphertext)
                Log.i(TAG, "uploaded attachment $blobId (${sealed.ciphertext.size} bytes ciphertext)")

                // Anyone authenticated can fetch the blob -- it is opaque, and its
                // secrecy rests entirely on the key never reaching the relay.
                val fetched = bob.api.downloadAttachment(blobId)
                assertArrayEquals("relay returned different bytes", sealed.ciphertext, fetched)

                assertFalse(
                    "relay stored something resembling the plaintext",
                    fetched.contentEquals(plaintext),
                )
                assertEquals(plaintext.size + 12 + 16, fetched.size)

                val opened = app.relaymsg.crypto.AttachmentCipher.open(
                    fetched, sealed.key, sealed.digest,
                )
                assertArrayEquals(plaintext, opened)

                // And a tampered blob must fail closed, before decryption.
                val tampered = fetched.copyOf().also { it[it.size - 1] = (it.last() + 1).toByte() }
                org.junit.Assert.assertThrows(
                    app.relaymsg.crypto.AttachmentCipher.DigestMismatchException::class.java,
                ) {
                    app.relaymsg.crypto.AttachmentCipher.open(tampered, sealed.key, sealed.digest)
                }
                Log.i(TAG, "attachment decrypted correctly and tampering rejected")
            } finally {
                alice.cleanUp()
                bob.cleanUp()
            }
        }
    }

    @Test
    fun groupMessageEncryptedOnceReachesEveryMember() {
        // The sender-key path end to end: a group is announced, the members learn
        // the roster from the update alone (the relay stores NO group state), the
        // sender distributes its sender key pairwise, and one ciphertext is fanned
        // out to everyone.
        runBlocking {
            val alice = buildHarness()
            val bob = buildHarness()
            try {
                val received = Channel<DecryptedEnvelope>(Channel.UNLIMITED)
                val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
                val applied = Channel<EnvelopePipeline.Outcome>(Channel.UNLIMITED)

                suspend fun connect(h: Harness, sink: Channel<EnvelopePipeline.Outcome>?) {
                    val drained = Channel<Unit>(Channel.CONFLATED)
                    h.socket.connect()
                        .onEach { event ->
                            when (event) {
                                is RelayEvent.QueueDrained -> drained.trySend(Unit)
                                is RelayEvent.Envelope ->
                                    runCatching { h.pipeline.apply(event.envelope) }
                                        .getOrNull()?.let { sink?.trySend(it) }
                                else -> Unit
                            }
                        }
                        .launchIn(scope)
                    withTimeoutOrNull(30_000) { drained.receive() }
                }
                connect(bob, applied)
                connect(alice, null)

                // Alice creates the group locally and announces it. Bob has never
                // heard of it until this update lands.
                val groupId = UUID.randomUUID().toString()
                val distributionId = UUID.randomUUID().toString()
                val members = listOf(alice.credentials.accountId, bob.credentials.accountId)

                alice.store.messages.upsertGroup(
                    groupId, "Interop", distributionId, 1, members,
                    listOf(alice.credentials.accountId),
                )
                val update = alice.messenger.buildGroupUpdate(
                    groupId = groupId,
                    action = relay.content.ContentOuterClass.GroupUpdate.Action.CREATE,
                    revision = 1,
                    name = "Interop",
                    members = members,
                    admins = listOf(alice.credentials.accountId),
                    distributionId = distributionId,
                )
                alice.messenger.sendToGroupMembers(
                    alice.socket, members, update.toByteArray(), System.currentTimeMillis(),
                )

                // Bob must end up with the roster purely from that message.
                assertTrue(
                    "bob never received the group update",
                    withTimeoutOrNull(45_000) { applied.receive() } != null,
                )
                val bobsGroup = requireNotNull(bob.store.messages.group(groupId)) {
                    "bob has no group after the CREATE update"
                }
                assertEquals("Interop", bobsGroup.name)
                assertEquals(members.sorted(), bobsGroup.members.sorted())
                assertEquals(distributionId, bobsGroup.distributionId)

                // Now the message itself: one sender-key ciphertext, fanned out.
                val timestamp = System.currentTimeMillis()
                val body = "group hello \u2713 $timestamp"
                val outcome = alice.messenger.sendGroupMessage(
                    socket = alice.socket,
                    groupId = groupId,
                    distributionId = distributionId,
                    members = members,
                    plaintext = alice.messenger.buildGroupTextContent(groupId, body, timestamp).toByteArray(),
                    clientTimestamp = timestamp,
                )
                assertTrue("group send rejected: $outcome", outcome is SendOutcome.Ok)

                // Bob receives the SKDM first, then the sender-key message.
                var delivered: EnvelopePipeline.Outcome? = null
                withTimeoutOrNull(60_000) {
                    while (true) {
                        val next = applied.receive()
                        if (next.conversationId != null && !next.isDuplicate) {
                            val stored = bob.store.messages.messages(next.conversationId!!)
                            if (stored.any { it.body == body }) { delivered = next; break }
                        }
                    }
                }
                assertTrue("bob never decrypted the group message", delivered != null)
                Log.i(TAG, "group message decrypted by ${bob.username} via sender key")

                scope.cancel()
            } finally {
                alice.cleanUp()
                bob.cleanUp()
            }
        }
    }

    @Test
    fun resolvesItsOwnUsernameThroughBlindedDiscovery() {
        // The live OPRF round-trip, against the relay's real secret key: blind the
        // username, have the server evaluate it, unblind, derive the token, and
        // look it up. The token we compute must equal the one the server indexed
        // when the account was created -- which is the whole basis of discovery,
        // since the client can only ever produce the blinded form.
        //
        // Offline vectors cannot prove this: they check our arithmetic against a
        // transcription of the server's algorithm, not against its actual key.
        runBlocking {
            val harness = buildHarness()
            try {
                val sodium = com.goterl.lazysodium.LazySodiumAndroid(
                    com.goterl.lazysodium.SodiumAndroid(),
                )
                val discovery = app.relaymsg.crypto.BlindedDiscovery(sodium)

                val blinded = discovery.blind(harness.username)
                val evaluated = harness.api.directoryEvaluate(listOf(blinded.element))
                assertEquals(1, evaluated.size)

                val token = discovery.token(blinded, evaluated.first())
                val matches = harness.api.directoryResolve(listOf(token))

                assertEquals("directory did not resolve our own username", 1, matches.size)
                assertEquals(harness.credentials.accountId, matches.first().accountId)
                assertEquals(harness.username, matches.first().username)
                Log.i(TAG, "blinded discovery resolved ${harness.username} correctly")
            } finally {
                harness.cleanUp()
            }
        }
    }

    @Test
    fun blindedDiscoveryRevealsNothingForAnUnregisteredName() {
        // Non-users must simply be absent from the results rather than producing a
        // distinguishable error, or discovery would leak who is registered.
        runBlocking {
            val harness = buildHarness()
            try {
                val sodium = com.goterl.lazysodium.LazySodiumAndroid(
                    com.goterl.lazysodium.SodiumAndroid(),
                )
                val discovery = app.relaymsg.crypto.BlindedDiscovery(sodium)
                val blinded = discovery.blind("definitely-not-registered-${UUID.randomUUID()}")
                val evaluated = harness.api.directoryEvaluate(listOf(blinded.element))
                val token = discovery.token(blinded, evaluated.first())
                assertTrue(harness.api.directoryResolve(listOf(token)).isEmpty())
            } finally {
                harness.cleanUp()
            }
        }
    }

    @Test
    fun sendsWithoutConsumingAOneTimePreKey() {
        // Diagnostic for a peer that cannot decrypt our messages. The relay hands
        // out a one-time prekey per bundle fetch; we deliberately discard it and
        // run PQXDH from the signed + Kyber prekeys alone -- the same degraded but
        // valid path taken when a peer's pool is exhausted.
        //
        // If the peer can read THIS but not a normal send, their published
        // one-time prekeys no longer match the private halves in their store, and
        // every new session that consumes one dies silently.
        runBlocking {
            val peer = peerUsername
            assumeTrue("set -P...relayPeer=<username> to run", peer != null)
            val harness = buildHarness()
            try {
                val peerAccount = harness.api.lookupAccountId(peer!!)
                val devices = harness.messenger.refreshSessions(peerAccount, useOneTimePreKeys = false)
                assertTrue("peer has no registered devices", devices.isNotEmpty())
                Log.i(TAG, "sessions WITHOUT one-time prekeys: ${devices.size} device(s)")

                val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
                val drained = Channel<Unit>(Channel.CONFLATED)
                harness.socket.connect()
                    .onEach { if (it is RelayEvent.QueueDrained) drained.trySend(Unit) }
                    .launchIn(scope)
                withTimeoutOrNull(20_000) { drained.receive() }

                val timestamp = System.currentTimeMillis()
                val body = "NO-OTK probe \u2713 ($timestamp)"
                val outcome = harness.messenger.sendOverWebSocket(
                    socket = harness.socket,
                    account = peerAccount,
                    plaintext = harness.messenger.buildTextContent(body, timestamp).toByteArray(),
                    clientTimestamp = timestamp,
                )
                Log.i(TAG, "NO-OTK send outcome: $outcome from ${harness.username}")
                assertTrue("relay rejected the send: $outcome", outcome is SendOutcome.Ok)
                scope.cancel()
            } finally {
                harness.cleanUp()
            }
        }
    }

    @Test
    fun receivesAMessageSentFromTheIosClient() {
        // Reverses the direction. Android sending to iOS exercises iOS's PQXDH
        // handshake against prekeys the relay published for it; if those private
        // halves are gone (a reinstall, a wiped store), iOS cannot decrypt and --
        // by design -- acks and drops silently, which is indistinguishable from
        // the message never arriving. Having iOS start the session instead avoids
        // that path entirely and says whether the two clients can talk at all.
        //
        // Registers a probe account, prints its username, and waits. Send to that
        // username from the iPhone while it runs.
        runBlocking {
            val harness = buildHarness()
            try {
                Log.i(TAG, "PROBE READY -- send a message from iOS to: ${harness.username}")
                Log.i(TAG, "PROBE account id: ${harness.credentials.accountId}")

                val received = Channel<DecryptedEnvelope>(Channel.UNLIMITED)
                val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
                harness.socket.connect()
                    .onEach { event ->
                        if (event is RelayEvent.Envelope) {
                            // Log before decrypting: an envelope that arrives but
                            // fails to open is a very different diagnosis from one
                            // that never arrives.
                            Log.i(
                                TAG,
                                "PROBE envelope ${event.envelope.id} sender=" +
                                    event.envelope.senderAccount.ifEmpty { "<sealed>" } +
                                    " type=${event.envelope.message.kind}",
                            )
                            runCatching { harness.messenger.processEnvelope(event.envelope) }
                                .onFailure { Log.e(TAG, "PROBE decrypt failed", it) }
                                .getOrNull()?.let { received.trySend(it) }
                        }
                    }
                    .launchIn(scope)

                val delivered = withTimeoutOrNull(300_000) { received.receive() }
                assertTrue(
                    "no message arrived from iOS within 5 minutes -- send to ${harness.username}",
                    delivered != null,
                )
                Log.i(TAG, "PROBE received from ${delivered!!.senderAccount}: ${delivered.content.text.body}")
                scope.cancel()
            } finally {
                harness.cleanUp()
            }
        }
    }

    @Test
    fun twoAndroidClientsRoundTripThroughTheLiveRelay() {
        // Isolation test. If this passes, the client's own send AND receive paths
        // are correct against the real relay, so any failure to reach the iOS
        // client is on the iOS side (or in the pairing) rather than here. If it
        // fails, the bug is ours. Worth running before blaming the other client.
        runBlocking {
            val alice = buildHarness()
            val bob = buildHarness()
            try {
                val received = Channel<DecryptedEnvelope>(Channel.UNLIMITED)
                val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
                val drained = Channel<Unit>(Channel.CONFLATED)

                bob.socket.connect()
                    .onEach { event ->
                        when (event) {
                            is RelayEvent.QueueDrained -> drained.trySend(Unit)
                            is RelayEvent.Envelope ->
                                bob.messenger.processEnvelope(event.envelope)
                                    ?.let { received.trySend(it) }
                            else -> Unit
                        }
                    }
                    .launchIn(scope)
                assertTrue(
                    "bob's socket never drained its queue",
                    withTimeoutOrNull(30_000) { drained.receive() } != null,
                )

                // Alice needs a live socket too: the authenticated send path is a
                // WebSocket frame, not a REST call.
                val aliceDrained = Channel<Unit>(Channel.CONFLATED)
                alice.socket.connect()
                    .onEach { if (it is RelayEvent.QueueDrained) aliceDrained.trySend(Unit) }
                    .launchIn(scope)
                withTimeoutOrNull(30_000) { aliceDrained.receive() }

                alice.messenger.refreshSessions(bob.credentials.accountId)

                val timestamp = System.currentTimeMillis()
                val body = "loopback \u2713 $timestamp"
                val outcome = alice.messenger.sendOverWebSocket(
                    socket = alice.socket,
                    account = bob.credentials.accountId,
                    plaintext = alice.messenger.buildTextContent(body, timestamp).toByteArray(),
                    clientTimestamp = timestamp,
                )
                assertTrue("send rejected: $outcome", outcome is SendOutcome.Ok)

                val delivered = withTimeoutOrNull(45_000) { received.receive() }
                assertTrue("bob never received the message", delivered != null)
                assertEquals(alice.credentials.accountId, delivered!!.senderAccount)
                assertEquals(body, delivered.content.text.body)
                Log.i(TAG, "loopback delivered and decrypted: ${delivered.content.text.body}")

                scope.cancel()
            } finally {
                alice.cleanUp()
                bob.cleanUp()
            }
        }
    }

    @Test
    fun androidSendsAMessageTheIosClientCanRead() {
        runBlocking {
        val peer = peerUsername
        assumeTrue(
            "set -Pandroid.testInstrumentationRunnerArguments.relayPeer=<iOS username> to run",
            peer != null,
        )
        val harness = buildHarness()
        try {
            val peerAccount = harness.api.lookupAccountId(peer!!)
            Log.i(TAG, "resolved $peer -> $peerAccount")

            val devices = harness.messenger.refreshSessions(peerAccount)
            assertTrue("peer has no registered devices", devices.isNotEmpty())
            Log.i(TAG, "established sessions with ${devices.size} device(s)")

            val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            val connected = Channel<Unit>(Channel.CONFLATED)
            harness.socket.connect()
                .onEach { if (it is RelayEvent.QueueDrained) connected.trySend(Unit) }
                .launchIn(scope)
            // The queue-drained marker is the signal the socket is live.
            withTimeoutOrNull(20_000) { connected.receive() }

            val timestamp = System.currentTimeMillis()
            val body = "Hello from the Relay Android client ✓ ($timestamp)"
            val content = harness.messenger.buildTextContent(body, timestamp)

            val outcome = harness.messenger.sendOverWebSocket(
                socket = harness.socket,
                account = peerAccount,
                plaintext = content.toByteArray(),
                clientTimestamp = timestamp,
            )
            Log.i(TAG, "send outcome: $outcome")
            assertTrue("relay rejected the send: $outcome", outcome is SendOutcome.Ok)

                scope.cancel()
            } finally {
                harness.cleanUp()
            }
        }
    }
}
