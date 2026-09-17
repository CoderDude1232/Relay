package app.relaymsg.net

import com.google.protobuf.ByteString
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString
import relay.v1.Relay

/** Events surfaced by a live relay connection. */
sealed interface RelayEvent {
    data class Envelope(val envelope: IncomingEnvelope) : RelayEvent

    /** The offline queue is fully drained; everything after this is real time. */
    data object QueueDrained : RelayEvent

    /** A signed remote-wipe command. Verify the signature before acting. */
    data class Nuke(val command: NukeEvent) : RelayEvent

    data class DeviceListChanged(val change: DeviceListChangedEvent) : RelayEvent

    /** The connection ended; the flow completes after this. */
    data class Disconnected(val cause: Throwable?) : RelayEvent
}

class NotConnectedException : IllegalStateException("relay websocket is not connected")

/**
 * The real-time channel to the relay. One instance is one connection;
 * reconnection policy belongs to the caller.
 *
 * Every binary frame is exactly one `ClientFrame` (out) or `ServerFrame` (in).
 * On connect the server drains this device's queue as `Envelope` frames, then
 * sends `QueueEmpty`.
 */
class RelayWebSocket(
    baseUrl: String,
    private val auth: RelayAuthenticator,
    client: OkHttpClient = defaultClient(),
) {
    companion object {
        /**
         * The server pings every 45s and drops the socket after 60s of silence.
         * Pinging from this side at 25s keeps the connection warm through NAT and
         * proxy idle timeouts, and surfaces a dead socket quickly so the caller
         * can reconnect and drain the queue. iOS does the same.
         */
        private const val PING_INTERVAL_SECONDS = 25L

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .pingInterval(PING_INTERVAL_SECONDS, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS) // a websocket is expected to idle
            .build()
    }

    private val url = baseUrl.trimEnd('/')
        .replaceFirst("https://", "wss://")
        .replaceFirst("http://", "ws://") + "/v1/ws"

    private val client = client
    private val nextRequestId = AtomicLong(1)
    private val pending = mutableMapOf<Long, CompletableDeferred<Relay.SendResponse>>()

    @Volatile
    private var socket: WebSocket? = null

    /**
     * Connects and emits events until the socket closes.
     *
     * The upgrade request carries the same `Relay-Sig` headers as any REST call —
     * the server wraps the WebSocket handler in the same authenticator.
     */
    fun connect(): Flow<RelayEvent> = callbackFlow {
        val request = Request.Builder()
            .url(url)
            .apply { auth.headers("GET", "/v1/ws").forEach { (k, v) -> header(k, v) } }
            .build()

        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                socket = webSocket
            }

            override fun onMessage(webSocket: WebSocket, bytes: okio.ByteString) {
                val frame = runCatching { Relay.ServerFrame.parseFrom(bytes.toByteArray()) }
                    .getOrNull() ?: return
                when (frame.payloadCase) {
                    Relay.ServerFrame.PayloadCase.SEND_RESPONSE -> {
                        val response = frame.sendResponse
                        synchronized(pending) { pending.remove(response.replyTo) }
                            ?.complete(response)
                    }
                    Relay.ServerFrame.PayloadCase.ENVELOPE ->
                        IncomingEnvelope.from(frame.envelope)?.let { trySend(RelayEvent.Envelope(it)) }
                    Relay.ServerFrame.PayloadCase.QUEUE_EMPTY ->
                        trySend(RelayEvent.QueueDrained)
                    Relay.ServerFrame.PayloadCase.NUKE -> trySend(
                        RelayEvent.Nuke(
                            NukeEvent(
                                accountId = frame.nuke.accountId,
                                commandId = frame.nuke.commandId,
                                creationTimeMs = frame.nuke.creationTimeMs,
                                initiatingDeviceId = frame.nuke.initiatingDeviceId,
                                signature = frame.nuke.signature.toByteArray(),
                            ),
                        ),
                    )
                    Relay.ServerFrame.PayloadCase.DEVICE_LIST_CHANGED -> trySend(
                        RelayEvent.DeviceListChanged(
                            DeviceListChangedEvent(
                                action = when (frame.deviceListChanged.action) {
                                    Relay.DeviceListChanged.Action.DEVICE_ADDED ->
                                        DeviceListChangedEvent.Action.ADDED
                                    Relay.DeviceListChanged.Action.DEVICE_REMOVED ->
                                        DeviceListChangedEvent.Action.REMOVED
                                    else -> DeviceListChangedEvent.Action.UNKNOWN
                                },
                                deviceId = frame.deviceListChanged.deviceId,
                            ),
                        ),
                    )
                    else -> Unit
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                failPending(t)
                trySend(RelayEvent.Disconnected(t))
                close()
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                failPending(null)
                trySend(RelayEvent.Disconnected(null))
                close()
            }
        }

        val webSocket = client.newWebSocket(request, listener)
        awaitClose {
            socket = null
            webSocket.cancel()
        }
    }

    /**
     * Sends one ciphertext to one destination mailbox.
     *
     * The relay accepts **exactly one** `DeviceMessage` per frame and treats
     * `destination_account` as an opaque mailbox id, so per-device fan-out is one
     * call per mailbox (PROTOCOL.md §4.1).
     */
    suspend fun send(
        mailboxId: String,
        payload: DeviceMessagePayload,
        clientTimestamp: Long,
        ephemeral: Boolean = false,
    ): SendOutcome {
        val socket = socket ?: throw NotConnectedException()
        val requestId = nextRequestId.getAndIncrement()

        val frame = Relay.ClientFrame.newBuilder()
            .setId(requestId)
            .setSend(
                Relay.SendRequest.newBuilder()
                    .setDestinationAccount(mailboxId)
                    .addMessages(
                        Relay.DeviceMessage.newBuilder()
                            .setDeviceId(payload.deviceId)
                            .setRegistrationId(payload.registrationId)
                            .setType(payload.message.kind.toWire())
                            .setContent(ByteString.copyFrom(payload.message.data)),
                    )
                    .setClientTimestamp(clientTimestamp)
                    .setEphemeral(ephemeral),
            )
            .build()

        val deferred = CompletableDeferred<Relay.SendResponse>()
        synchronized(pending) { pending[requestId] = deferred }
        if (!socket.send(frame.toByteArray().toByteString())) {
            synchronized(pending) { pending.remove(requestId) }
            throw NotConnectedException()
        }
        return SendOutcome.from(deferred.await())
    }

    /** Confirms durable receipt; the relay then drops the envelope from our queue. */
    fun ack(envelopeId: String) {
        val socket = socket ?: throw NotConnectedException()
        val frame = Relay.ClientFrame.newBuilder()
            .setAck(Relay.AckRequest.newBuilder().setEnvelopeId(envelopeId))
            .build()
        socket.send(frame.toByteArray().toByteString())
    }

    fun disconnect() {
        socket?.close(1000, null)
        socket = null
    }

    private fun failPending(cause: Throwable?) {
        synchronized(pending) {
            pending.values.forEach {
                it.completeExceptionally(cause ?: NotConnectedException())
            }
            pending.clear()
        }
    }
}
