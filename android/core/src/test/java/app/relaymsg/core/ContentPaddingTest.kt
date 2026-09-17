package app.relaymsg.core

import com.google.gson.JsonParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import relay.content.ContentOuterClass.Content
import relay.content.content
import relay.content.textMessage

/**
 * Content padding (PROTOCOL.md §1.9).
 *
 * Padding does not affect decryption — receivers ignore the field — so a mismatch
 * would not break messaging. It would do something subtler and worse: make
 * Android traffic distinguishable from iOS traffic by size, defeating the reason
 * the padding exists. Hence the bucket table is checked against vectors generated
 * from the same arithmetic the Swift implementation uses.
 */
class ContentPaddingTest {

    private fun paddingCases(): List<Pair<Int, Int>> {
        val stream = checkNotNull(
            javaClass.classLoader?.getResourceAsStream("golden/crypto-vectors.json")
        ) { "golden/crypto-vectors.json missing — run tools/genvectors -kind=crypto" }
        val padding = stream.reader().use { JsonParser.parseReader(it) }
            .asJsonObject.getAsJsonObject("padding")
        return padding.getAsJsonArray("cases").map {
            val o = it.asJsonObject
            o.get("input").asInt to o.get("target").asInt
        }
    }

    @Test
    fun `bucket sizes match the other clients`() {
        val cases = paddingCases()
        assertTrue("no padding vectors loaded", cases.isNotEmpty())
        for ((input, expected) in cases) {
            assertEquals("target size differs for input $input", expected, ContentPadding.targetSize(input))
        }
    }

    @Test
    fun `sizes at a bucket boundary move up to the next bucket`() {
        // Strictly greater, so a message that happens to be exactly 256 bytes is
        // not left unpadded at its exact length.
        assertEquals(512, ContentPadding.targetSize(256))
        assertEquals(256, ContentPadding.targetSize(255))
        assertEquals(8192, ContentPadding.targetSize(4096))
    }

    @Test
    fun `padding fills to the bucket without exceeding it`() {
        for (bodyLength in intArrayOf(0, 1, 50, 200, 400, 900, 3000, 9000)) {
            val message = content {
                text = textMessage {
                    body = "x".repeat(bodyLength)
                    timestamp = 1758000000000L
                }
                senderAccountId = "6f1a2b3c-4d5e-4f60-8899-aabbccddeeff"
                senderDeviceId = 1
            }
            val serialized = message.toByteArray()
            val padded = ContentPadding.pad(serialized)
            val target = ContentPadding.targetSize(serialized.size)

            assertTrue(
                "padded size ${padded.size} overshot target $target (body $bodyLength)",
                padded.size <= target,
            )
            assertTrue(
                "padding did not grow the message (body $bodyLength)",
                padded.size > serialized.size,
            )
        }
    }

    @Test
    fun `padding is random, so equal messages do not produce equal ciphertext input`() {
        val message = content {
            text = textMessage { body = "hello"; timestamp = 1758000000000L }
        }.toByteArray()

        val first = ContentPadding.pad(message)
        val second = ContentPadding.pad(message)

        assertEquals(first.size, second.size)
        assertNotEquals(
            "padding bytes repeated between calls",
            first.toList(),
            second.toList(),
        )
    }

    @Test
    fun `the padded message still parses and preserves every field`() {
        val original = content {
            text = textMessage {
                body = "keep me intact ✓"
                timestamp = 1758000000000L
            }
            groupId = "group-1"
            senderAccountId = "6f1a2b3c-4d5e-4f60-8899-aabbccddeeff"
            senderDeviceId = 3
            expiresAfterMs = 86_400_000L
        }

        val parsed = Content.parseFrom(ContentPadding.pad(original.toByteArray()))

        assertEquals(original.text.body, parsed.text.body)
        assertEquals(original.text.timestamp, parsed.text.timestamp)
        assertEquals(original.groupId, parsed.groupId)
        assertEquals(original.senderAccountId, parsed.senderAccountId)
        assertEquals(original.senderDeviceId, parsed.senderDeviceId)
        assertEquals(original.expiresAfterMs, parsed.expiresAfterMs)
        assertTrue("padding field was not populated", parsed.padding.size() > 0)
    }
}
