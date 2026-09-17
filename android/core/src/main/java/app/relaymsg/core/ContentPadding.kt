package app.relaymsg.core

import com.google.protobuf.ByteString
import java.security.SecureRandom
import relay.content.ContentOuterClass.Content

/**
 * Pads a serialized `Content` before encryption so the relay observes fewer
 * exact plaintext-size differences (PROTOCOL.md §1.9).
 *
 * Sizes are rounded up to the next bucket: 256, 512, 1024, 4096, then to the next
 * 4096-byte boundary above that. The filler goes in `Content.padding` (field 12),
 * which receivers ignore.
 *
 * This must match `RelayCore/ContentPadding.swift` — not because a mismatch
 * breaks decryption (it doesn't; the field is ignored), but because differing
 * bucket sizes would make Android and iOS traffic distinguishable on the wire,
 * which is the whole point of padding.
 *
 * **Ephemeral payloads (typing, receipts) are not padded** — the caller decides.
 */
object ContentPadding {

    private val BUCKETS = intArrayOf(256, 512, 1024, 4096)

    /**
     * Messages larger than the largest fixed bucket are rounded up to the next
     * multiple of this block, so no message is ever sent at its exact length.
     */
    private const val LARGE_BLOCK = 4096

    private val random = SecureRandom()

    /** Smallest bucket strictly greater than [size]; above that, the next block boundary. */
    internal fun targetSize(size: Int): Int =
        BUCKETS.firstOrNull { it > size } ?: (((size / LARGE_BLOCK) + 1) * LARGE_BLOCK)

    /**
     * Returns [serializedContent] re-serialized with padding added.
     *
     * Protobuf length prefixes grow as the padding grows, so the amount is
     * adjusted until the final encoding fits the bucket. If no amount fits, the
     * input is returned unchanged rather than overshooting the bucket.
     */
    fun pad(serializedContent: ByteArray): ByteArray {
        val content = Content.parseFrom(serializedContent)
        val baseSize = serializedContent.size
        val target = targetSize(baseSize)

        // Start just under the target to leave room for the field tag and length
        // prefix, then shrink by however much we overshot.
        var paddingSize = maxOf(0, target - baseSize - 2)
        while (paddingSize > 0) {
            val padded = content.toBuilder()
                .setPadding(ByteString.copyFrom(ByteArray(paddingSize).also(random::nextBytes)))
                .build()
                .toByteArray()
            if (padded.size <= target) return padded
            paddingSize -= padded.size - target
        }
        return serializedContent
    }
}
