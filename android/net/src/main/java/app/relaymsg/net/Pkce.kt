package app.relaymsg.net

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/**
 * PKCE (RFC 7636) for the Supabase OAuth hand-off.
 *
 * The app cannot keep a client secret — anything shipped in an APK is public —
 * so the code is bound to this attempt instead: the challenge travels in the
 * authorize URL, the verifier never leaves the process, and only the two
 * together redeem a session. Without it, any app that registered the same
 * redirect scheme could take the code and sign in as the user.
 *
 * Base64**url** without padding throughout; the plain alphabet's `+` and `/`
 * do not survive a URL, and iOS strips padding the same way.
 */
data class PkcePair(val verifier: String, val challenge: String) {
    companion object {
        fun generate(): PkcePair {
            val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
            val verifier = encode(bytes)
            return PkcePair(verifier, challengeFor(verifier))
        }

        /**
         * The S256 challenge for a verifier.
         *
         * Hashes the verifier's **ASCII characters**, not the bytes it decodes
         * to — a natural mistake that produces a challenge the server rejects
         * with a generic error.
         */
        fun challengeFor(verifier: String): String =
            encode(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII)))

        private fun encode(bytes: ByteArray): String =
            Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }
}
