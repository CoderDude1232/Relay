package app.relaymsg.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** PKCE, pinned to RFC 7636 so a wrong challenge cannot reach a live sign-in. */
class PkceTest {

    @Test
    fun `the S256 challenge matches RFC 7636 appendix B`() {
        assertEquals(
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            PkcePair.challengeFor("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
        )
    }

    @Test
    fun `verifiers are base64url with no padding`() {
        val pair = PkcePair.generate()

        // '+' and '/' do not survive a URL, and Supabase rejects padding.
        assertFalse(pair.verifier.any { it == '+' || it == '/' || it == '=' })
        assertFalse(pair.challenge.any { it == '+' || it == '/' || it == '=' })
        // 32 bytes of entropy, which RFC 7636 puts at the top of its range.
        assertEquals(43, pair.verifier.length)
        assertEquals(43, pair.challenge.length)
    }

    @Test
    fun `every attempt gets a fresh verifier`() {
        // Reuse would let a code intercepted from an earlier attempt be redeemed.
        assertNotEquals(PkcePair.generate().verifier, PkcePair.generate().verifier)
    }

    @Test
    fun `the authorize url carries the challenge and an encoded redirect`() {
        val url = SupabaseAuth(projectUrl = "https://proj.supabase.co", anonKey = "k")
            .authorizeUrl("google", "app.relaymsg://auth-callback", "CHALLENGE")

        assertTrue(url.startsWith("https://proj.supabase.co/auth/v1/authorize?provider=google"))
        assertTrue(url.contains("code_challenge=CHALLENGE"))
        // Lowercase s256 is what iOS sends and what Supabase matches on.
        assertTrue(url.contains("code_challenge_method=s256"))
        // The scheme's "://" has to be escaped or it truncates the parameter.
        assertTrue(url.contains("redirect_to=app.relaymsg%3A%2F%2Fauth-callback"))
    }
}
