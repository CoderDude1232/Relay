package app.relaymsg.net

import com.google.gson.JsonParser
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.util.Base64
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `Relay-Sig` request-authentication interop (PROTOCOL.md §2.1).
 *
 * Android is the **first** client to implement this scheme — iOS still sends
 * HTTP Basic — so there is no second implementation to compare against in the
 * app. These vectors come from Go instead, built with the same `ecdsa.SignASN1`
 * the server verifies with, which pins the three things that can silently drift:
 * the canonical string, the digest, and the signature encoding.
 *
 * The auth layer deliberately uses `java.util.Base64` rather than
 * `android.util.Base64` — it exists from API 26, which is our minSdk, and it
 * keeps this code plain JVM so it needs neither a device nor Robolectric.
 */
class RelaySigTest {

    private class SigCase(
        val method: String,
        val path: String,
        val timestampMs: Long,
        val nonce: String,
        val canonical: String,
        val digest: ByteArray,
        val signature: ByteArray,
    )

    private fun load(): Pair<ByteArray, List<SigCase>> {
        val stream = checkNotNull(
            javaClass.classLoader?.getResourceAsStream("golden/crypto-vectors.json"),
        ) { "golden/crypto-vectors.json missing — run tools/genvectors -kind=crypto" }
        val root = stream.reader().use { JsonParser.parseReader(it) }
            .asJsonObject.getAsJsonObject("relaySig")
        val decoder = Base64.getDecoder()
        val cases = root.getAsJsonArray("cases").map {
            val o = it.asJsonObject
            SigCase(
                method = o.get("method").asString,
                path = o.get("path").asString,
                timestampMs = o.get("timestampMs").asLong,
                nonce = o.get("nonce").asString,
                canonical = o.get("canonical").asString,
                digest = decoder.decode(o.get("digest").asString),
                signature = decoder.decode(o.get("signature").asString),
            )
        }
        return decoder.decode(root.get("publicKey").asString) to cases
    }

    @Test
    fun `canonical string matches the server's byte for byte`() {
        val (_, cases) = load()
        assertTrue("no Relay-Sig vectors loaded", cases.isNotEmpty())
        for (case in cases) {
            assertEquals(
                "canonical string differs for ${case.method} ${case.path}",
                case.canonical,
                RelayAuthenticator.canonicalString(
                    case.method,
                    case.path,
                    case.timestampMs,
                    case.nonce,
                ),
            )
        }
    }

    @Test
    fun `canonical string is exactly four newline-separated fields`() {
        val canonical = RelayAuthenticator.canonicalString("GET", "/v1/queue", 1L, "abc")
        assertEquals("GET\n/v1/queue\n1\nabc", canonical)
        assertEquals(3, canonical.count { it == '\n' })
    }

    @Test
    fun `signed path excludes the query string`() {
        // The server signs r.URL.Path. Including "?device=3" here would produce a
        // signature that never validates, with only a bare 401 to debug.
        val (_, cases) = load()
        val keysCase = cases.single { it.path.startsWith("/v1/keys/") }
        assertTrue("vector path unexpectedly carries a query", !keysCase.path.contains("?"))
        assertEquals(
            keysCase.canonical,
            RelayAuthenticator.canonicalString(
                keysCase.method,
                keysCase.path,
                keysCase.timestampMs,
                keysCase.nonce,
            ),
        )
    }

    @Test
    fun `digest is sha-256 of the canonical string`() {
        val (_, cases) = load()
        for (case in cases) {
            val digest = MessageDigest.getInstance("SHA-256").digest(case.canonical.toByteArray())
            assertArrayEquals("digest differs for ${case.method} ${case.path}", case.digest, digest)
        }
    }

    @Test
    fun `go-produced signatures verify against the published public key`() {
        // Proves we can parse the uncompressed point the server stores and that
        // the DER signature encoding matches what ecdsa.SignASN1 emits.
        val (publicKey, cases) = load()
        val key = publicKey.toP256PublicKey()
        for (case in cases) {
            val verifier = Signature.getInstance("SHA256withECDSA").apply {
                initVerify(key)
                update(case.canonical.toByteArray())
            }
            assertTrue(
                "Go signature failed to verify for ${case.method} ${case.path}",
                verifier.verify(case.signature),
            )
        }
    }

    @Test
    fun `our signatures use the encoding the server verifies`() {
        // The reverse direction: sign as the client does and confirm the output is
        // ASN.1/DER over SHA-256, which is what ecdsa.VerifyASN1 accepts.
        val pair = KeyPairGenerator.getInstance("EC").apply {
            initialize(ECGenParameterSpec("secp256r1"))
        }.generateKeyPair()

        val signer = object : RequestSigner {
            override fun sign(message: ByteArray): ByteArray =
                Signature.getInstance("SHA256withECDSA").run {
                    initSign(pair.private)
                    update(message)
                    sign()
                }

            override fun publicKey(): ByteArray = ByteArray(65).also { it[0] = 0x04 }
        }

        val auth = RelayAuthenticator(
            RelayCredentials("6f1a2b3c-4d5e-4f60-8899-aabbccddeeff", 1, "unused"),
            signer,
        )
        val headers = auth.headers("GET", "/v1/queue")

        val authorization = requireNotNull(headers["Authorization"])
        assertTrue(authorization.startsWith("Relay-Sig "))
        val timestamp = requireNotNull(headers[RelayAuthenticator.HEADER_TIMESTAMP]).toLong()
        val nonce = requireNotNull(headers[RelayAuthenticator.HEADER_NONCE])
        val signature = Base64.getDecoder().decode(authorization.substringAfterLast(':'))

        val canonical = RelayAuthenticator.canonicalString("GET", "/v1/queue", timestamp, nonce)
        val verifier = Signature.getInstance("SHA256withECDSA").apply {
            initVerify(pair.public)
            update(canonical.toByteArray())
        }
        assertTrue("client signature did not verify", verifier.verify(signature))

        // The credential half the server parses as <accountId>.<deviceId>.
        assertEquals(
            "6f1a2b3c-4d5e-4f60-8899-aabbccddeeff.1",
            authorization.removePrefix("Relay-Sig ").substringBeforeLast(':'),
        )
    }

    @Test
    fun `each request gets a fresh nonce`() {
        // The server keeps a replay cache keyed by nonce; a repeated nonce inside
        // the 5-minute window is rejected as a replay.
        val pair = KeyPairGenerator.getInstance("EC").apply {
            initialize(ECGenParameterSpec("secp256r1"))
        }.generateKeyPair()
        val auth = RelayAuthenticator(
            RelayCredentials("acct", 1, "pw"),
            object : RequestSigner {
                override fun sign(message: ByteArray): ByteArray =
                    Signature.getInstance("SHA256withECDSA").run {
                        initSign(pair.private); update(message); sign()
                    }
                override fun publicKey() = ByteArray(65)
            },
        )
        val nonces = (1..20).map { auth.headers("GET", "/v1/queue")[RelayAuthenticator.HEADER_NONCE] }
        assertEquals("nonces repeated", nonces.size, nonces.toSet().size)
    }

    @Test
    fun `basic auth is the documented bootstrap form`() {
        val auth = RelayAuthenticator(RelayCredentials("acct-1", 3, "hunter22"), signer = null)
        val header = requireNotNull(auth.basicHeaders()["Authorization"])
        assertTrue(header.startsWith("Basic "))
        val decoded = String(Base64.getDecoder().decode(header.removePrefix("Basic ")))
        assertEquals("acct-1.3:hunter22", decoded)
    }

    /** Parses `0x04 ‖ X ‖ Y` — the only encoding the server's elliptic.Unmarshal accepts. */
    private fun ByteArray.toP256PublicKey(): java.security.PublicKey {
        assertEquals(65, size)
        assertEquals(0x04.toByte(), this[0])
        val x = java.math.BigInteger(1, copyOfRange(1, 33))
        val y = java.math.BigInteger(1, copyOfRange(33, 65))
        val params = (
            KeyPairGenerator.getInstance("EC").apply {
                initialize(ECGenParameterSpec("secp256r1"))
            }.generateKeyPair().public as java.security.interfaces.ECPublicKey
            ).params
        return KeyFactory.getInstance("EC")
            .generatePublic(ECPublicKeySpec(ECPoint(x, y), params))
    }
}
