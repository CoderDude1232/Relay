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
 * The group-call mesh, which is where the interop risk in group calling lives.
 *
 * Runs on the JVM: who offers to whom, what is addressed to whom, and when the
 * call ends are all pure logic, and all of it has to match iOS.
 */
class GroupCallManagerTest {

    private val me = "6f1a2b3c-4d5e-4f60-8899-aabbccddeeff"
    private val alice = "11112222-3333-4444-5555-666677778888"
    private val bob = "99990000-1111-2222-3333-444455556666"
    private val groupId = "group-1"

    private class FakeTransport : CallTransport {
        val applied = mutableListOf<String>()
        var closed = false
        var listener: ((MediaConnectionState) -> Unit)? = null
        override fun onConnectionState(listener: (MediaConnectionState) -> Unit) {
            this.listener = listener
        }
        override suspend fun createOffer(isVideo: Boolean) = "offer-sdp"
        override suspend fun createAnswer(remoteSdp: String, isVideo: Boolean) = "answer-sdp"
        override suspend fun acceptAnswer(remoteSdp: String) {}
        override suspend fun addIceCandidate(candidateJson: String) { applied += candidateJson }
        override fun setMicrophoneEnabled(enabled: Boolean) {}
        override fun audioRoutes() = emptyList<AudioRoute>()
        override fun selectAudioRoute(route: AudioRoute) {}
        override fun switchCamera() {}
        override fun setCameraEnabled(enabled: Boolean) {}
        override fun close() { closed = true }
    }

    private class Recorder {
        data class Sent(val peer: String, val content: Content, val ephemeral: Boolean)
        val sent = mutableListOf<Sent>()
        fun to(peer: String) = sent.filter { it.peer == peer }.map { it.content.call.type }
    }

    private val transports = mutableMapOf<String, FakeTransport>()

    private fun manager(recorder: Recorder = Recorder()): Pair<GroupCallManager, Recorder> =
        GroupCallManager(
            ownAccount = me,
            ownDevice = 1,
            newTransport = { peer -> transports.getOrPut(peer) { FakeTransport() } },
            send = { p, c, e -> recorder.sent += Recorder.Sent(p, c, e) },
            nameOf = { it.take(5) },
            groupNameOf = { "Test group" },
        ) to recorder

    private fun signal(
        type: CallMessage.Type,
        callId: String,
        from: String,
        sdp: String = "",
        ice: String = "",
        target: String = "",
        group: String = groupId,
        participants: List<String> = emptyList(),
    ) = CallSignal(type, callId, sdp, ice, from, group, target, participants)

    // ---------------------------------------------------------------- ringing

    @Test
    fun `starting a call rings every other member and never ourselves`() = runTest {
        val (calls, recorder) = manager()
        val callId = calls.start(groupId, "Test group", listOf(me, alice, bob), isVideo = false)!!

        assertEquals(setOf(alice, bob), recorder.sent.map { it.peer }.toSet())
        assertTrue(recorder.sent.all { it.content.call.type == CallMessage.Type.GROUP_RING })
        // Durable: a member whose phone is asleep must still learn of the call.
        assertTrue(recorder.sent.none { it.ephemeral })
        assertEquals(callId, recorder.sent.first().content.call.callId)
        assertEquals(groupId, recorder.sent.first().content.call.groupId)
        assertFalse(calls.call.value!!.isRinging)
    }

    @Test
    fun `a ring is ignored while already in a call rather than answered with busy`() = runTest {
        val (calls, recorder) = manager()
        calls.start(groupId, "Test group", listOf(me, alice), isVideo = false)
        recorder.sent.clear()

        calls.onSignal(signal(CallMessage.Type.GROUP_RING, "other-call", from = bob))

        // BUSY would end the *caller's* call, and a group ring is a broadcast:
        // one member being busy says nothing about the call as a whole.
        assertTrue(recorder.sent.isEmpty())
        assertEquals(groupId, calls.call.value?.groupId)
    }

    @Test
    fun `joining tells the caller and everyone listed, but not ourselves`() = runTest {
        val (calls, recorder) = manager()
        calls.onSignal(
            signal(
                CallMessage.Type.GROUP_RING, "call-1", from = alice,
                participants = listOf(me, bob),
            ),
        )
        assertTrue(calls.call.value!!.isRinging)
        recorder.sent.clear()

        calls.join()

        assertEquals(setOf(alice, bob), recorder.sent.map { it.peer }.toSet())
        assertTrue(recorder.sent.all { it.content.call.type == CallMessage.Type.GROUP_JOIN })
        assertFalse(calls.call.value!!.isRinging)
    }

    @Test
    fun `declining is silent`() = runTest {
        val (calls, recorder) = manager()
        calls.onSignal(signal(CallMessage.Type.GROUP_RING, "call-1", from = alice))
        recorder.sent.clear()

        calls.decline()

        assertNull(calls.call.value)
        assertTrue("iOS declineGroupCall sends nothing", recorder.sent.isEmpty())
    }

    // ------------------------------------------------------------------- mesh

    @Test
    fun `whoever is already in the call offers to whoever joins`() = runTest {
        // This one rule builds the whole mesh: a joiner sends one JOIN and
        // everybody present answers with an OFFER addressed to them.
        val (calls, recorder) = manager()
        val callId = calls.start(groupId, "Test group", listOf(me, alice, bob), isVideo = false)!!
        recorder.sent.clear()

        calls.onSignal(signal(CallMessage.Type.GROUP_JOIN, callId, from = alice))

        val offer = recorder.sent.single()
        assertEquals(alice, offer.peer)
        assertEquals(CallMessage.Type.OFFER, offer.content.call.type)
        // Every member receives every signal, so the leg has to say who it is for.
        assertEquals(alice, offer.content.call.targetAccount)
        assertEquals(groupId, offer.content.call.groupId)
        assertEquals(listOf(alice), calls.call.value!!.peers.map { it.account })

        // A second JOIN from the same member must not build a second leg.
        recorder.sent.clear()
        calls.onSignal(signal(CallMessage.Type.GROUP_JOIN, callId, from = alice))
        assertTrue(recorder.sent.isEmpty())
    }

    @Test
    fun `a mesh offer addressed to someone else is ignored`() = runTest {
        val (calls, recorder) = manager()
        val callId = calls.start(groupId, "Test group", listOf(me, alice, bob), isVideo = false)!!
        recorder.sent.clear()

        // Alice offering to Bob reaches us too; answering it would put us in a
        // call leg neither of them asked for.
        calls.onSignal(signal(CallMessage.Type.OFFER, callId, from = alice, target = bob, sdp = "s"))

        assertTrue(recorder.sent.isEmpty())
        assertTrue(calls.call.value!!.peers.isEmpty())
    }

    @Test
    fun `an offer addressed to us is answered to the sender`() = runTest {
        val (calls, recorder) = manager()
        calls.onSignal(
            signal(CallMessage.Type.GROUP_RING, "call-1", from = alice, participants = listOf(me)),
        )
        calls.join()
        recorder.sent.clear()

        calls.onSignal(signal(CallMessage.Type.OFFER, "call-1", from = alice, target = me, sdp = "s"))

        val answer = recorder.sent.single()
        assertEquals(alice, answer.peer)
        assertEquals(CallMessage.Type.ANSWER, answer.content.call.type)
        assertEquals(alice, answer.content.call.targetAccount)
    }

    @Test
    fun `candidates that beat their leg are queued per peer`() = runTest {
        val (calls, _) = manager()
        val callId = calls.start(groupId, "Test group", listOf(me, alice, bob), isVideo = false)!!

        // Alice's candidates arrive before we have built a leg to her at all.
        calls.onSignal(signal(CallMessage.Type.ICE, callId, from = alice, ice = "cand-a1"))
        calls.onSignal(signal(CallMessage.Type.ICE, callId, from = bob, ice = "cand-b1"))
        calls.onSignal(signal(CallMessage.Type.GROUP_JOIN, callId, from = alice))

        // Only Alice's leg exists, so only Alice's candidates are applied — one
        // slow member must not hold up anyone else's.
        assertEquals(listOf("cand-a1"), transports[alice]?.applied)
        assertNull(transports[bob])
    }

    // -------------------------------------------------------------- departures

    @Test
    fun `a member leaving drops only that member`() = runTest {
        val (calls, _) = manager()
        val callId = calls.start(groupId, "Test group", listOf(me, alice, bob), isVideo = false)!!
        calls.onSignal(signal(CallMessage.Type.GROUP_JOIN, callId, from = alice))
        calls.onSignal(signal(CallMessage.Type.GROUP_JOIN, callId, from = bob))
        assertEquals(2, calls.call.value!!.peers.size)

        calls.onSignal(signal(CallMessage.Type.GROUP_LEAVE, callId, from = alice))

        assertEquals(listOf(bob), calls.call.value!!.peers.map { it.account })
        assertTrue("the departed member's leg must be torn down", transports[alice]!!.closed)
        assertFalse(transports[bob]!!.closed)
    }

    @Test
    fun `the last member leaving ends the call`() = runTest {
        val (calls, _) = manager()
        val callId = calls.start(groupId, "Test group", listOf(me, alice), isVideo = false)!!
        calls.onSignal(signal(CallMessage.Type.GROUP_JOIN, callId, from = alice))

        // A hangup from a group member means they left, not that the call is
        // over — but with nobody else there, it is over.
        calls.onSignal(signal(CallMessage.Type.HANGUP, callId, from = alice))

        assertNull(calls.call.value)
    }

    @Test
    fun `leaving tells everyone still connected`() = runTest {
        val (calls, recorder) = manager()
        val callId = calls.start(groupId, "Test group", listOf(me, alice, bob), isVideo = false)!!
        calls.onSignal(signal(CallMessage.Type.GROUP_JOIN, callId, from = alice))
        calls.onSignal(signal(CallMessage.Type.GROUP_JOIN, callId, from = bob))
        recorder.sent.clear()

        calls.leave()

        assertEquals(listOf(CallMessage.Type.GROUP_LEAVE), recorder.to(alice))
        assertEquals(listOf(CallMessage.Type.GROUP_LEAVE), recorder.to(bob))
        assertNull(calls.call.value)
        assertTrue(transports.values.all { it.closed })
    }

    @Test
    fun `signals for a different call id are ignored`() = runTest {
        val (calls, recorder) = manager()
        calls.start(groupId, "Test group", listOf(me, alice), isVideo = false)
        recorder.sent.clear()

        calls.onSignal(signal(CallMessage.Type.GROUP_JOIN, "a-different-call", from = alice))

        assertTrue(recorder.sent.isEmpty())
        assertTrue(calls.call.value!!.peers.isEmpty())
    }

    // --------------------------------------------------------------- routing

    @Test
    fun `routing is by group id, not by signal type`() {
        // A mesh leg is a plain OFFER; only group_id separates it from a 1:1
        // call, which is exactly the rule iOS uses.
        assertTrue(CallSignalling.isGroupSignal(signal(CallMessage.Type.OFFER, "c", from = alice)))
        assertFalse(
            CallSignalling.isGroupSignal(
                signal(CallMessage.Type.OFFER, "c", from = alice, group = ""),
            ),
        )
        // The group-only types carry no group_id of their own in some paths, so
        // they must be recognised by type as well.
        assertTrue(
            CallSignalling.isGroupSignal(
                signal(CallMessage.Type.GROUP_RING, "c", from = alice, group = ""),
            ),
        )
    }
}
