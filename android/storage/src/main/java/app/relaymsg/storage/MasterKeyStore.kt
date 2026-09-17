package app.relaymsg.storage

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Base64
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Custody of the database master key.
 *
 * The design mirrors iOS (PROTOCOL.md §7.6): 32 random bytes are generated once
 * and **never stored in the clear**. They are wrapped with an AES key that lives
 * inside the Android Keystore — the Keystore counterpart of iOS's Secure Enclave
 * ECIES wrap — and only the wrapped blob is persisted.
 *
 * Hardware tiers are tried in order and recorded, because they are not equally
 * strong and the user deserves an honest answer about which one they got:
 *
 *  1. **StrongBox** — a separate security chip. Unavailable on emulators and on
 *     plenty of real hardware.
 *  2. **TEE** — the standard hardware-backed Keystore.
 *  3. **Software** — Keystore without hardware backing. Still better than a bare
 *     file, but it is not a hardware guarantee and [tier] will say so.
 *
 * The wrapped blob and the tier live in ordinary SharedPreferences: the blob is
 * useless without the Keystore key, which cannot be exported from the device.
 *
 * The identity private key and registration id are held here too, and
 * deliberately never enter the SQLCipher database — the same rule iOS follows
 * with the Keychain.
 */
class MasterKeyStore(
    private val context: Context,
    private val preferencesName: String = DEFAULT_PREFERENCES,
) {

    /** Which Keystore backing the wrapping key actually got. */
    enum class Tier { STRONGBOX, TEE, SOFTWARE }

    companion object {
        const val DEFAULT_PREFERENCES = "app.relaymsg.secrets"

        private const val KEYSTORE = "AndroidKeyStore"
        private const val WRAPPING_KEY_ALIAS = "app.relaymsg.db-wrapping-key"

        private const val PREF_WRAPPED_KEY = "db-master-key.wrapped"
        private const val PREF_TIER = "db-master-key.tier"
        private const val PREF_IDENTITY = "identity-key-pair"
        private const val PREF_REGISTRATION_ID = "registration-id"

        private const val MASTER_KEY_BYTES = 32
        private const val GCM_NONCE_BYTES = 12
        private const val GCM_TAG_BITS = 128
    }

    private val prefs by lazy {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
    }
    private val random = SecureRandom()

    /** The Keystore tier protecting the master key, once one has been created. */
    val tier: Tier?
        get() = prefs.getString(PREF_TIER, null)?.let(Tier::valueOf)

    /**
     * The 32-byte database master key, generated and persisted on first call.
     *
     * Callers should zero the array when finished; SQLCipher copies it.
     */
    fun databaseKey(): ByteArray {
        prefs.getString(PREF_WRAPPED_KEY, null)?.let { stored ->
            return unwrap(Base64.decode(stored, Base64.NO_WRAP))
        }
        val key = ByteArray(MASTER_KEY_BYTES).also(random::nextBytes)
        val (wrapped, tier) = wrap(key)
        prefs.edit()
            .putString(PREF_WRAPPED_KEY, Base64.encodeToString(wrapped, Base64.NO_WRAP))
            .putString(PREF_TIER, tier.name)
            .apply()
        return key
    }

    // ------------------------------------------------------------- identity

    /** The stored libsignal identity key pair, or null before one is created. */
    fun identityKeyPair(): ByteArray? =
        prefs.getString(PREF_IDENTITY, null)?.let { Base64.decode(it, Base64.NO_WRAP) }

    fun storeIdentityKeyPair(serialized: ByteArray) {
        prefs.edit()
            .putString(PREF_IDENTITY, Base64.encodeToString(serialized, Base64.NO_WRAP))
            .apply()
    }

    /**
     * The device's registration id, generated once in 1..0x3FFF and persisted
     * (PROTOCOL.md §1.2). A changed registration id makes every peer's session
     * stale, so it must survive for the life of the install.
     */
    fun registrationId(): Int {
        val existing = prefs.getInt(PREF_REGISTRATION_ID, 0)
        if (existing != 0) return existing
        val generated = 1 + random.nextInt(0x3FFF)
        prefs.edit().putInt(PREF_REGISTRATION_ID, generated).apply()
        return generated
    }

    /** Erases every secret held here — the local half of a remote wipe. */
    fun wipe() {
        prefs.edit().clear().apply()
        runCatching {
            KeyStore.getInstance(KEYSTORE).apply { load(null) }.deleteEntry(WRAPPING_KEY_ALIAS)
        }
    }

    // ------------------------------------------------------- key wrapping

    /** AES-GCM wrap: the returned blob is `nonce ‖ ciphertext ‖ tag`. */
    private fun wrap(plaintext: ByteArray): Pair<ByteArray, Tier> {
        val (wrappingKey, tier) = createWrappingKey()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey)
        val body = cipher.doFinal(plaintext)
        return (cipher.iv + body) to tier
    }

    private fun unwrap(blob: ByteArray): ByteArray {
        require(blob.size > GCM_NONCE_BYTES) { "wrapped master key is truncated" }
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        val wrappingKey = keyStore.getKey(WRAPPING_KEY_ALIAS, null) as? SecretKey
            ?: throw IllegalStateException(
                "the Keystore wrapping key is gone but a wrapped database key remains — " +
                    "the database can no longer be opened and local state must be reset",
            )
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            wrappingKey,
            GCMParameterSpec(GCM_TAG_BITS, blob, 0, GCM_NONCE_BYTES),
        )
        return cipher.doFinal(blob, GCM_NONCE_BYTES, blob.size - GCM_NONCE_BYTES)
    }

    /**
     * Creates the Keystore wrapping key, preferring the strongest tier available.
     *
     * The key is NOT bound to user authentication: the client must be able to
     * decrypt an incoming message while the device is locked (the push path), the
     * same reason iOS uses `AfterFirstUnlockThisDeviceOnly` rather than a
     * biometric-gated item.
     */
    private fun createWrappingKey(): Pair<SecretKey, Tier> {
        fun spec(strongBox: Boolean) =
            KeyGenParameterSpec.Builder(
                WRAPPING_KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .apply { if (strongBox) setIsStrongBoxBacked(true) }
                .build()

        fun generate(strongBox: Boolean): SecretKey =
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
                .apply { init(spec(strongBox)) }
                .generateKey()

        // StrongBox: a separate secure element. Absent on emulators and on many
        // devices, and the failure mode varies by OEM, so treat any failure as
        // "not available" rather than trusting the documented exception alone.
        runCatching { return generate(strongBox = true) to Tier.STRONGBOX }
            .onFailure { if (it !is StrongBoxUnavailableException && it !is Exception) throw it }

        // TEE, then plain software. Keystore decides which it can honour; the
        // resulting key is used identically either way.
        return generate(strongBox = false) to
            if (isHardwareBacked()) Tier.TEE else Tier.SOFTWARE
    }

    /** Whether the generated wrapping key ended up inside secure hardware. */
    private fun isHardwareBacked(): Boolean = runCatching {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        val key = keyStore.getKey(WRAPPING_KEY_ALIAS, null) as SecretKey
        val factory = javax.crypto.SecretKeyFactory.getInstance(key.algorithm, KEYSTORE)
        val info = factory.getKeySpec(
            key,
            android.security.keystore.KeyInfo::class.java,
        ) as android.security.keystore.KeyInfo
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            info.securityLevel != android.security.keystore.KeyProperties.SECURITY_LEVEL_SOFTWARE
        } else {
            @Suppress("DEPRECATION")
            info.isInsideSecureHardware
        }
    }.getOrDefault(false)
}
