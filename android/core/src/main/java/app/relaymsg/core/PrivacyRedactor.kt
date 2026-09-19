package app.relaymsg.core

/**
 * Strips secrets out of anything on its way to a log.
 *
 * Android's logcat is readable by `adb` from any machine the phone is plugged
 * into, and crash reporters copy it wholesale — so an exception carrying a
 * bearer token or an account id is a real leak, not a theoretical one. Every
 * log line that interpolates a server response, a URL or an exception goes
 * through here.
 *
 * Patterns match iOS's `PrivacyRedactor` so both clients redact the same shapes.
 */
object PrivacyRedactor {

    const val REDACTED = "<redacted>"

    private val patterns = listOf(
        // Authorization headers, in either spelling.
        Regex("""(?i)\bbearer\s+[^\s,;]+"""),
        Regex("""(?i)(authorization|bearer|basic|password|token|secret|nonce|key|credential)=([^\s,;]+)"""),
        Regex("""(?i)(authorization|bearer|basic|password|token|secret|nonce|key|credential)(["':\s=]+)([^\s,;}]+)"""),
        // Account and group ids.
        Regex("""\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"""),
        // Hex blobs: keys, digests, mailbox ids.
        Regex("""\b[0-9a-fA-F]{32,}\b"""),
        // Base64: ciphertext, tokens, serialized keys.
        Regex("""\b[A-Za-z0-9+/]{48,}={0,2}\b"""),
    )

    fun redact(value: String): String =
        patterns.fold(value) { text, pattern -> pattern.replace(text, REDACTED) }

    /**
     * A throwable's message, redacted.
     *
     * The class name is kept — it is the useful half and never carries a
     * secret; only the message can.
     */
    fun redact(error: Throwable): String =
        "${error::class.simpleName}: ${redact(error.message.orEmpty())}"
}
