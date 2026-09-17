package app.relaymsg.crypto

import com.google.protobuf.CodedOutputStream
import java.io.ByteArrayOutputStream
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.ecc.ECKeyPair
import org.signal.libsignal.protocol.ecc.ECPrivateKey
import org.signal.libsignal.protocol.state.impl.InMemorySignalProtocolStore

/**
 * Sealed-sender tests (PROTOCOL.md §1.6).
 *
 * The relay mints delivery certificates in Go (`server/internal/sealedsender/cert.go`).
 * That package is under `internal/`, so a vector generator in another module cannot
 * import it — instead this test **reproduces the exact protobuf field layout the Go
 * minter emits** and signs with libsignal's own XEd25519 (`ECPrivateKey.calculateSignature`,
 * the same scheme `signXEd25519` implements). libsignal then validates it.
 *
 * That proves the layout documented in PROTOCOL.md is the layout libsignal accepts.
 * It does NOT prove the live relay's certificates validate — that needs a real
 * `GET /v1/certificate/delivery` response and lands in Stage 4, where the client
 * can authenticate.
 */
class SealedSenderTest {

    private class Peer {
        val accountId: String = UUID.randomUUID().toString()
        val deviceId = 1
        val address = SignalProtocolAddress(accountId, deviceId)
        val store = InMemorySignalProtocolStore(IdentityKeyPair.generate(), (1..0x3FFF).random())
        val engine = CryptoEngine(store, address)

        fun publishBundle(): PeerPreKeyBundle {
            val p = engine.generatePreKeyPublication(1, 2, 100..101)
            return PeerPreKeyBundle(
                deviceId = deviceId,
                registrationId = p.registrationId,
                identityKey = p.identityKey,
                signedPreKey = p.signedPreKey,
                kyberPreKey = p.kyberPreKey,
                oneTimePreKey = p.oneTimePreKeys.first(),
            )
        }
    }

    /** A minted trust root and the certificates it vouches for. */
    private class TestAuthority {
        val trustRoot: ECKeyPair = ECKeyPair.generate()
        private val serverKey: ECKeyPair = ECKeyPair.generate()

        /** ServerCertificate: {1: keyId, 2: key(33)} signed by the trust root. */
        private val serverCertificate: ByteArray = run {
            val inner = encode {
                it.writeUInt32(1, 1)
                it.writeByteArray(2, serverKey.publicKey.serialize())
            }
            wrap(inner, trustRoot.privateKey.calculateSignature(inner))
        }

        /**
         * SenderCertificate. Fields in the order the Go minter appends them:
         * 2=device, 3=expires (fixed64, unix ms), 4=identityKey, 5=signer, 6=uuid.
         * Field 1 (e164) is omitted, exactly as the relay omits it.
         */
        fun senderCertificate(
            senderUuid: String,
            deviceId: Int,
            identityKey: ByteArray,
            expiresMs: Long,
        ): ByteArray {
            val inner = encode {
                it.writeUInt32(2, deviceId)
                it.writeFixed64(3, expiresMs)
                it.writeByteArray(4, identityKey)
                it.writeByteArray(5, serverCertificate)
                it.writeString(6, senderUuid)
            }
            return wrap(inner, serverKey.privateKey.calculateSignature(inner))
        }

        /** The shared outer envelope: {1: certificate, 2: signature}. */
        private fun wrap(certificate: ByteArray, signature: ByteArray) = encode {
            it.writeByteArray(1, certificate)
            it.writeByteArray(2, signature)
        }

        private fun encode(block: (CodedOutputStream) -> Unit): ByteArray {
            val out = ByteArrayOutputStream()
            val stream = CodedOutputStream.newInstance(out)
            block(stream)
            stream.flush()
            return out.toByteArray()
        }
    }

    private fun ECPrivateKey.sign(data: ByteArray) = calculateSignature(data)

    @Test
    fun `sealed message hides the sender on the wire but the recipient recovers it`() {
        val authority = TestAuthority()
        val alice = Peer()
        val bob = Peer()

        alice.engine.processPeerBundle(bob.publishBundle(), bob.address)

        val certificate = authority.senderCertificate(
            senderUuid = alice.accountId,
            deviceId = alice.deviceId,
            identityKey = alice.engine.identityKey(),
            expiresMs = System.currentTimeMillis() + 7 * 24 * 3600_000L,
        )

        val plaintext = "sealed hello".toByteArray()
        val sealed = alice.engine.sealedEncrypt(plaintext, bob.address, certificate)

        val result = bob.engine.sealedDecrypt(
            sealed = sealed,
            trustRoot = authority.trustRoot.publicKey.serialize(),
            timestampMs = System.currentTimeMillis(),
        )

        // The sender is recovered cryptographically, not from any server-stamped field.
        assertEquals(alice.accountId, result.senderAccountId)
        assertEquals(alice.deviceId, result.senderDeviceId)
        assertArrayEquals(plaintext, result.plaintext)
    }

    @Test
    fun `a certificate from an unknown trust root is rejected`() {
        val authority = TestAuthority()
        val alice = Peer()
        val bob = Peer()
        alice.engine.processPeerBundle(bob.publishBundle(), bob.address)

        val sealed = alice.engine.sealedEncrypt(
            "spoofed".toByteArray(),
            bob.address,
            authority.senderCertificate(
                alice.accountId, alice.deviceId, alice.engine.identityKey(),
                System.currentTimeMillis() + 3600_000L,
            ),
        )

        // Validating against a DIFFERENT trust root must fail: this is the whole
        // basis for trusting an unauthenticated delivery path.
        val impostorRoot = ECKeyPair.generate().publicKey.serialize()
        assertThrows(CryptoEngine.InvalidSenderCertificateException::class.java) {
            bob.engine.sealedDecrypt(sealed, impostorRoot, System.currentTimeMillis())
        }
    }

    @Test
    fun `an expired certificate is rejected at the validation timestamp`() {
        val authority = TestAuthority()
        val alice = Peer()
        val bob = Peer()
        alice.engine.processPeerBundle(bob.publishBundle(), bob.address)

        val now = System.currentTimeMillis()
        val sealed = alice.engine.sealedEncrypt(
            "stale".toByteArray(),
            bob.address,
            authority.senderCertificate(
                alice.accountId, alice.deviceId, alice.engine.identityKey(),
                expiresMs = now - 1000,
            ),
        )
        assertThrows(CryptoEngine.InvalidSenderCertificateException::class.java) {
            bob.engine.sealedDecrypt(sealed, authority.trustRoot.publicKey.serialize(), now)
        }
    }

    @Test
    fun `a certificate valid when the relay accepted the message still validates later`() {
        // Clients validate at Envelope.server_timestamp, not at receive time, so a
        // delayed delivery of a since-expired certificate still opens.
        val authority = TestAuthority()
        val alice = Peer()
        val bob = Peer()
        alice.engine.processPeerBundle(bob.publishBundle(), bob.address)

        val acceptedAt = System.currentTimeMillis()
        val sealed = alice.engine.sealedEncrypt(
            "delayed".toByteArray(),
            bob.address,
            authority.senderCertificate(
                alice.accountId, alice.deviceId, alice.engine.identityKey(),
                expiresMs = acceptedAt + 60_000,
            ),
        )

        val result = bob.engine.sealedDecrypt(
            sealed,
            authority.trustRoot.publicKey.serialize(),
            timestampMs = acceptedAt,
        )
        assertArrayEquals("delayed".toByteArray(), result.plaintext)
    }
}
