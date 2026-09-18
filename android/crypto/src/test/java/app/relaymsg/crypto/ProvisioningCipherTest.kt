package app.relaymsg.crypto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.signal.libsignal.protocol.ecc.ECPrivateKey
import org.signal.libsignal.protocol.ecc.ECPublicKey

/**
 * Device-linking crypto.
 *
 * This is the one piece of Android code whose output an iPhone has to open, and
 * the failure mode is silent — a wrong key length or a wrong HKDF salt produces
 * a blob that simply never decrypts. So the primitives are pinned to published
 * vectors rather than only round-tripped against themselves.
 */
class ProvisioningCipherTest {

    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    // -------------------------------------------------------------- primitives

    @Test
    fun `hkdf matches RFC 5869 test case 1`() {
        val okm = Hkdf.derive(
            ikm = hex("0b".repeat(22)),
            salt = hex("000102030405060708090a0b0c"),
            info = hex("f0f1f2f3f4f5f6f7f8f9"),
            length = 42,
        )
        assertArrayEquals(
            hex(
                "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf" +
                    "34007208d5b887185865",
            ),
            okm,
        )
    }

    @Test
    fun `hkdf with an empty salt substitutes zeros, as CryptoKit does`() {
        // RFC 5869 test case 3: zero-length salt and info. This is the case the
        // provisioning cipher actually uses, and the one implementations differ
        // on -- some pass an empty HMAC key instead of HashLen zero bytes.
        val okm = Hkdf.derive(
            ikm = hex("0b".repeat(22)),
            salt = ByteArray(0),
            info = ByteArray(0),
            length = 42,
        )
        assertArrayEquals(
            hex(
                "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d" +
                    "9d201395faa4b61a96c8",
            ),
            okm,
        )
        assertArrayEquals(okm, Hkdf.derive(hex("0b".repeat(22)), ByteArray(32), ByteArray(0), 42))
    }

    @Test
    fun `libsignal agreement is plain X25519, matching CryptoKit`() {
        // RFC 7748 6.1. If libsignal ever wrapped or salted the agreement, the
        // iOS side would derive a different key and nothing would decrypt.
        val alice = ECPrivateKey(hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))
        val bobPublic = ECPublicKey(
            byteArrayOf(0x05) +
                hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"),
        )

        assertArrayEquals(
            hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"),
            alice.calculateAgreement(bobPublic),
        )
    }

    // ------------------------------------------------------------------ format

    @Test
    fun `the ephemeral public key is raw 32 bytes, not libsignal's 33`() {
        // The QR carries CryptoKit's rawRepresentation. Shipping libsignal's
        // serialize() would add a 0x05 type byte and iOS could not read it.
        assertEquals(32, ProvisioningCipher.EphemeralKeyPair.generate().publicKey.size)
    }

    @Test
    fun `the blob is version, sender key, then an AES-GCM box`() {
        val device = ProvisioningCipher.EphemeralKeyPair.generate()
        val payload = "provisioning payload".toByteArray()
        val blob = ProvisioningCipher.seal(payload, device.publicKey)

        assertEquals(1, blob[0].toInt())
        // 1 version + 32 sender key + 12 nonce + payload + 16 tag.
        assertEquals(1 + 32 + 12 + payload.size + 16, blob.size)
        // The sender's key must not be the recipient's.
        assertNotEquals(
            device.publicKey.toList(),
            blob.copyOfRange(1, 33).toList(),
        )
    }

    @Test
    fun `a sealed payload opens on the device it was addressed to`() {
        val device = ProvisioningCipher.EphemeralKeyPair.generate()
        val payload = """{"version":1,"accountId":"abc"}""".toByteArray()

        val opened = ProvisioningCipher.open(
            ProvisioningCipher.seal(payload, device.publicKey),
            device,
        )
        assertArrayEquals(payload, opened)
    }

    @Test
    fun `a payload addressed to another device does not open`() {
        val intended = ProvisioningCipher.EphemeralKeyPair.generate()
        val eavesdropper = ProvisioningCipher.EphemeralKeyPair.generate()
        val blob = ProvisioningCipher.seal("secret".toByteArray(), intended.publicKey)

        // GCM authentication is what stops a session id being enough to steal an
        // account: the blob is bound to the key shown in the QR.
        assertThrows(Exception::class.java) { ProvisioningCipher.open(blob, eavesdropper) }
    }

    @Test
    fun `a tampered blob does not open`() {
        val device = ProvisioningCipher.EphemeralKeyPair.generate()
        val blob = ProvisioningCipher.seal("secret".toByteArray(), device.publicKey)
        blob[blob.size - 1] = (blob[blob.size - 1] + 1).toByte()

        assertThrows(Exception::class.java) { ProvisioningCipher.open(blob, device) }
    }

    @Test
    fun `an unknown version is refused rather than guessed at`() {
        val device = ProvisioningCipher.EphemeralKeyPair.generate()
        val blob = ProvisioningCipher.seal("secret".toByteArray(), device.publicKey)
        blob[0] = 0x02

        val error = assertThrows(ProvisioningCipherException::class.java) {
            ProvisioningCipher.open(blob, device)
        }
        assertTrue(error.message!!.contains("version"))
    }
}
