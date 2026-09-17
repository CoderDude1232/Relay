package app.relaymsg.crypto

import com.goterl.lazysodium.interfaces.Ristretto255
import com.google.gson.JsonParser
import java.util.Base64
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Blinded-discovery (OPRF) interop, against vectors from the Go side
 * (PROTOCOL.md §1.7).
 *
 * The test plays both halves: it blinds an identifier the way the client does,
 * evaluates it with the vector's secret scalar the way `POST /v1/directory/oprf`
 * does, unblinds, and derives the lookup token. That token must equal the one Go
 * computed directly from the plaintext identifier — which is exactly the property
 * discovery depends on, since the server indexes the direct form and the client
 * can only ever produce the blinded form.
 *
 * Caveat recorded honestly: the vectors come from an implementation transcribed
 * from `server/internal/oprf` rather than imported from it, because Go's
 * `internal` rule blocks importing across modules (see tools/genvectors).
 * It still cross-checks everything that differs between implementations —
 * ristretto255 encodings, the SHA-512 → from_hash mapping, the domain tags and
 * the hash input ordering. The end-to-end proof against the live relay's real
 * OPRF key comes in Stage 4, once the client can authenticate.
 *
 * Runs on the JVM via lazysodium-java; production uses lazysodium-android against
 * the same interface.
 */
class BlindedDiscoveryTest {

    private val sodium: Ristretto255.Native = TestSodium.lazySodium
    private val discovery = BlindedDiscovery(sodium)

    private class OprfVectors(
        val hashToGroupDomain: String,
        val tokenDomain: String,
        val keyScalar: ByteArray,
        val cases: List<Case>,
    ) {
        class Case(val identifier: String, val normalized: String, val token: ByteArray)
    }

    private fun loadVectors(): OprfVectors {
        val stream = checkNotNull(
            javaClass.classLoader?.getResourceAsStream("golden/crypto-vectors.json")
        ) { "golden/crypto-vectors.json missing — run tools/genvectors -kind=crypto" }
        val oprf = stream.reader().use { JsonParser.parseReader(it) }
            .asJsonObject.getAsJsonObject("oprf")
        val decoder = Base64.getDecoder()
        return OprfVectors(
            hashToGroupDomain = oprf.get("hashToGroupDomain").asString,
            tokenDomain = oprf.get("tokenDomain").asString,
            keyScalar = decoder.decode(oprf.get("keyScalar").asString),
            cases = oprf.getAsJsonArray("cases").map {
                val o = it.asJsonObject
                OprfVectors.Case(
                    identifier = o.get("identifier").asString,
                    normalized = o.get("normalized").asString,
                    token = decoder.decode(o.get("token").asString),
                )
            },
        )
    }

    /** Stands in for the relay: E = k·B. */
    private fun evaluate(keyScalar: ByteArray, blindedElement: ByteArray): ByteArray {
        val evaluated = ByteArray(32)
        assertTrue(
            "server-side scalar multiplication failed",
            sodium.cryptoScalarmultRistretto255(evaluated, keyScalar, blindedElement),
        )
        return evaluated
    }

    @Test
    fun `domain tags match the server's`() {
        // These strings are load-bearing: a typo yields tokens that match nothing
        // and silently makes every contact look unregistered.
        val vectors = loadVectors()
        assertEquals("Relay-OPRF-v1-h2g", vectors.hashToGroupDomain)
        assertEquals("Relay-OPRF-v1-token", vectors.tokenDomain)
    }

    @Test
    fun `normalization matches the server's`() {
        for (case in loadVectors().cases) {
            assertEquals(
                "normalization differs for '${case.identifier}'",
                case.normalized,
                String(BlindedDiscovery.normalize(case.identifier)),
            )
        }
    }

    @Test
    fun `blinded round-trip derives the token the server indexed`() {
        val vectors = loadVectors()
        assertTrue("no OPRF vectors loaded", vectors.cases.isNotEmpty())

        for (case in vectors.cases) {
            val blinded = discovery.blind(case.identifier)
            val evaluated = evaluate(vectors.keyScalar, blinded.element)
            val token = discovery.token(blinded, evaluated)

            assertArrayEquals(
                "token mismatch for '${case.identifier}'",
                case.token,
                token,
            )
        }
    }

    @Test
    fun `the same identifier blinds differently every time but yields one token`() {
        val vectors = loadVectors()
        val case = vectors.cases.first()

        val first = discovery.blind(case.identifier)
        val second = discovery.blind(case.identifier)

        // The value on the wire must differ between queries, or the relay could
        // correlate repeated lookups of the same contact.
        assertFalse(
            "blinded elements repeated — the blinding scalar is not random",
            first.element.contentEquals(second.element),
        )

        assertArrayEquals(
            discovery.token(first, evaluate(vectors.keyScalar, first.element)),
            discovery.token(second, evaluate(vectors.keyScalar, second.element)),
        )
    }

    @Test
    fun `identifiers differing only in case or padding resolve to one token`() {
        val vectors = loadVectors()
        val blinded = discovery.blind("  ALICE  ")
        val token = discovery.token(blinded, evaluate(vectors.keyScalar, blinded.element))

        // "alice" and "  Alice  " are separate vector cases that must collapse to
        // the same token — that collapse is what lets a user find a contact
        // regardless of how the address book capitalized them.
        val equivalent = vectors.cases.filter { it.normalized == "alice" }
        assertTrue("expected several spellings of 'alice' in the vectors", equivalent.size > 1)
        for (case in equivalent) {
            assertArrayEquals(
                "'${case.identifier}' derived a different token",
                case.token,
                token,
            )
        }
    }

    @Test
    fun `an evaluation of the wrong length is rejected`() {
        val blinded = discovery.blind("alice")
        val tooShort = ByteArray(31)
        val error = org.junit.Assert.assertThrows(BlindedDiscovery.OprfException::class.java) {
            discovery.token(blinded, tooShort)
        }
        assertTrue(error.message!!.contains("32 bytes"))
    }
}
