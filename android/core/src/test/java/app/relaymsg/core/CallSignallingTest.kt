package app.relaymsg.core

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
class CallSignallingTest {

    private val me = "6f1a2b3c-4d5e-4f60-8899-aabbccddeeff"
    private val peer = "11112222-3333-4444-5555-666677778888"

    /** Records what was sent, so ordering and ephemerality can be asserted. */
    private class Recorder {
        data class Sent(val peer: String, val content: Content, val ephemeral: Boolean)
        val sent = mutableListOf<Sent>()
        val types get() = sent.map { it.content.call.type }
    }

    private class FakeTransport(
        var offerSdp: String = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF\r\n",
        var failOnOffer: Boolean = false,
    ) : CallTransport {
        val applied = mutableListOf<String>()
        var closed = false
        override suspend fun createOffer(isVideo: Boolean): String {
            if (failOnOffer) throw IllegalStateException("no mic")
            return offerSdp
        }
        override suspend fun createAnswer(remoteSdp: String, isVideo: Boolean) = "answer-sdp"
        override suspend fun acceptAnswer(remoteSdp: String) {}
        override suspend fun addIceCandidate(candidateJson: String) { applied += candidateJson }
        override fun close() { closed = true }
    }

    private fun manager(
        transport: CallTransport = FakeTransport(),
        recorder: Recorder = Recorder(),
    ): Pair<CallManager, Recorder> =
        CallManager(me, 1, transport, { p, c, e -> recorder.sent += Recorder.Sent(p, c, e) }) to recorder

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
        val (calls, recorder) = manager()
        val callId = calls.placeCall(peer, isVideo = false)

        assertTrue(callId != null)
        assertEquals(listOf(CallMessage.Type.OFFER), recorder.types)
        assertFalse("OFFER must be queued, not ephemeral", recorder.sent.single().ephemeral)
        assertEquals(CallState.OUTGOING_RINGING, calls.call.value?.state)

        calls.onSignal(signal(CallMessage.Type.ANSWER, callId!!, sdp = "answer"))
        assertEquals(CallState.ACTIVE, calls.call.value?.state)
        assertTrue("connected time should be recorded", calls.call.value?.connectedAt != null)
    }

    @Test
    fun `incoming call auto-replies ringing then connects when accepted`() = runTest {
        val (calls, recorder) = manager()
        calls.onSignal(signal(CallMessage.Type.OFFER, "call-9", sdp = "m=audio"))

        assertEquals(CallState.INCOMING_RINGING, calls.call.value?.state)
        assertEquals(listOf(CallMessage.Type.RINGING), recorder.types)
        assertTrue("RINGING is ephemeral", recorder.sent.single().ephemeral)

        assertTrue(calls.accept())
        assertEquals(CallMessage.Type.ANSWER, recorder.types.last())
        assertEquals(CallState.ACTIVE, calls.call.value?.state)
    }

    @Test
    fun `a second incoming call gets busy and does not disturb the active one`() = runTest {
        val (calls, recorder) = manager()
        calls.onSignal(signal(CallMessage.Type.OFFER, "call-1", sdp = "m=audio"))
        calls.accept()
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
