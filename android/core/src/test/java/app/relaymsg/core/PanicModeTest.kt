package app.relaymsg.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Panic mode's logic, against an in-memory stand-in for the kv table. */
class PanicModeTest {

    private class FakeStore : KeyValueStore {
        private val values = mutableMapOf<String, ByteArray>()
        override fun get(key: String) = values[key]
        override fun put(key: String, value: ByteArray) { values[key] = value }
        override fun delete(key: String) { values.remove(key) }
    }

    @Test
    fun `the right pin unlocks and a wrong one does not`() {
        val panic = PanicMode(FakeStore())
        panic.enable("4821")
        panic.lock()

        assertFalse(panic.unlock("1234"))
        assertFalse(panic.isUnlocked)
        assertTrue(panic.unlock("4821"))
        assertTrue(panic.isUnlocked)
    }

    @Test
    fun `hidden conversations are hidden only while locked`() {
        val panic = PanicMode(FakeStore())
        panic.enable("4821")
        panic.setHidden("conv-1", true)

        // Enabling leaves it unlocked, so the thread is still visible.
        assertFalse(panic.shouldHide("conv-1"))

        panic.lock()
        assertTrue(panic.shouldHide("conv-1"))
        assertFalse("an unmarked thread must stay visible", panic.shouldHide("conv-2"))

        panic.unlock("4821")
        assertFalse(panic.shouldHide("conv-1"))
    }

    @Test
    fun `disabling unhides everything`() {
        // Leaving threads marked with no PIN to unlock them would strand them
        // out of the list permanently.
        val panic = PanicMode(FakeStore())
        panic.enable("4821")
        panic.setHidden("conv-1", true)
        panic.disable()

        assertFalse(panic.isEnabled)
        assertEquals(emptySet<String>(), panic.hidden())
        assertFalse(panic.shouldHide("conv-1"))
    }

    @Test
    fun `nothing is hidden before a pin is set`() {
        val panic = PanicMode(FakeStore())
        assertFalse(panic.isEnabled)
        assertFalse(panic.shouldHide("conv-1"))
    }
}
