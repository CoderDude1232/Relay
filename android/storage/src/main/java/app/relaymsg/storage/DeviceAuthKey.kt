package app.relaymsg.storage

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

/**
 * The device's P-256 authorization key, held in the Android Keystore.
 *
 * One key serves three purposes on the server side, all verified against the
 * single stored `devices.auth_public_key`:
 *
 *  - `Relay-Sig` per-request signatures (PROTOCOL.md §2.1),
 *  - remote-wipe (nuke) commands,
 *  - device-list mutations (add / link / remove).
 *
 * The private half is generated inside the Keystore and is not exportable, which
 * is the point: unlike the device password it replaces, nothing replayable ever
 * crosses the wire, and a stolen database yields no way to sign as this device.
 *
 * This is the Keystore counterpart of iOS's Keychain-held device authorization
 * key — with the difference that iOS has not yet shipped the client half of
 * `Relay-Sig` at all, so Android is the first client to sign requests.
 */
class DeviceAuthKey(private val alias: String = DEFAULT_ALIAS) {

    companion object {
        const val DEFAULT_ALIAS = "app.relaymsg.device-auth-key"
        private const val KEYSTORE = "AndroidKeyStore"

        /** ASN.1/DER, which is what the server's `ecdsa.VerifyASN1` expects. */
        private const val SIGNATURE_ALGORITHM = "SHA256withECDSA"
    }

    private val keyStore: KeyStore
        get() = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    /** Signs [message] — SHA-256 is applied by the algorithm, not by the caller. */
    fun sign(message: ByteArray): ByteArray {
        val privateKey = (keyStore.getEntry(ensureKey(), null) as KeyStore.PrivateKeyEntry).privateKey
        return Signature.getInstance(SIGNATURE_ALGORITHM).run {
            initSign(privateKey)
            update(message)
            sign()
        }
    }

    /**
     * The public key as an **uncompressed** P-256 point: `0x04 ‖ X ‖ Y`, 65 bytes.
     *
     * The server parses this with `elliptic.Unmarshal`, which accepts only this
     * encoding — a compressed point or an X.509/SPKI wrapper is rejected with a
     * 400, so the raw affine coordinates are assembled by hand here.
     */
    fun publicKey(): ByteArray {
        val certificate = keyStore.getCertificate(ensureKey())
        val point = (certificate.publicKey as ECPublicKey).w
        val x = point.affineX.toUnsigned32()
        val y = point.affineY.toUnsigned32()
        return byteArrayOf(0x04) + x + y
    }

    fun exists(): Boolean = keyStore.containsAlias(alias)

    fun delete() {
        runCatching { keyStore.deleteEntry(alias) }
    }

    /** Creates the key on first use; later calls are cheap lookups. */
    private fun ensureKey(): String {
        if (keyStore.containsAlias(alias)) return alias
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE).apply {
            initialize(
                KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    // Not bound to user authentication: requests must be signable
                    // while the device is locked, since the push path fetches and
                    // acks the queue in the background.
                    .setUserAuthenticationRequired(false)
                    .build(),
            )
            generateKeyPair()
        }
        return alias
    }

    /**
     * A P-256 affine coordinate as exactly 32 bytes.
     *
     * `BigInteger.toByteArray` is signed and variable-length: it prepends a 0x00
     * byte when the high bit is set, and omits leading zeros otherwise. Either
     * would shift the point encoding and make the server reject the key.
     */
    private fun java.math.BigInteger.toUnsigned32(): ByteArray {
        val raw = toByteArray()
        return when {
            raw.size == 32 -> raw
            raw.size > 32 -> raw.copyOfRange(raw.size - 32, raw.size)
            else -> ByteArray(32 - raw.size) + raw
        }
    }
}
