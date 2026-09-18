package app.relaymsg.crypto

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.signal.libsignal.protocol.ecc.ECKeyPair
import org.signal.libsignal.protocol.ecc.ECPrivateKey
import org.signal.libsignal.protocol.ecc.ECPublicKey

/** The blob was not something this version can open. */
class ProvisioningCipherException(message: String) : IllegalArgumentException(message)

/**
 * End-to-end encryption for the device-linking payload (PROTOCOL.md §7.9).
 *
 * The new device makes an ephemeral X25519 pair and shows the public half in a
 * QR code. The primary does ECDH against it, derives a key with HKDF-SHA256 and
 * seals the payload; the new device does the matching ECDH and opens it. The
 * relay only ever holds the resulting opaque blob, so the account's identity
 * private key never crosses the wire in the clear.
 *
 * Blob layout, which must match iOS `ProvisioningCipher` exactly:
 *
 * ```
 * version(1) ‖ senderEphemeralPublicKey(32) ‖ nonce(12) ‖ ciphertext ‖ tag(16)
 * ```
 *
 * The public keys are **raw 32-byte X25519**, matching CryptoKit's
 * `rawRepresentation`. libsignal's own `serialize()` prefixes a `0x05` type
 * byte, so `getPublicKeyBytes()` / `fromPublicKeyBytes` are used throughout —
 * mixing the two produces a 33-byte key iOS cannot read.
 */
object ProvisioningCipher {

    /** Domain separation: binds the derived key to this one use. */
    private val INFO = "Relay Device Provisioning v1".toByteArray()

    private const val VERSION: Byte = 0x01
    private const val PUBLIC_KEY_LENGTH = 32
    private const val NONCE_LENGTH = 12
    private const val TAG_BITS = 128

    /**
     * libsignal serializes a curve point as `type(0x05) ‖ X`; CryptoKit's
     * `rawRepresentation` is the bare `X`. These two helpers are the only place
     * that difference is handled, because getting it wrong produces a 33-byte
     * key iOS silently cannot agree with.
     */
    private const val DJB_TYPE: Byte = 0x05

    private fun raw(key: ECPublicKey): ByteArray = key.serialize().let { serialized ->
        require(serialized.size == PUBLIC_KEY_LENGTH + 1 && serialized[0] == DJB_TYPE) {
            "unexpected curve point encoding"
        }
        serialized.copyOfRange(1, serialized.size)
    }

    private fun decode(raw: ByteArray): ECPublicKey {
        require(raw.size == PUBLIC_KEY_LENGTH) { "bad public key length ${raw.size}" }
        return ECPublicKey(byteArrayOf(DJB_TYPE) + raw)
    }

    /**
     * The new device's ephemeral pair.
     *
     * The public half goes in the QR; the private half stays in memory on the
     * new device for the life of the linking session, is used once, and is never
     * written to disk or logged.
     */
    class EphemeralKeyPair private constructor(private val pair: ECKeyPair) {
        /** Raw 32 bytes, as CryptoKit writes them — this is what goes in the QR. */
        val publicKey: ByteArray get() = raw(pair.publicKey)
        internal val private: ECPrivateKey get() = pair.privateKey

        companion object {
            fun generate() = EphemeralKeyPair(ECKeyPair.generate())
        }
    }

    /** Primary side: seals [payload] to the new device's ephemeral public key. */
    fun seal(payload: ByteArray, recipientPublicKey: ByteArray): ByteArray {
        require(recipientPublicKey.size == PUBLIC_KEY_LENGTH) { "bad recipient key length" }
        val ephemeral = ECKeyPair.generate()
        val shared = ephemeral.privateKey.calculateAgreement(decode(recipientPublicKey))
        val key = Hkdf.derive(shared, salt = ByteArray(0), info = INFO, length = 32)

        val nonce = ByteArray(NONCE_LENGTH).also { SecureRandom().nextBytes(it) }
        val sealed = Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
            doFinal(payload)
        }
        return byteArrayOf(VERSION) + raw(ephemeral.publicKey) + nonce + sealed
    }

    /** New-device side: opens a blob sealed to [ephemeral]. */
    fun open(blob: ByteArray, ephemeral: EphemeralKeyPair): ByteArray {
        if (blob.size <= 1 + PUBLIC_KEY_LENGTH + NONCE_LENGTH) {
            throw ProvisioningCipherException("provisioning blob too short")
        }
        if (blob[0] != VERSION) {
            throw ProvisioningCipherException("unsupported provisioning version ${blob[0]}")
        }

        val senderKey = blob.copyOfRange(1, 1 + PUBLIC_KEY_LENGTH)
        val nonce = blob.copyOfRange(1 + PUBLIC_KEY_LENGTH, 1 + PUBLIC_KEY_LENGTH + NONCE_LENGTH)
        val body = blob.copyOfRange(1 + PUBLIC_KEY_LENGTH + NONCE_LENGTH, blob.size)

        val shared = ephemeral.private.calculateAgreement(decode(senderKey))
        val key = Hkdf.derive(shared, salt = ByteArray(0), info = INFO, length = 32)
        return Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
            doFinal(body)
        }
    }
}
