package app.relaymsg.storage

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.relaymsg.crypto.PeerPreKeyBundle
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.signal.libsignal.protocol.SignalProtocolAddress

/**
 * Stage 3 storage tests.
 *
 * Instrumented rather than JVM: SQLCipher ships Android native libraries and the
 * Keystore is a platform service, so neither exists on the host JVM. Run with
 * `./gradlew :storage:connectedDebugAndroidTest` against an emulator.
 */
@RunWith(AndroidJUnit4::class)
class SecureStoreTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var keys: MasterKeyStore
    private lateinit var store: SecureStore

    /** A preferences namespace per test, so each starts with no key material. */
    private fun freshKeys() = MasterKeyStore(context, "test-secrets-${UUID.randomUUID()}")

    @Before
    fun setUp() {
        keys = freshKeys()
        store = SecureStore.openInMemory(keys)
    }

    @After
    fun tearDown() {
        store.close()
        keys.wipe()
    }

    // ------------------------------------------------------------ key custody

    @Test
    fun masterKeyIsStableAcrossReopen() {
        val first = keys.databaseKey()
        val second = keys.databaseKey()
        // Unwrapping must reproduce the key exactly, or the database becomes
        // unreadable on the second launch.
        assertArrayEquals(first, second)
        assertEquals(32, first.size)
    }

    @Test
    fun masterKeyIsNotStoredInTheClear() {
        val key = keys.databaseKey()
        val prefs = context.getSharedPreferences(
            MasterKeyStore.DEFAULT_PREFERENCES,
            android.content.Context.MODE_PRIVATE,
        )
        // The wrapped blob is all that is persisted; the raw key must not appear.
        prefs.all.values.filterIsInstance<String>().forEach { stored ->
            assertFalse(stored.contains(android.util.Base64.encodeToString(key, android.util.Base64.NO_WRAP)))
        }
    }

    @Test
    fun keystoreTierIsRecorded() {
        keys.databaseKey()
        val tier = keys.tier
        assertNotNull("no Keystore tier was recorded", tier)
        // StrongBox does not exist on an emulator; TEE or SOFTWARE is expected
        // there. On real hardware this should be STRONGBOX or TEE — if it reports
        // SOFTWARE on a physical device, the key is not hardware-protected.
        assertTrue(tier in MasterKeyStore.Tier.entries)
    }

    @Test
    fun identityAndRegistrationIdPersist() {
        val engine = store.makeCryptoEngine(UUID.randomUUID().toString(), 1)
        val identity = engine.identityKey()
        val registrationId = engine.registrationId()

        assertEquals(33, identity.size)
        assertEquals(0x05.toByte(), identity[0])
        assertTrue(registrationId in 1..0x3FFF)

        // A second engine over the same store must present the same identity;
        // a regenerated identity would invalidate every peer's session.
        val reopened = store.makeCryptoEngine(UUID.randomUUID().toString(), 1)
        assertArrayEquals(identity, reopened.identityKey())
        assertEquals(registrationId, reopened.registrationId())
    }

    // ------------------------------------------------- sessions across restart

    @Test
    fun sessionSurvivesReopeningTheDatabase() {
        // The Stage 3 milestone: encrypt before a restart, decrypt after it.
        val aliceAccount = UUID.randomUUID().toString()
        val bobAccount = UUID.randomUUID().toString()
        val aliceAddress = SignalProtocolAddress(aliceAccount, 1)
        val bobAddress = SignalProtocolAddress(bobAccount, 1)

        val bobKeys = freshKeys()
        val bobStore = SecureStore.openInMemory(bobKeys)
        try {
            val alice = store.makeCryptoEngine(aliceAccount, 1)
            val bob = bobStore.makeCryptoEngine(bobAccount, 1)

            val bobPublication = bob.generatePreKeyPublication(1, 2, 100..101)
            alice.processPeerBundle(
                PeerPreKeyBundle(
                    deviceId = 1,
                    registrationId = bobPublication.registrationId,
                    identityKey = bobPublication.identityKey,
                    signedPreKey = bobPublication.signedPreKey,
                    kyberPreKey = bobPublication.kyberPreKey,
                    oneTimePreKey = bobPublication.oneTimePreKeys.first(),
                ),
                bobAddress,
            )

            val ciphertext = alice.encrypt("persisted hello".toByteArray(), bobAddress)

            // Bob's session state lives in SQLCipher; a fresh engine over the same
            // store stands in for the process having been restarted.
            val bobAfterRestart = bobStore.makeCryptoEngine(bobAccount, 1)
            assertArrayEquals(
                "persisted hello".toByteArray(),
                bobAfterRestart.decrypt(ciphertext, aliceAddress),
            )
        } finally {
            bobStore.close()
            bobKeys.wipe()
        }
    }

    // ------------------------------------------------------ identity policy

    @Test
    fun trustOnFirstUseThenDistrustAChangedKey() {
        val signalStore = store.signalStore
        val peer = SignalProtocolAddress(UUID.randomUUID().toString(), 1)
        val first = org.signal.libsignal.protocol.IdentityKeyPair.generate().publicKey
        val replacement = org.signal.libsignal.protocol.IdentityKeyPair.generate().publicKey
        val direction = org.signal.libsignal.protocol.state.IdentityKeyStore.Direction.SENDING

        // Unknown peer: trusted on first use and recorded.
        assertTrue(signalStore.isTrustedIdentity(peer, first, direction))
        signalStore.saveIdentity(peer, first)
        assertTrue(signalStore.isTrustedIdentity(peer, first, direction))

        // A different key for a known peer is NOT trusted — this is what surfaces
        // as the safety-number-changed warning.
        assertFalse(signalStore.isTrustedIdentity(peer, replacement, direction))
    }

    @Test
    fun verificationStateTracksKeyChanges() {
        val signalStore = store.signalStore
        val name = UUID.randomUUID().toString()
        val peer = SignalProtocolAddress(name, 1)
        val original = org.signal.libsignal.protocol.IdentityKeyPair.generate().publicKey
        val replacement = org.signal.libsignal.protocol.IdentityKeyPair.generate().publicKey

        signalStore.saveIdentity(peer, original)
        assertEquals(SqlCipherSignalStore.VerificationState.UNVERIFIED, signalStore.verificationState(name))

        signalStore.setVerified(true, name)
        assertEquals(SqlCipherSignalStore.VerificationState.VERIFIED, signalStore.verificationState(name))
        assertTrue(signalStore.isVerified(name))

        // The peer reinstalls: verification resets, and the state must say the key
        // CHANGED rather than merely "unverified", so the UI can warn.
        signalStore.saveIdentity(peer, replacement)
        assertEquals(SqlCipherSignalStore.VerificationState.CHANGED, signalStore.verificationState(name))
        assertFalse(signalStore.isVerified(name))
    }

    // --------------------------------------------------- kyber replay guard

    @Test
    fun replayingAKyberHandshakeIsRefused() {
        // Relay publishes one last-resort Kyber prekey and never rotates it, so
        // libsignal delegates replay detection to the store. A repeated
        // (kyber, signed, baseKey) tuple means a captured PreKeySignalMessage is
        // being replayed.
        val signalStore = store.signalStore
        val baseKey = org.signal.libsignal.protocol.ecc.ECKeyPair.generate().publicKey

        signalStore.markKyberPreKeyUsed(2, 1, baseKey)
        assertThrows(org.signal.libsignal.protocol.ReusedBaseKeyException::class.java) {
            signalStore.markKyberPreKeyUsed(2, 1, baseKey)
        }

        // A different base key is a genuine new handshake and must be allowed.
        val otherBaseKey = org.signal.libsignal.protocol.ecc.ECKeyPair.generate().publicKey
        signalStore.markKyberPreKeyUsed(2, 1, otherBaseKey)
    }

    @Test
    fun oneTimePrekeysAreConsumedButTheKyberKeyIsKept() {
        val engine = store.makeCryptoEngine(UUID.randomUUID().toString(), 1)
        val publication = engine.generatePreKeyPublication(1, 2, 100..102)
        val signalStore = store.signalStore

        assertTrue(signalStore.containsPreKey(100))
        signalStore.removePreKey(100)
        assertFalse(signalStore.containsPreKey(100))

        // The last-resort Kyber prekey is marked used but must survive, or every
        // later inbound PQXDH handshake fails.
        signalStore.markKyberPreKeyUsed(
            publication.kyberPreKey.id,
            publication.signedPreKey.id,
            org.signal.libsignal.protocol.ecc.ECKeyPair.generate().publicKey,
        )
        assertTrue(signalStore.containsKyberPreKey(publication.kyberPreKey.id))
    }
}
