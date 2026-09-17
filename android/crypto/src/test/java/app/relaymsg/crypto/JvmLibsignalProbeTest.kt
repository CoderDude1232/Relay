package app.relaymsg.crypto

import org.junit.Assert.assertEquals
import org.junit.Test
import org.signal.libsignal.protocol.IdentityKeyPair

/** Probe: does libsignal's native library load in a plain JVM unit test? */
class JvmLibsignalProbeTest {
    @Test
    fun nativeLibraryLoads() {
        assertEquals(33, IdentityKeyPair.generate().publicKey.serialize().size)
    }
}
