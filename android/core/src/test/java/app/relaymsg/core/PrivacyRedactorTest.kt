package app.relaymsg.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Log redaction.
 *
 * Tested by asserting the secret is *absent* rather than that the output has
 * some exact shape: what matters is that nothing sensitive survives, and a test
 * pinned to the exact replacement would pass while a new pattern leaked.
 */
class PrivacyRedactorTest {

    @Test
    fun `authorization headers do not survive`() {
        val cleaned = PrivacyRedactor.redact("Authorization: Bearer abcdef123456789 rest")
        assertFalse(cleaned.contains("abcdef123456789"))
    }

    @Test
    fun `named secrets do not survive in either spelling`() {
        listOf(
            "token=secretvalue",
            """password: "hunter22"""",
            "credential='s3cr3t'",
            "nonce=AAAABBBBCCCC",
        ).forEach { input ->
            val cleaned = PrivacyRedactor.redact(input)
            listOf("secretvalue", "hunter22", "s3cr3t", "AAAABBBBCCCC").forEach { secret ->
                assertFalse("$secret survived in '$cleaned'", cleaned.contains(secret))
            }
        }
    }

    @Test
    fun `account ids do not survive`() {
        val account = "123E4567-E89B-12D3-A456-426614174000"
        assertFalse(PrivacyRedactor.redact("sending to $account").contains(account))
    }

    @Test
    fun `key material and ciphertext do not survive`() {
        // A 32-hex digest and a long base64 run: identity keys, digests,
        // sealed-sender certificates.
        val hex = "a".repeat(64)
        val base64 = "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9w"
        assertFalse(PrivacyRedactor.redact("digest $hex").contains(hex))
        assertFalse(PrivacyRedactor.redact("blob $base64").contains(base64))
    }

    @Test
    fun `ordinary text is left alone`() {
        // Over-redaction makes logs useless, which is its own failure.
        val message = "failed to send message to conversation after 3 attempts"
        assertEquals(message, PrivacyRedactor.redact(message))
    }

    @Test
    fun `a throwable keeps its type and loses its secrets`() {
        val error = IllegalStateException("bad token=abcdefghijklmnop")
        val cleaned = PrivacyRedactor.redact(error)

        // The class name is the useful half and never carries a secret.
        assertTrue(cleaned.startsWith("IllegalStateException"))
        assertFalse(cleaned.contains("abcdefghijklmnop"))
    }
}
