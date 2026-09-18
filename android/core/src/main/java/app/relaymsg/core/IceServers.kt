package app.relaymsg.core

import app.relaymsg.net.TurnCredentials

/**
 * One ICE server.
 *
 * Deliberately not `org.webrtc.PeerConnection.IceServer`: the decisions below are
 * privacy decisions, they have to match iOS, and keeping them off the WebRTC
 * types is what lets them be unit-tested on the JVM.
 */
data class IceServerSpec(
    val urls: List<String>,
    val username: String? = null,
    val credential: String? = null,
)

/** How a peer connection should be configured for one call. */
data class IcePlan(
    val servers: List<IceServerSpec>,
    /**
     * TURN-only. Every candidate is relayed, so the peer never learns this
     * device's address — Private Call Mode.
     */
    val forceRelay: Boolean,
)

/**
 * Turns TURN credentials into an ICE configuration, matching iOS's
 * `freshIceServers` / `shouldForceRelay`.
 *
 * Two rules carry real weight here:
 *
 *  - **Only Relay's own servers are ever used.** No public STUN, ever. A
 *    third-party STUN server learns the caller's IP and that a call is starting,
 *    which is exactly what this app exists to avoid. With no TURN and no relay
 *    STUN the call falls back to host candidates and may simply not connect —
 *    that is the intended trade.
 *  - **Private Call Mode only forces relay when TURN actually exists.** With
 *    `forceRelay` and no TURN server a call gathers no candidates at all and can
 *    never connect, so the mode silently degrades instead of breaking calls.
 */
object IceServerPolicy {

    fun plan(credentials: TurnCredentials?, privateCallMode: Boolean): IcePlan {
        val servers = servers(credentials)
        return IcePlan(servers, forceRelay = privateCallMode && servers.anyTurn())
    }

    private fun servers(credentials: TurnCredentials?): List<IceServerSpec> {
        if (credentials == null) return emptyList()
        val turn = credentials.urls.filter(::isTurn)
        val stun = credentials.urls.filter { it.startsWith("stun:") }

        return buildList {
            // Credentials are per-URL-set, so all TURN urls share one entry.
            if (turn.isNotEmpty() &&
                credentials.username.isNotEmpty() &&
                credentials.credential.isNotEmpty()
            ) {
                add(IceServerSpec(turn, credentials.username, credentials.credential))
            }
            // The relay's own STUN, unauthenticated. Under forceRelay WebRTC
            // discards its candidates anyway; it matters when TURN is missing,
            // which is the case where it is the only thing that connects a call.
            if (stun.isNotEmpty()) add(IceServerSpec(stun))
        }
    }

    private fun isTurn(url: String) = url.startsWith("turn:") || url.startsWith("turns:")

    private fun List<IceServerSpec>.anyTurn() = any { spec -> spec.urls.any(::isTurn) }
}
