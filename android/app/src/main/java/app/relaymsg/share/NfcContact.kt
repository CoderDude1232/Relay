package app.relaymsg.share

import android.app.Activity
import android.content.Intent
import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.NfcAdapter
import android.nfc.tech.Ndef
import android.nfc.tech.NdefFormatable

/**
 * Contact exchange over an NFC tag.
 *
 * Tags and stickers, not phone-to-phone: Android Beam was removed in Android 10
 * and iOS never had P2P NDEF at all, so a writable tag is the only exchange
 * both clients can actually perform.
 *
 * The payload is the same `https://relaymsg.app/add/<username>` URL the QR
 * carries — one format for both, and a phone with neither app installed lands
 * on the website rather than a dead scheme.
 */
object NfcContact {

    fun isAvailable(activity: Activity): Boolean =
        NfcAdapter.getDefaultAdapter(activity)?.isEnabled == true

    /** The URL to write, or that was read. */
    fun link(username: String) = "https://relaymsg.app/add/$username"

    /**
     * Pulls a username out of a scanned tag.
     *
     * Accepts the https link and the `relay://add/<username>` scheme alike,
     * because a tag written by an older client may carry either.
     */
    fun username(intent: Intent): String? {
        val messages = intent.rawNdefMessages() ?: return null
        return messages
            .flatMap { it.records.asList() }
            .mapNotNull { it.toUriOrNull() }
            .firstNotNullOfOrNull { uri ->
                when {
                    uri.contains("relaymsg.app/add/") -> uri.substringAfterLast("/add/")
                    uri.startsWith("relay://add/") -> uri.removePrefix("relay://add/")
                    else -> null
                }?.trim()?.takeIf { it.isNotEmpty() }
            }
    }

    /**
     * Writes the link to a tag held against the phone.
     *
     * Formats a blank tag if it will take it. Returns false rather than
     * throwing: a tag that is locked, too small or pulled away mid-write is the
     * normal case, not an exception.
     */
    fun write(intent: Intent, username: String): Boolean {
        val tag = intent.tag() ?: return false
        val message = NdefMessage(arrayOf(NdefRecord.createUri(link(username))))

        Ndef.get(tag)?.let { ndef ->
            return runCatching {
                ndef.connect()
                if (!ndef.isWritable || ndef.maxSize < message.toByteArray().size) return false
                ndef.writeNdefMessage(message)
                ndef.close()
                true
            }.getOrDefault(false)
        }

        return NdefFormatable.get(tag)?.let { formatable ->
            runCatching {
                formatable.connect()
                formatable.format(message)
                formatable.close()
                true
            }.getOrDefault(false)
        } ?: false
    }

    @Suppress("DEPRECATION")
    private fun Intent.rawNdefMessages(): List<NdefMessage>? =
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES, NdefMessage::class.java)
                ?.toList()
        } else {
            getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES)
                ?.filterIsInstance<NdefMessage>()
        }

    @Suppress("DEPRECATION")
    private fun Intent.tag(): android.nfc.Tag? =
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(NfcAdapter.EXTRA_TAG, android.nfc.Tag::class.java)
        } else {
            getParcelableExtra(NfcAdapter.EXTRA_TAG)
        }

    private fun NdefRecord.toUriOrNull(): String? = runCatching { toUri()?.toString() }.getOrNull()
}
