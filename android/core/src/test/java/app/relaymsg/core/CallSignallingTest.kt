package app.relaymsg.core

import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import relay.content.ContentOuterClass.CallMessage
import relay.content.ContentOuterClass.Content

/**
 * Call signalling logic — the half that must interoperate with iOS.
 *
 * Runs on the JVM because [CallTransport] abstracts WebRTC away: what matters
 * for interop is which signals are sent, in what order, and which are ephemeral.
 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class CallSignallingTest {

    private val me = "6f1a2b3c-4d5e-4f60-8899-aabbccddeeff"
    private val peer = "11112222-3333-4444-5555-666677778888"

    /** Records what was sent, so ordering and ephemerality can be asserted. */
    private class Recorder {
        data class Sent(val peer: String, val content: Content, val ephemeral: Boolean)
        val sent = mutableListOf<Sent>()
        val ended = mutableListOf<Pair<ActiveCall, CallEndReason>>()
        val types get() = sent.map { it.content.call.type }
    }

    private class FakeTransport(
        var offerSdp: String = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF\r\n",
        var failOnOffer: Boolean = false,
    ) : CallTransport {
        val applied = mutableListOf<String>()
        var closed = false

        /** Set when the manager attaches; tests drive ICE through it. */
        var connection: ((MediaConnectionState) -> Unit)? = null
        override fun onConnectionState(listener: (MediaConnectionState) -> Unit) {
            connection = listener
        }

        fun ice(state: MediaConnectionState) = connection?.invoke(state)
        override suspend fun createOffer(isVideo: Boolean): String {
            if (failOnOffer) throw IllegalStateException("no mic")
            return offerSdp
        }
        override suspend fun createAnswer(remoteSdp: String, isVideo: Boolean) = "answer-sdp"
        override suspend fun acceptAnswer(remoteSdp: String) {}
        override suspend fun addIceCandidate(candidateJson: String) { applied += candidateJson }
        // Named off the interface methods on purpose: a `var microphoneEnabled`
        // would generate the same JVM setter signature as setMicrophoneEnabled.
        var micOn = true
        var cameraOn = true
        var switches = 0
        var route: AudioRoute? = null
        var routes = listOf(
            AudioRoute(1, AudioRouteKind.EARPIECE, "Phone"),
            AudioRoute(2, AudioRouteKind.SPEAKER, "Speaker"),
        )
        override fun setMicrophoneEnabled(enabled: Boolean) { micOn = enabled }
        override fun audioRoutes() = routes
        override fun selectAudioRoute(route: AudioRoute) { this.route = route }
        override fun switchCamera() { switches++ }
        override fun setCameraEnabled(enabled: Boolean) { cameraOn = enabled }
        override fun close() { closed = true }
    }

    private fun TestScope.manager(
        transport: FakeTransport = FakeTransport(),
        recorder: Recorder = Recorder(),
    ): Pair<CallManager, Recorder> =
        CallManager(
            ownAccount = me,
            ownDevice = 1,
            newTransport = { transport },
            send = { p, c, e -> recorder.sent += Recorder.Sent(p, c, e) },
            // The grace-period timers live here, so the virtual clock controls
            // them and a test never actually waits three seconds.
            scope = backgroundScope,
            onEnded = { call, reason -> recorder.ended += call to reason },
        ) to recorder

    // ------------------------------------------------------------- call kind

    @Test
    fun `video offers carry the iOS kind metadata and audio offers carry none`() {
        // iOS reads the kind out of the OFFER's `ice` field, so the exact string
        // matters; an audio offer must stay empty or it would decode as video.
        val video = CallSignalling.offer("call-1", "sdp", me, 1, isVideo = true)
        assertEquals("""{"kind":"video"}""", video.call.ice)

        val audio = CallSignalling.offer("call-1", "sdp", me, 1, isVideo = false)
        assertEquals("", audio.call.ice)
    }

    @Test
    fun `call kind comes from metadata first and the SDP only as a fallback`() {
        fun signal(ice: String, sdp: String) = CallSignal(
            type = CallMessage.Type.OFFER, callId = "c", sdp = sdp, ice = ice,
            fromAccount = peer, groupId = "", targetAccount = "", participants = emptyList(),
        )

        assertTrue(CallSignalling.isVideoOffer(signal("""{"kind":"video"}""", "")))
        // Metadata wins even when the SDP disagrees.
        assertFalse(CallSignalling.isVideoOffer(signal("""{"kind":"audio"}""", "m=video 9 RTP")))
        // No metadata: fall back to the SDP, the way iOS does.
        assertTrue(CallSignalling.isVideoOffer(signal("", "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF\r\n")))
        assertFalse(CallSignalling.isVideoOffer(signal("", "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF\r\n")))
    }

    @Test
    fun `m equals video inside an attribute does not make a call video`() {
        // Line-anchored, not a substring search: guessing video here would open
        // the camera on an audio call.
        val signal = CallSignal(
            type = CallMessage.Type.OFFER, callId = "c",
            sdp = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF\r\na=label:m=video\r\n",
            ice = "", fromAccount = peer, groupId = "", targetAccount = "",
            participants = emptyList(),
        )
        assertFalse(CallSignalling.isVideoOffer(signal))
    }

    // ------------------------------------------------------------ ephemerality

    @Test
    fun `ephemerality matches the iOS rule exactly`() {
        // Queued: must survive an offline device, or a call can never wake a
        // sleeping phone and a hangup can be lost, leaving the far side ringing.
        assertFalse(CallSignalling.isEphemeral(CallMessage.Type.OFFER))
        assertFalse(CallSignalling.isEphemeral(CallMessage.Type.HANGUP))
        assertFalse(CallSignalling.isEphemeral(CallMessage.Type.GROUP_RING))

        // Ephemeral: worthless once stale, and queuing them would replay a dead
        // call's signalling on the next connect.
        assertTrue(CallSignalling.isEphemeral(CallMessage.Type.ANSWER))
        assertTrue(CallSignalling.isEphemeral(CallMessage.Type.ICE))
        assertTrue(CallSignalling.isEphemeral(CallMessage.Type.RINGING))
        assertTrue(CallSignalling.isEphemeral(CallMessage.Type.BUSY))
        assertTrue(CallSignalling.isEphemeral(CallMessage.Type.GROUP_JOIN))
        assertTrue(CallSignalling.isEphemeral(CallMessage.Type.GROUP_LEAVE))
    }

    @Test
    fun `an unrecognised signal type is treated as durable`() {
        // Forward compatibility: queuing something that turns out to be
        // ephemeral is recoverable; dropping something durable is not.
        assertFalse(CallSignalling.isEphemeral(CallMessage.Type.UNRECOGNIZED))
    }

    @Test
    fun `offer carries type explicitly even though it is the zero value`() {
        // OFFER == 0, so proto3 elides it; a receiver must default to OFFER.
        val content = CallSignalling.offer("call-1", "sdp", me, 1)
        assertEquals(CallMessage.Type.OFFER, content.call.type)
        val reparsed = Content.parseFrom(content.toByteArray())
        assertEquals(CallMessage.Type.OFFER, reparsed.call.type)
        assertEquals("call-1", reparsed.call.callId)
    }

    @Test
    fun `every signal stamps the sender so it survives sealed sender`() {
        val content = CallSignalling.hangup("call-1", me, 3)
        assertEquals(me, content.senderAccountId)
        assertEquals(3, content.senderDeviceId)
    }

    // -------------------------------------------------------------- lifecycle

    @Test
    fun `outgoing call sends an offer and connects on answer`() = runTest {
        val transport = FakeTransport()
        val (calls, recorder) = manager(transport)
        val callId = calls.placeCall(peer, isVideo = false)

        assertTrue(callId != null)
        assertEquals(listOf(CallMessage.Type.OFFER), recorder.types)
        assertFalse("OFFER must be queued, not ephemeral", recorder.sent.single().ephemeral)
        assertEquals(CallState.OUTGOING_RINGING, calls.call.value?.state)

        calls.onSignal(signal(CallMessage.Type.ANSWER, callId!!, sdp = "answer"))
        // An answered SDP exchange is not a working call; only ICE says that.
        assertEquals(CallState.CONNECTING, calls.call.value?.state)
        assertNull("not connected until media flows", calls.call.value?.connectedAt)

        transport.ice(MediaConnectionState.CONNECTED)
        assertEquals(CallState.ACTIVE, calls.call.value?.state)
        assertTrue("connected time should be recorded", calls.call.value?.connectedAt != null)
    }

    @Test
    fun `incoming call auto-replies ringing then connects when accepted`() = runTest {
        val transport = FakeTransport()
        val (calls, recorder) = manager(transport)
        calls.onSignal(signal(CallMessage.Type.OFFER, "call-9", sdp = "m=audio"))

        assertEquals(CallState.INCOMING_RINGING, calls.call.value?.state)
        assertEquals(listOf(CallMessage.Type.RINGING), recorder.types)
        assertTrue("RINGING is ephemeral", recorder.sent.single().ephemeral)

        assertTrue(calls.accept())
        assertEquals(CallMessage.Type.ANSWER, recorder.types.last())
        assertEquals(CallState.CONNECTING, calls.call.value?.state)

        transport.ice(MediaConnectionState.CONNECTED)
        assertEquals(CallState.ACTIVE, calls.call.value?.state)
    }

    @Test
    fun `a second incoming call gets busy and does not disturb the active one`() = runTest {
        val transport = FakeTransport()
        val (calls, recorder) = manager(transport)
        calls.onSignal(signal(CallMessage.Type.OFFER, "call-1", sdp = "m=audio"))
        calls.accept()
        transport.ice(MediaConnectionState.CONNECTED)
        val active = calls.call.value

        calls.onSignal(signal(CallMessage.Type.OFFER, "call-2", from = "someone-else", sdp = "m=audio"))

        assertEquals(CallMessage.Type.BUSY, recorder.types.last())
        assertEquals("the active call must be untouched", active?.callId, calls.call.value?.callId)
        assertEquals(CallState.ACTIVE, calls.call.value?.state)
    }

    @Test
    fun `signals for a different call id are ignored`() = runTest {
        // Stale signalling from an ended call arrives routinely, since ICE and
        // ANSWER race and the relay may deliver late.
        val (calls, _) = manager()
        val callId = calls.placeCall(peer, isVideo = false)!!
        calls.onSignal(signal(CallMessage.Type.HANGUP, "some-other-call"))
        assertEquals("unrelated hangup must not end our call", CallState.OUTGOING_RINGING, calls.call.value?.state)
        assertEquals(callId, calls.call.value?.callId)
    }

    @Test
    fun `mute and speaker are local only and never reach the wire`() = runTest {
        val transport = FakeTransport()
        val (calls, recorder) = manager(transport)
        calls.placeCall(peer, isVideo = false)
        recorder.sent.clear()

        calls.setMuted(true)
        assertFalse(transport.micOn)
        assertTrue(calls.call.value!!.isMuted)

        calls.setSpeakerOn(true)
        assertEquals(AudioRouteKind.SPEAKER, transport.route?.kind)
        assertEquals(AudioRouteKind.SPEAKER, calls.call.value!!.audioRoute)

        // A "they muted you" indicator would leak what is happening in someone's
        // room, so nothing is signalled. iOS does not send one either.
        assertTrue("muting must not be signalled", recorder.sent.isEmpty())
    }

    @Test
    fun `mute with no call in progress is ignored`() = runTest {
        val transport = FakeTransport()
        val (calls, _) = manager(transport)
        calls.setMuted(true)

        assertNull(calls.call.value)
        assertTrue("must not touch a transport that does not exist", transport.micOn)
    }

    @Test
    fun `turning the speaker off prefers a headset over the earpiece`() = runTest {
        val transport = FakeTransport()
        transport.routes = listOf(
            AudioRoute(1, AudioRouteKind.EARPIECE, "Phone"),
            AudioRoute(2, AudioRouteKind.SPEAKER, "Speaker"),
            AudioRoute(3, AudioRouteKind.BLUETOOTH, "Headphones"),
        )
        val (calls, _) = manager(transport)
        calls.placeCall(peer, isVideo = false)

        calls.setSpeakerOn(true)
        assertEquals(AudioRouteKind.SPEAKER, calls.call.value!!.audioRoute)

        // "Speaker off" means back to wherever audio would otherwise go. With
        // headphones paired, that is the headphones, not the earpiece.
        calls.setSpeakerOn(false)
        assertEquals(AudioRouteKind.BLUETOOTH, calls.call.value!!.audioRoute)
    }

    @Test
    fun `camera controls are local and need a call in progress`() = runTest {
        val transport = FakeTransport()
        val (calls, recorder) = manager(transport)

        // No call: nothing to flip, and nothing to crash on.
        calls.switchCamera()
        calls.setCameraEnabled(false)
        assertEquals(0, transport.switches)
        assertTrue(transport.cameraOn)

        calls.placeCall(peer, isVideo = true)
        recorder.sent.clear()
        calls.switchCamera()
        calls.setCameraEnabled(false)

        assertEquals(1, transport.switches)
        assertFalse(transport.cameraOn)
        assertFalse(calls.call.value!!.isCameraOn)
        assertTrue("camera changes must not be signalled", recorder.sent.isEmpty())
    }

    // ------------------------------------------------------------ ice recovery

    @Test
    fun `a disconnect that recovers inside the grace period keeps the call`() = runTest {
        val transport = FakeTransport()
        val (calls, recorder) = manager(transport)
        val callId = calls.placeCall(peer, isVideo = false)!!
        calls.onSignal(signal(CallMessage.Type.ANSWER, callId, sdp = "answer"))
        transport.ice(MediaConnectionState.CONNECTED)
        recorder.sent.clear()

        // WebRTC drops to `disconnected` on any network blip and usually finds a
        // new candidate pair by itself. Ending the call here would be wrong.
        transport.ice(MediaConnectionState.DISCONNECTED)
        advanceTimeBy(9_000)
        transport.ice(MediaConnectionState.CONNECTED)
        advanceTimeBy(30_000)

        assertEquals(CallState.ACTIVE, calls.call.value?.state)
        assertTrue("a recovered blip must not signal anything", recorder.sent.isEmpty())
    }

    @Test
    fun `ice failure ends the call after the grace period and tells the peer`() = runTest {
        val transport = FakeTransport()
        val (calls, recorder) = manager(transport)
        val callId = calls.placeCall(peer, isVideo = false)!!
        calls.onSignal(signal(CallMessage.Type.ANSWER, callId, sdp = "answer"))
        transport.ice(MediaConnectionState.CONNECTED)
        recorder.sent.clear()

        transport.ice(MediaConnectionState.FAILED)
        advanceTimeBy(2_000)
        assertEquals("must not give up early", CallState.ACTIVE, calls.call.value?.state)

        advanceTimeBy(2_000)
        assertNull(calls.call.value)
        // Without this the far side sits watching a call that is already gone.
        assertEquals(CallMessage.Type.HANGUP, recorder.sent.last().content.call.type)
        assertEquals(CallEndReason.FAILED, recorder.ended.single().second)
    }

    @Test
    fun `the grace period is not restarted by repeated failure reports`() = runTest {
        val transport = FakeTransport()
        val (calls, _) = manager(transport)
        val callId = calls.placeCall(peer, isVideo = false)!!
        calls.onSignal(signal(CallMessage.Type.ANSWER, callId, sdp = "answer"))
        transport.ice(MediaConnectionState.CONNECTED)

        // ICE reports state changes repeatedly while it flails. If each one reset
        // the timer, a permanently broken call would never end.
        transport.ice(MediaConnectionState.FAILED)
        advanceTimeBy(2_000)
        transport.ice(MediaConnectionState.FAILED)
        transport.ice(MediaConnectionState.DISCONNECTED)
        advanceTimeBy(1_500)

        assertNull(calls.call.value)
    }

    // --------------------------------------------------------------- call log

    @Test
    fun `the call log distinguishes a connected call from one that never was`() = runTest {
        val connectedTransport = FakeTransport()
        val (connected, connectedLog) = manager(connectedTransport)
        val callId = connected.placeCall(peer, isVideo = false)!!
        connected.onSignal(signal(CallMessage.Type.ANSWER, callId, sdp = "answer"))
        connectedTransport.ice(MediaConnectionState.CONNECTED)
        connected.hangUp()

        val (call, reason) = connectedLog.ended.single()
        assertEquals(CallEndReason.HUNG_UP, reason)
        assertTrue("a completed call must carry its connect time", call.connectedAt != null)
        assertTrue(call.isOutgoing)

        // Hanging up before ICE ever connected is a failed call, not a completed
        // one, and the connect time is what tells them apart.
        val (never, neverLog) = manager()
        never.placeCall(peer, isVideo = false)
        never.hangUp()
        assertNull(neverLog.ended.single().first.connectedAt)
    }

    @Test
    fun `ice arriving before the answer is queued and applied afterwards`() = runTest {
        // The far side trickles candidates as soon as it creates its answer, and
        // those can overtake the ANSWER itself. Applying one with no remote
        // description throws, so they must be held.
        val transport = FakeTransport()
        val (calls, _) = manager(transport)
        val callId = calls.placeCall(peer, isVideo = false)!!

        calls.onSignal(signal(CallMessage.Type.ICE, callId, ice = "candidate-1"))
        calls.onSignal(signal(CallMessage.Type.ICE, callId, ice = "candidate-2"))
        assertTrue("candidates must not be applied yet", transport.applied.isEmpty())

        calls.onSignal(signal(CallMessage.Type.ANSWER, callId, sdp = "answer"))
        assertEquals(listOf("candidate-1", "candidate-2"), transport.applied)
    }

    @Test
    fun `hangup while ringing is recorded as missed, after connecting as hung up`() = runTest {
        val (ringing, _) = manager()
        ringing.onSignal(signal(CallMessage.Type.OFFER, "call-1", sdp = "m=audio"))
        assertEquals(CallEndReason.MISSED, ringing.onSignal(signal(CallMessage.Type.HANGUP, "call-1")))

        val (connected, _) = manager()
        connected.onSignal(signal(CallMessage.Type.OFFER, "call-2", sdp = "m=audio"))
        connected.accept()
        assertEquals(CallEndReason.HUNG_UP, connected.onSignal(signal(CallMessage.Type.HANGUP, "call-2")))
    }

    @Test
    fun `declining sends hangup and reports declined`() = runTest {
        val (calls, recorder) = manager()
        calls.onSignal(signal(CallMessage.Type.OFFER, "call-1", sdp = "m=audio"))
        assertEquals(CallEndReason.DECLINED, calls.hangUp())
        assertEquals(CallMessage.Type.HANGUP, recorder.types.last())
        assertFalse("HANGUP must be queued so it is never lost", recorder.sent.last().ephemeral)
        assertNull(calls.call.value)
    }

    @Test
    fun `a failed transport ends the call and releases devices`() = runTest {
        val transport = FakeTransport(failOnOffer = true)
        val (calls, _) = manager(transport)
        assertNull(calls.placeCall(peer, isVideo = false))
        assertTrue("the mic must be released on failure", transport.closed)
        assertNull(calls.call.value)
    }

    @Test
    fun `placing a call while already on one is refused`() = runTest {
        val (calls, _) = manager()
        calls.placeCall(peer, isVideo = false)
        assertNull(calls.placeCall("someone-else", isVideo = false))
    }

    private fun signal(
        type: CallMessage.Type,
        callId: String,
        from: String = peer,
        sdp: String = "",
        ice: String = "",
    ) = CallSignal(type, callId, sdp, ice, from, "", "", emptyList())
}
