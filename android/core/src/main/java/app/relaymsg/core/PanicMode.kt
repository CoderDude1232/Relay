package app.relaymsg.core

import java.security.MessageDigest
import java.security.SecureRandom
import org.json.JSONArray

/**
 * The handful of key-value operations [PanicMode] needs.
 *
 * Narrower than the whole store on purpose: it keeps the PIN logic testable
 * without a database, and makes plain that panic mode touches nothing else.
 */
interface KeyValueStore {
    fun get(key: String): ByteArray?
    fun put(key: String, value: ByteArray)
    fun delete(key: String)
}

/**
 * Hides marked conversations behind a second PIN.
 *
 * Not a lock on the app — that is the screen lock — and not a wipe. It is for
 * the case where someone else is holding an unlocked phone and scrolling: the
 * marked threads are simply not in the list, and nothing says they exist.
 *
 * The PIN is stretched the way iOS stretches it (50 000 rounds of SHA-256 over
 * salt ‖ pin, each round feeding the next). Iterated hashing rather than PBKDF2
 * to match the other client exactly; the cost is linear in rounds and lands
 * around 25 ms, which is what makes a four-digit sweep take real time.
 *
 * A PIN this short cannot be made strong. It raises the cost of a casual look,
 * which is the threat it is for.
 */
class PanicMode(private val store: KeyValueStore) {

    val isEnabled: Boolean get() = store.get(KV_HASH) != null

    /** Hidden conversations are only listed while the PIN has been entered. */
    var isUnlocked: Boolean = false
        private set

    fun enable(pin: String) {
        val salt = ByteArray(SALT_BYTES).also { SecureRandom().nextBytes(it) }
        store.put(KV_SALT, salt)
        store.put(KV_HASH, stretch(pin, salt))
        isUnlocked = true
    }

    /** Turns it off and unhides everything; leaving threads hidden with no PIN would strand them. */
    fun disable() {
        store.delete(KV_HASH)
        store.delete(KV_SALT)
        store.delete(KV_HIDDEN)
        isUnlocked = false
    }

    fun unlock(pin: String): Boolean {
        val salt = store.get(KV_SALT) ?: return false
        val expected = store.get(KV_HASH) ?: return false
        // Constant-time: a PIN this short is already weak enough without
        // leaking how many leading bytes were right.
        val matched = MessageDigest.isEqual(expected, stretch(pin, salt))
        if (matched) isUnlocked = true
        return matched
    }

    fun lock() {
        isUnlocked = false
    }

    fun hidden(): Set<String> {
        val raw = store.get(KV_HIDDEN) ?: return emptySet()
        return runCatching {
            val array = JSONArray(raw.decodeToString())
            (0 until array.length()).map { array.getString(it) }.toSet()
        }.getOrDefault(emptySet())
    }

    fun setHidden(conversationId: String, hidden: Boolean) {
        val next = if (hidden) hidden() + conversationId else hidden() - conversationId
        store.put(KV_HIDDEN, JSONArray(next.sorted()).toString().toByteArray())
    }

    /** Whether a conversation should be left out of the list right now. */
    fun shouldHide(conversationId: String): Boolean =
        isEnabled && !isUnlocked && conversationId in hidden()

    private fun stretch(pin: String, salt: ByteArray): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        var state = digest.digest(pin.toByteArray() + salt)
        repeat(ROUNDS - 1) { state = digest.digest(state) }
        return state
    }

    private companion object {
        const val SALT_BYTES = 16

        /** iOS's count. Around 25 ms, which is the point. */
        const val ROUNDS = 50_000

        const val KV_HASH = "panic.hash"
        const val KV_SALT = "panic.salt"
        const val KV_HIDDEN = "panic.hidden"
    }
}
