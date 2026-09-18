package app.relaymsg.core

import app.relaymsg.net.TurnCredentials
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The ICE configuration rules, which are privacy rules as much as connectivity
 * ones — see [IceServerPolicy].
 */
class IceServerPolicyTest {

    private fun creds(vararg urls: String, user: String = "1757000000:relay", cred: String = "sig") =
        TurnCredentials(urls.toList(), user, cred, ttl = 3600)

    @Test
    fun `turn urls share one credentialled entry and stun gets its own`() {
        val plan = IceServerPolicy.plan(
            creds("turn:turn.relaymsg.app:3478", "turns:turn.relaymsg.app:5349", "stun:turn.relaymsg.app:3478"),
            privateCallMode = false,
        )

        assertEquals(2, plan.servers.size)
        assertEquals(2, plan.servers[0].urls.size)
        assertEquals("1757000000:relay", plan.servers[0].username)
        // STUN is unauthenticated; sending credentials there would be pointless.
        assertEquals(listOf("stun:turn.relaymsg.app:3478"), plan.servers[1].urls)
        assertEquals(null, plan.servers[1].username)
    }

    @Test
    fun `private call mode forces relay only when there is a turn server`() {
        val withTurn = IceServerPolicy.plan(creds("turn:turn.relaymsg.app:3478"), privateCallMode = true)
        assertTrue(withTurn.forceRelay)

        // Forcing relay with no TURN gathers no candidates at all, so the mode
        // degrades rather than making calls impossible.
        val stunOnly = IceServerPolicy.plan(creds("stun:turn.relaymsg.app:3478"), privateCallMode = true)
        assertFalse(stunOnly.forceRelay)

        assertFalse(IceServerPolicy.plan(null, privateCallMode = true).forceRelay)
    }

    @Test
    fun `no turn credentials means no servers at all, never a public fallback`() {
        // The whole point: a third-party STUN server would learn the caller's IP
        // and that a call is starting. An empty list is the correct answer.
        assertEquals(emptyList<IceServerSpec>(), IceServerPolicy.plan(null, privateCallMode = true).servers)
    }

    @Test
    fun `turn without usable credentials is dropped rather than sent unauthenticated`() {
        val plan = IceServerPolicy.plan(
            creds("turn:turn.relaymsg.app:3478", "stun:turn.relaymsg.app:3478", user = "", cred = ""),
            privateCallMode = true,
        )

        assertEquals(1, plan.servers.size)
        assertEquals(listOf("stun:turn.relaymsg.app:3478"), plan.servers[0].urls)
        // And with the TURN entry gone, relay must not be forced.
        assertFalse(plan.forceRelay)
    }
}
