package app.relaymsg.core

import app.relaymsg.net.IncomingEnvelope
import app.relaymsg.storage.MessageStatus
import app.relaymsg.storage.MessageStore
import app.relaymsg.storage.QuotedMessage
import app.relaymsg.storage.StoredAttachment
import relay.content.ContentOuterClass.Content
import relay.content.ContentOuterClass.ReceiptMessage
import relay.content.ContentOuterClass.TypingMessage

/**
 * Applies a decrypted `Content` to local storage — the counterpart of iOS's
 * `EnvelopeProcessor`, minus the network side effects, which are returned rather
 * than performed so the caller decides whether to act on them.
 */
class EnvelopePipeline(
    private val messenger: RelayMessenger,
    private val messages: MessageStore,
    private val ownAccountId: String,
) {
    /** What the caller should do after a message was applied. */
    data class Outcome(
        val conversationId: String?,
        val peerAccount: String?,
        /** Send a delivery receipt for this sender timestamp; null when not needed. */
        val deliveryReceiptFor: Long? = null,
        val notificationBody: String? = null,
        val typingStarted: Boolean? = null,
        val isDuplicate: Boolean = false,
    )

    /**
     * Decrypts and applies one envelope.
     *
     * Failures are the caller's to handle, but note the contract: an envelope
     * that cannot be decrypted must still be **acked and dropped**, or it
     * redelivers forever (PROTOCOL.md §4.3).
     */
    fun apply(envelope: IncomingEnvelope): Outcome {
        val decrypted = messenger.processEnvelope(envelope)
            ?: return Outcome(null, null, isDuplicate = true)

        val content = decrypted.content
        val sender = decrypted.senderAccount
        val groupId = content.groupId.ifEmpty { null }

        // A sync copy is our own message echoed to our other devices; it belongs
        // in the conversation with the ORIGINAL recipient, stored as outgoing.
        val isSync = ownAccountId.isNotEmpty() &&
            sender == ownAccountId &&
            content.syncRecipient.isNotEmpty()

        val conversationId = messages.conversation(
            account = when {
                isSync -> content.syncRecipient
                groupId != null -> groupId
                else -> sender
            },
        )

        // Keep the disappearing timer in lockstep with the sender, before the
        // message is inserted so the new timer applies to it.
        if (content.expiresAfterMs > 0) {
            messages.setDisappearingSeconds(conversationId, content.expiresAfterMs / 1000)
        }

        return when (content.bodyCase) {
            Content.BodyCase.TEXT -> applyText(content, envelope, conversationId, sender, groupId, isSync)
            Content.BodyCase.RECEIPT -> applyReceipt(content, conversationId, sender, groupId)
            Content.BodyCase.REACTION -> applyReaction(content, conversationId, sender, isSync)
            Content.BodyCase.DELETE -> {
                messages.markDeleted(conversationId, content.delete.targetTimestamp)
                Outcome(conversationId, sender)
            }
            Content.BodyCase.EDIT -> {
                messages.editMessage(conversationId, content.edit.targetTimestamp, content.edit.newBody)
                Outcome(conversationId, sender)
            }
            Content.BodyCase.TYPING -> Outcome(
                conversationId = conversationId,
                peerAccount = sender,
                typingStarted = content.typing.action == TypingMessage.Action.ACTION_STARTED,
            )
            else -> Outcome(conversationId, sender)
        }
    }

    private fun applyText(
        content: Content,
        envelope: IncomingEnvelope,
        conversationId: String,
        sender: String,
        groupId: String?,
        isSync: Boolean,
    ): Outcome {
        val text = content.text
        val quote = if (text.hasQuote()) {
            QuotedMessage(text.quote.targetTimestamp, text.quote.author, text.quote.text)
        } else {
            null
        }
        val attachments = text.attachmentsList.map { pointer ->
            StoredAttachment(
                id = pointer.id,
                key = pointer.key.toByteArray(),
                digest = pointer.digest.toByteArray(),
                contentType = pointer.contentType,
                size = pointer.size,
                filename = pointer.filename.ifEmpty { null },
                width = pointer.width,
                height = pointer.height,
                isDownloaded = false,
            )
        }

        // The envelope id is the row id, which is what makes at-least-once
        // delivery safe: a redelivered envelope collides and is ignored.
        val inserted = messages.insertMessage(
            id = envelope.id,
            conversationId = conversationId,
            isOutgoing = isSync,
            body = text.body,
            timestamp = text.timestamp,
            status = if (isSync) MessageStatus.SENT else MessageStatus.RECEIVED,
            replyTo = quote,
            attachments = attachments,
            senderAccount = if (groupId == null) null else sender,
        )

        return Outcome(
            conversationId = conversationId,
            peerAccount = if (isSync) content.syncRecipient else sender,
            // Only receipt a message we actually stored, and never our own sync copy.
            deliveryReceiptFor = if (inserted && !isSync) text.timestamp else null,
            notificationBody = if (inserted && !isSync) {
                text.body.ifEmpty { if (attachments.isEmpty()) "" else "📷 Photo" }
            } else {
                null
            },
        )
    }

    private fun applyReceipt(
        content: Content,
        conversationId: String,
        sender: String,
        groupId: String?,
    ): Outcome {
        val status = if (content.receipt.type == ReceiptMessage.Type.TYPE_READ) {
            MessageStatus.READ
        } else {
            MessageStatus.DELIVERED
        }
        if (groupId != null) {
            messages.recordGroupReceipt(
                conversationId, sender, content.receipt.messageTimestampsList, status,
            )
        } else {
            messages.applyReceipt(conversationId, content.receipt.messageTimestampsList, status)
        }
        return Outcome(conversationId, sender)
    }

    private fun applyReaction(
        content: Content,
        conversationId: String,
        sender: String,
        isSync: Boolean,
    ): Outcome {
        messages.setReaction(
            conversationId = conversationId,
            targetTimestamp = content.reaction.targetTimestamp,
            author = sender,
            isOutgoing = isSync,
            emoji = content.reaction.emoji,
            remove = content.reaction.remove,
        )
        return Outcome(
            conversationId = conversationId,
            peerAccount = sender,
            notificationBody = if (content.reaction.remove || isSync) {
                null
            } else {
                "Reacted ${content.reaction.emoji}"
            },
        )
    }
}
