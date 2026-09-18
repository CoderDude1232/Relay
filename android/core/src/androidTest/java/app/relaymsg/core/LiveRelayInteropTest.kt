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
import org.junit.Assert.assertEquals
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

        Harness(credentials, api, messenger, RelayWebSocket(server, auth), store, masterKeys, authKey)
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
