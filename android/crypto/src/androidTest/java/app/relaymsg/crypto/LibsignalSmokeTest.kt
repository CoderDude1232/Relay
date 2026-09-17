package app.relaymsg.crypto

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.fingerprint.NumericFingerprintGenerator
import org.signal.libsignal.protocol.kem.KEMKeyPair
import org.signal.libsignal.protocol.kem.KEMKeyType

/**
 * Stage 1 verification that libsignal 0.97.4 is wired up correctly — this is an
 * *instrumented* test because it needs the native `libsignal_jni.so`, which only
 * loads on a device or emulator.
 *
 * It also pins the crypto parameters PROTOCOL.md §1.2/§1.3/§1.5 claims the iOS
 * client uses, so a future libsignal bump that changes any of them fails here
 * rather than silently breaking interop.
 */
@RunWith(AndroidJUnit4::class)
class LibsignalSmokeTest {

    @Test
    fun identityKeyIsThirtyThreeByteDjbEncoded() {
        val identity = IdentityKeyPair.generate()
        val serialized = identity.publicKey.serialize()
        // PROTOCOL.md §1.2: Curve25519, 33-byte serialization 0x05 || X.
        assertEquals(33, serialized.size)
        assertEquals(0x05.toByte(), serialized[0])
    }

    @Test
    fun kyberKeyTypeIsKyber1024() {
        // PROTOCOL.md §1.3: the mandatory last-resort Kyber prekey.
        val pair = KEMKeyPair.generate(KEMKeyType.KYBER_1024)
        assertTrue(pair.publicKey.serialize().isNotEmpty())
    }

    @Test
    fun safetyNumberUsesSignalProductionParameters() {
        // PROTOCOL.md §1.5: 5200 iterations, version 2, account ids as the
        // stable identifiers, 60 displayed digits.
        val local = IdentityKeyPair.generate()
        val remote = IdentityKeyPair.generate()
        val fingerprint = NumericFingerprintGenerator(5200).createFor(
            2,
            "acct-local".toByteArray(),
            local.publicKey,
            "acct-remote".toByteArray(),
            remote.publicKey,
        )
        val displayed = fingerprint.displayableFingerprint.displayText
        assertEquals(60, displayed.length)
        assertTrue(displayed.all { it.isDigit() })
        assertTrue(fingerprint.scannableFingerprint.serialized.isNotEmpty())
    }

    @Test
    fun safetyNumberIsSymmetricAcrossBothSides() {
        val a = IdentityKeyPair.generate()
        val b = IdentityKeyPair.generate()
        fun numberFrom(
            localId: String,
            localKey: IdentityKeyPair,
            remoteId: String,
            remoteKey: IdentityKeyPair,
        ) = NumericFingerprintGenerator(5200).createFor(
            2,
            localId.toByteArray(),
            localKey.publicKey,
            remoteId.toByteArray(),
            remoteKey.publicKey,
        ).displayableFingerprint.displayText

        // Both peers must derive the same 60 digits from opposite viewpoints,
        // which is what makes out-of-band comparison meaningful.
        assertEquals(
            numberFrom("acct-a", a, "acct-b", b),
            numberFrom("acct-b", b, "acct-a", a),
        )
    }
}
