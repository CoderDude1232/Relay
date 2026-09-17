package app.relaymsg.crypto

import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.state.impl.InMemorySignalProtocolStore

/**
 * Stage 2 crypto-core tests.
 *
 * These run on the JVM: libsignal's jar bundles a desktop dylib, so no emulator
 * is needed. Every parameter asserted here is one `android/PROTOCOL.md` §1 pins
 * as required for interop with the iOS client.
 */
class CryptoEngineTest {

    /** A test peer: its own engine, store and relay-style account id. */
    private class Peer(val deviceId: Int = 1) {
        val accountId: String = UUID.randomUUID().toString()
        val address = SignalProtocolAddress(accountId, deviceId)
        val registrationId = (1..0x3FFF).random()
        val store = InMemorySignalProtocolStore(IdentityKeyPair.generate(), registrationId)
        val engine = CryptoEngine(store, address)

        /** Publishes a bundle the way `PUT /v1/keys` would, and returns the public half. */
        fun publish(oneTimeIds: IntRange = 100..104): PreKeyPublication =
            engine.generatePreKeyPublication(
                signedPreKeyId = 1,
                kyberPreKeyId = 2,
                oneTimePreKeyIds = oneTimeIds,
            )

        /** The bundle a peer would fetch from `GET /v1/keys/{account}`. */
        fun bundleFor(publication: PreKeyPublication, useOneTime: Boolean = true) =
            PeerPreKeyBundle(
                deviceId = deviceId,
                registrationId = publication.registrationId,
                identityKey = publication.identityKey,
                signedPreKey = publication.signedPreKey,
                kyberPreKey = publication.kyberPreKey,
                oneTimePreKey = if (useOneTime) publication.oneTimePreKeys.first() else null,
            )
    }

    // ------------------------------------------------------------- identity

    @Test
    fun `identity key is 33-byte djb encoded`() {
        val peer = Peer()
        val key = peer.engine.identityKey()
        assertEquals(33, key.size)
        assertEquals(0x05.toByte(), key[0])
    }

    @Test
    fun `registration id round-trips through the engine`() {
        val peer = Peer()
        assertEquals(peer.registrationId, peer.engine.registrationId())
        // PROTOCOL.md §1.2: generated in 1..0x3FFF.
        assertTrue(peer.engine.registrationId() in 1..0x3FFF)
    }

    // ------------------------------------------------------------- pre-keys

    @Test
    fun `publication carries a mandatory kyber prekey and signed prekey`() {
        val publication = Peer().publish(oneTimeIds = 100..102)

        // PQXDH: the Kyber pre-key is not optional (PROTOCOL.md §1.3).
        assertTrue(publication.kyberPreKey.publicKey.isNotEmpty())
        assertTrue(publication.kyberPreKey.signature.isNotEmpty())
        assertTrue(publication.signedPreKey.publicKey.isNotEmpty())
        assertTrue(publication.signedPreKey.signature.isNotEmpty())
        assertEquals(3, publication.oneTimePreKeys.size)
        assertEquals(listOf(100, 101, 102), publication.oneTimePreKeys.map { it.id })
        // Signed pre-key is a 33-byte curve point; Kyber is much larger.
        assertEquals(33, publication.signedPreKey.publicKey.size)
        assertTrue(publication.kyberPreKey.publicKey.size > 1000)
    }

    @Test
    fun `an empty one-time range republishes only the signed and kyber prekeys`() {
        // What the client does on every launch so the relay can never serve a
        // signed pre-key whose private half was lost to a reinstall.
        val publication = Peer().engine.generatePreKeyPublication(7, 8, IntRange.EMPTY)
        assertTrue(publication.oneTimePreKeys.isEmpty())
        assertEquals(7, publication.signedPreKey.id)
        assertEquals(8, publication.kyberPreKey.id)
    }

    // ------------------------------------------------------- PQXDH + ratchet

    @Test
    fun `pqxdh session establishes and the ratchet round-trips both ways`() {
        val alice = Peer()
        val bob = Peer()
        val bobPublication = bob.publish()

        assertFalse(alice.engine.hasSession(bob.address))
        alice.engine.processPeerBundle(bob.bundleFor(bobPublication), bob.address)
        assertTrue(alice.engine.hasSession(bob.address))

        // First message carries the handshake.
        val outgoing = alice.engine.encrypt("hello bob".toByteArray(), bob.address)
        assertEquals(MessageKind.PRE_KEY, outgoing.kind)
        assertArrayEquals(
            "hello bob".toByteArray(),
            bob.engine.decrypt(outgoing, alice.address),
        )

        // Bob now has a session and replies with a normal ratchet message.
        val reply = bob.engine.encrypt("hello alice".toByteArray(), alice.address)
        assertEquals(MessageKind.MESSAGE, reply.kind)
        assertArrayEquals(
            "hello alice".toByteArray(),
            alice.engine.decrypt(reply, bob.address),
        )

        // And the ratchet keeps advancing.
        val second = alice.engine.encrypt("second".toByteArray(), bob.address)
        assertEquals(MessageKind.MESSAGE, second.kind)
        assertArrayEquals("second".toByteArray(), bob.engine.decrypt(second, alice.address))
    }

    @Test
    fun `session establishes without a one-time prekey when the pool is exhausted`() {
        // GET /v1/keys returns oneTimePreKey: null once the pool is drained; the
        // session must still establish from the signed pre-key alone.
        val alice = Peer()
        val bob = Peer()
        val bobPublication = bob.publish()

        alice.engine.processPeerBundle(
            bob.bundleFor(bobPublication, useOneTime = false),
            bob.address,
        )
        val outgoing = alice.engine.encrypt("degraded".toByteArray(), bob.address)
        assertEquals(MessageKind.PRE_KEY, outgoing.kind)
        assertArrayEquals("degraded".toByteArray(), bob.engine.decrypt(outgoing, alice.address))
    }

    @Test
    fun `ciphertext for one peer does not decrypt for another`() {
        val alice = Peer()
        val bob = Peer()
        val mallory = Peer()
        alice.engine.processPeerBundle(bob.bundleFor(bob.publish()), bob.address)
        mallory.publish()

        val outgoing = alice.engine.encrypt("for bob only".toByteArray(), bob.address)
        assertThrows(Exception::class.java) {
            mallory.engine.decrypt(outgoing, alice.address)
        }
    }

    // ------------------------------------------------------------- group keys

    @Test
    fun `sender key distribution lets a member decrypt group messages`() {
        val alice = Peer()
        val bob = Peer()
        val distributionId = UUID.randomUUID()

        val skdm = alice.engine.senderKeyDistributionMessage(distributionId)
        bob.engine.processSenderKeyDistribution(skdm, alice.address)

        val encrypted = alice.engine.groupEncrypt("group hello".toByteArray(), distributionId)
        assertEquals(MessageKind.SENDER_KEY, encrypted.kind)
        assertArrayEquals(
            "group hello".toByteArray(),
            bob.engine.decrypt(encrypted, alice.address),
        )
    }

    @Test
    fun `rotating the distribution id locks out a member holding the old sender key`() {
        // How a removed member is excluded: the actor rotates distribution_id and
        // only distributes the new sender key to remaining members.
        val alice = Peer()
        val removed = Peer()
        val oldEpoch = UUID.randomUUID()
        removed.engine.processSenderKeyDistribution(
            alice.engine.senderKeyDistributionMessage(oldEpoch),
            alice.address,
        )

        val newEpoch = UUID.randomUUID()
        alice.engine.senderKeyDistributionMessage(newEpoch) // not given to `removed`
        val afterRemoval = alice.engine.groupEncrypt("members only".toByteArray(), newEpoch)

        assertThrows(Exception::class.java) {
            removed.engine.decrypt(afterRemoval, alice.address)
        }
    }

    // ----------------------------------------------------------- safety numbers

    @Test
    fun `safety number is 60 digits and symmetric across both sides`() {
        val alice = Peer()
        val bob = Peer()

        val fromAlice = CryptoEngine.safetyNumber(
            localIdentifier = alice.accountId,
            localIdentityKey = alice.engine.identityKey(),
            remoteIdentifier = bob.accountId,
            remoteIdentityKey = bob.engine.identityKey(),
        )
        val fromBob = CryptoEngine.safetyNumber(
            localIdentifier = bob.accountId,
            localIdentityKey = bob.engine.identityKey(),
            remoteIdentifier = alice.accountId,
            remoteIdentityKey = alice.engine.identityKey(),
        )

        assertEquals(60, fromAlice.numeric.length)
        assertTrue(fromAlice.numeric.all { it.isDigit() })
        // Both parties must read the same digits, or out-of-band comparison is useless.
        assertEquals(fromAlice.numeric, fromBob.numeric)
    }

    @Test
    fun `safety number changes when an identity key changes`() {
        val alice = Peer()
        val bob = Peer()
        val impostor = Peer()

        val genuine = CryptoEngine.safetyNumber(
            alice.accountId, alice.engine.identityKey(),
            bob.accountId, bob.engine.identityKey(),
        )
        val swapped = CryptoEngine.safetyNumber(
            alice.accountId, alice.engine.identityKey(),
            bob.accountId, impostor.engine.identityKey(),
        )
        assertNotEquals(genuine.numeric, swapped.numeric)
    }

    @Test
    fun `stored-identity safety number matches the static computation and scans`() {
        val alice = Peer()
        val bob = Peer()
        // No session yet -> no stored identity for the peer.
        assertNull(alice.engine.safetyNumber(bob.accountId))

        alice.engine.processPeerBundle(bob.bundleFor(bob.publish()), bob.address)
        val stored = requireNotNull(alice.engine.safetyNumber(bob.accountId))
        val static = CryptoEngine.safetyNumber(
            alice.accountId, alice.engine.identityKey(),
            bob.accountId, bob.engine.identityKey(),
        )
        assertEquals(static.numeric, stored.numeric)

        // The QR encoding compares equal against the peer's own encoding, in either
        // direction (bob's lists his identity first, alice's lists it second).
        bob.engine.processPeerBundle(alice.bundleFor(alice.publish()), alice.address)
        val bobScannable = requireNotNull(bob.engine.safetyNumber(alice.accountId)).scannable
        assertTrue(alice.engine.verifyScannedSafetyNumber(bobScannable, bob.accountId))
    }

    @Test
    fun `scanning an unrelated safety number fails`() {
        val alice = Peer()
        val bob = Peer()
        val stranger = Peer()
        alice.engine.processPeerBundle(bob.bundleFor(bob.publish()), bob.address)
        stranger.engine.processPeerBundle(alice.bundleFor(alice.publish()), alice.address)

        val strangersCode = requireNotNull(stranger.engine.safetyNumber(alice.accountId)).scannable
        assertFalse(alice.engine.verifyScannedSafetyNumber(strangersCode, bob.accountId))
    }
}
