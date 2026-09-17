package app.relaymsg.proto

import com.google.gson.JsonParser
import com.google.protobuf.ByteString
import com.google.protobuf.MessageLite
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import relay.content.ContentOuterClass
import relay.content.attachmentPointer
import relay.content.callMessage
import relay.content.content
import relay.content.deleteMessage
import relay.content.editMessage
import relay.content.groupUpdate
import relay.content.pollMessage
import relay.content.pollVote
import relay.content.profileUpdate
import relay.content.quote
import relay.content.reactionMessage
import relay.content.receiptMessage
import relay.content.senderKeyDistribution
import relay.content.textMessage
import relay.content.typingMessage
import relay.v1.Relay
import relay.v1.ackRequest
import relay.v1.clientFrame
import relay.v1.deviceListChanged
import relay.v1.deviceMessage
import relay.v1.envelope
import relay.v1.nukeCommand
import relay.v1.queueEmpty
import relay.v1.sendRequest
import relay.v1.sendResponse
import relay.v1.serverFrame

/**
 * Wire-compatibility check against golden vectors produced by the relay's own Go
 * protobuf types (see `android/tools/genvectors`).
 *
 * This is the Stage 1 interop test. It proves the Kotlin codegen agrees with the
 * Go codegen — and therefore with the iOS Swift codegen, which is generated from
 * the same `proto/` schema — about every field number, wire type and proto3
 * default-elision rule. A field number typo or a stale regeneration fails here
 * rather than silently corrupting traffic against the live relay.
 *
 * What is asserted, per vector:
 *  - Go's bytes parse in Kotlin to exactly the message we expect (this is what
 *    catches a wrong field number: the value would land in a different field or
 *    in unknownFields, and equality would fail);
 *  - re-encoding those parsed bytes reproduces the Kotlin-built bytes exactly.
 *
 * Note we deliberately do NOT compare Kotlin's bytes to Go's bytes directly.
 * Protobuf field ORDER is not canonical across implementations — Go emits oneof
 * members after the top-level fields while the Java/Kotlin runtime emits strictly
 * ascending field numbers. Both encodings are valid and every conformant parser
 * accepts either, so a raw byte comparison fails on a difference that is not part
 * of the contract. Normalizing through one implementation keeps the comparison at
 * byte level while ignoring only the ordering freedom the spec actually grants.
 */
class WireVectorsTest {

    private fun bytes(fill: Int, count: Int): ByteString =
        ByteString.copyFrom(ByteArray(count) { fill.toByte() })

    /**
     * Every vector in the golden file, rebuilt with the generated Kotlin DSL.
     * Values must mirror `tools/genvectors/main.go` exactly.
     */
    private val builders: Map<String, MessageLite> = mapOf(

        // ---- relay.content.Content ---------------------------------------

        "content_text_full" to content {
            text = textMessage {
                body = "hello ✓"
                timestamp = 1758000000000L
                quote = quote {
                    targetTimestamp = 1757999999000L
                    author = "acct-a"
                    text = "prior message"
                }
                attachments.add(
                    attachmentPointer {
                        id = "blob-1"
                        key = bytes(0x01, 32)
                        digest = bytes(0x02, 32)
                        contentType = "image/jpeg"
                        size = 4096L
                        filename = "photo.jpg"
                        width = 800
                        height = 600
                    }
                )
            }
            groupId = "group-1"
            padding = bytes(0xAA, 8)
            senderAccountId = "acct-sender"
            senderDeviceId = 3
            expiresAfterMs = 86400000L
            syncRecipient = "acct-peer"
        },

        "content_text_minimal" to content {
            text = textMessage {}
        },

        "content_receipt_read" to content {
            receipt = receiptMessage {
                type = ContentOuterClass.ReceiptMessage.Type.TYPE_READ
                messageTimestamps.addAll(
                    listOf(1758000000001L, 1758000000002L, 1758000000003L)
                )
            }
            senderAccountId = "acct-sender"
            senderDeviceId = 1
        },

        "content_typing_started" to content {
            typing = typingMessage {
                action = ContentOuterClass.TypingMessage.Action.ACTION_STARTED
                timestamp = 1758000000000L
            }
            senderAccountId = "acct-sender"
            senderDeviceId = 1
        },

        "content_reaction" to content {
            reaction = reactionMessage {
                emoji = "🎉"
                targetAuthor = "acct-a"
                targetTimestamp = 1758000000000L
                remove = false
                timestamp = 1758000000500L
            }
            senderAccountId = "acct-sender"
            senderDeviceId = 2
        },

        "content_group_update_add" to content {
            groupUpdate = groupUpdate {
                revision = 7L
                action = ContentOuterClass.GroupUpdate.Action.ADD
                actor = "acct-admin"
                target = "acct-new"
                members.addAll(listOf("acct-admin", "acct-b", "acct-new"))
                admins.add("acct-admin")
                announceOnly = true
                distributionId = "6f1a2b3c-4d5e-4f60-8899-aabbccddeeff"
                inviteKey = bytes(0x33, 32)
            }
            groupId = "group-1"
            senderAccountId = "acct-admin"
            senderDeviceId = 1
        },

        "content_sender_key_distribution" to content {
            senderKeyDistribution = senderKeyDistribution {
                data = bytes(0x44, 48)
                distributionId = "6f1a2b3c-4d5e-4f60-8899-aabbccddeeff"
            }
            groupId = "group-1"
        },

        "content_delete" to content {
            delete = deleteMessage {
                targetTimestamp = 1758000000000L
                targetAuthor = "acct-sender"
            }
            senderAccountId = "acct-sender"
            senderDeviceId = 1
        },

        "content_edit" to content {
            edit = editMessage {
                targetTimestamp = 1758000000000L
                newBody = "edited body"
            }
            senderAccountId = "acct-sender"
            senderDeviceId = 1
        },

        "content_profile" to content {
            profile = profileUpdate {
                displayName = "Ethan"
                avatar = attachmentPointer {
                    id = "blob-avatar"
                    key = bytes(0x05, 32)
                    digest = bytes(0x06, 32)
                    contentType = "image/jpeg"
                    size = 2048L
                }
                timestamp = 1758000000000L
            }
        },

        "content_call_offer" to content {
            call = callMessage {
                type = ContentOuterClass.CallMessage.Type.OFFER
                callId = "call-1"
                sdp = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n"
            }
            senderAccountId = "acct-sender"
            senderDeviceId = 1
        },

        "content_call_group_ring" to content {
            call = callMessage {
                type = ContentOuterClass.CallMessage.Type.GROUP_RING
                callId = "call-2"
                groupId = "group-1"
                participants.addAll(listOf("acct-a", "acct-b", "acct-c"))
            }
            groupId = "group-1"
        },

        "content_poll" to content {
            poll = pollMessage {
                question = "Lunch?"
                options.addAll(listOf("Thai", "Sushi", "Burgers"))
                multiSelect = true
                timestamp = 1758000000000L
            }
            groupId = "group-1"
        },

        "content_poll_vote" to content {
            pollVote = pollVote {
                pollAuthor = "acct-a"
                pollTimestamp = 1758000000000L
                selectedOptions.addAll(listOf(0, 2))
                timestamp = 1758000001000L
            }
            groupId = "group-1"
        },

        // ---- relay.v1 -----------------------------------------------------

        "client_frame_send" to clientFrame {
            id = 42L
            send = sendRequest {
                destinationAccount = "mbx-0123456789abcdef"
                messages.add(
                    deviceMessage {
                        deviceId = 2
                        registrationId = 12345
                        type = Relay.CiphertextType.CIPHERTEXT_TYPE_PREKEY_MESSAGE
                        content = bytes(0x77, 64)
                    }
                )
                clientTimestamp = 1758000000000L
                ephemeral = false
            }
        },

        "client_frame_ack" to clientFrame {
            ack = ackRequest {
                envelopeId = "0123456789abcdef0123456789abcdef"
            }
        },

        "envelope_sealed" to envelope {
            id = "0123456789abcdef0123456789abcdef"
            type = Relay.CiphertextType.CIPHERTEXT_TYPE_MESSAGE
            content = bytes(0x88, 32)
            clientTimestamp = 1758000000000L
            serverTimestamp = 1758000000123L
        },

        "envelope_unsealed_ephemeral" to envelope {
            id = "fedcba9876543210fedcba9876543210"
            senderAccount = "acct-sender"
            senderDevice = 1
            type = Relay.CiphertextType.CIPHERTEXT_TYPE_MESSAGE
            content = bytes(0x99, 16)
            clientTimestamp = 1758000000000L
            serverTimestamp = 1758000000123L
            ephemeral = true
        },

        "server_frame_mismatched_devices" to serverFrame {
            sendResponse = sendResponse {
                replyTo = 42L
                status = Relay.SendStatus.SEND_STATUS_MISMATCHED_DEVICES
                missingDevices.addAll(listOf(2, 3))
                extraDevices.add(9)
                staleDevices.add(4)
                serverTimestamp = 1758000000123L
            }
        },

        "server_frame_queue_empty" to serverFrame {
            queueEmpty = queueEmpty {}
        },

        "server_frame_nuke" to serverFrame {
            nuke = nukeCommand {
                accountId = "acct-sender"
                commandId = "11112222-3333-4444-5555-666677778888"
                creationTimeMs = 1758000000000L
                initiatingDeviceId = 1
                signature = bytes(0xEE, 70)
            }
        },

        "server_frame_device_list_changed" to serverFrame {
            deviceListChanged = deviceListChanged {
                action = Relay.DeviceListChanged.Action.DEVICE_ADDED
                deviceId = 5
            }
        },
    )

    private data class Vector(val name: String, val type: String, val bytes: ByteArray)

    private fun loadVectors(): List<Vector> {
        val stream = checkNotNull(
            javaClass.classLoader?.getResourceAsStream("golden/wire-vectors.json")
        ) { "golden/wire-vectors.json missing — run android/tools/genvectors" }
        val root = stream.reader().use { JsonParser.parseReader(it) }.asJsonObject
        return root.getAsJsonArray("vectors").map { element ->
            val o = element.asJsonObject
            Vector(
                name = o.get("name").asString,
                type = o.get("type").asString,
                bytes = Base64.getDecoder().decode(o.get("bytes").asString),
            )
        }
    }

    @Test
    fun `kotlin codegen decodes the relay's go encoding to the expected message`() {
        val vectors = loadVectors()
        assertTrue("no vectors loaded", vectors.isNotEmpty())
        for (vector in vectors) {
            val expected = requireNotNull(builders[vector.name]) {
                "golden vector '${vector.name}' (${vector.type}) has no Kotlin counterpart " +
                    "in this test — add one so the schema stays covered"
            }
            val parsed = expected.parserForType.parseFrom(vector.bytes)
            assertEquals(
                "decode mismatch for ${vector.name} (${vector.type})",
                expected,
                parsed,
            )
        }
    }

    @Test
    fun `re-encoding the go bytes reproduces the kotlin encoding`() {
        for (vector in loadVectors()) {
            val expected = requireNotNull(builders[vector.name])
            val reEncoded = expected.parserForType.parseFrom(vector.bytes).toByteArray()
            assertEquals(
                "re-encoding mismatch for ${vector.name} (${vector.type})",
                expected.toByteArray().toHex(),
                reEncoded.toHex(),
            )
        }
    }

    @Test
    fun `go and kotlin encodings are the same length`() {
        // Ordering is free, but the SET of encoded fields is not: a field we failed
        // to encode (or encoded spuriously) changes the total length even when every
        // field that is present round-trips cleanly.
        for (vector in loadVectors()) {
            val expected = requireNotNull(builders[vector.name])
            assertEquals(
                "encoded length differs for ${vector.name} (${vector.type})",
                vector.bytes.size,
                expected.toByteArray().size,
            )
        }
    }

    @Test
    fun `every kotlin builder is covered by a golden vector`() {
        val covered = loadVectors().map { it.name }.toSet()
        val uncovered = builders.keys - covered
        assertEquals("Kotlin builders with no golden vector", emptySet<String>(), uncovered)
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
