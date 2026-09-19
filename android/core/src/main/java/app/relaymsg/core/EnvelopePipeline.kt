package app.relaymsg.core

import app.relaymsg.net.IncomingEnvelope
import app.relaymsg.storage.MessageStatus
import app.relaymsg.storage.MessageStore
import app.relaymsg.storage.QuotedMessage
import app.relaymsg.storage.StoredAttachment
import relay.content.ContentOuterClass.Content
import relay.content.ContentOuterClass.GroupUpdate
import relay.content.ContentOuterClass.ReceiptMessage
import java.util.UUID
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
        val callSignal: CallSignal? = null,
        /** An avatar the caller should fetch and store against [peerAccount]. */
        val profileAvatar: relay.content.ContentOuterClass.AttachmentPointer? = null,
        val isDuplicate: Boolean = false,
    )

    /**
     * Decrypts and applies one envelope.
     *
     * Failures are the caller's to handle, but note the contract: an envelope
     * that cannot be decrypted must still be **acked and dropped**, or it
     * redelivers forever (PROTOCOL.md §4.3).
     */
    /**
     * Whether a sender is blocked. Installed by [RelayService] after
     * construction, because the block list lives with the account rather than
     * the pipeline.
     */
    var isBlocked: (String) -> Boolean = { false }

    fun apply(envelope: IncomingEnvelope): Outcome {
        val decrypted = messenger.processEnvelope(envelope)
            ?: return Outcome(null, null, isDuplicate = true)

        val content = decrypted.content
        val sender = decrypted.senderAccount
        val groupId = content.groupId.ifEmpty { null }

        // Blocked: decrypted and discarded, never stored and never notified.
        // The decryption still had to happen — the ratchet advances either way,
        // and skipping it would desynchronise the session for good. The caller
        // acks regardless, so the relay stops redelivering it.
        if (sender.isNotEmpty() && isBlocked(sender)) {
            return Outcome(null, null)
        }

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
            Content.BodyCase.POLL -> {
                // Stored as a message with iOS's `__poll__:` body, so it takes
                // its place in the thread rather than needing a table of its own.
                val payload = PollPayload(
                    question = content.poll.question,
                    options = content.poll.optionsList.toList(),
                    multiSelect = content.poll.multiSelect,
                )
                messages.insertMessage(
                    id = envelope.id,
                    conversationId = conversationId,
                    isOutgoing = isSync,
                    body = payload.encodeBody(),
                    // The poll's own timestamp is its id, so votes can reference
                    // it; the envelope's would not match what the author sent.
                    timestamp = content.poll.timestamp,
                    status = MessageStatus.RECEIVED,
                    senderAccount = sender,
                )
                Outcome(
                    conversationId = conversationId,
                    peerAccount = sender,
                    notificationBody = if (isSync) null else content.poll.question,
                )
            }

            Content.BodyCase.POLL_VOTE -> {
                messages.upsertPollVote(
                    conversationId = conversationId,
                    pollAuthor = content.pollVote.pollAuthor,
                    pollTimestamp = content.pollVote.pollTimestamp,
                    voterAccount = sender,
                    selectedOptions = content.pollVote.selectedOptionsList.map { it.toInt() },
                    votedAt = content.pollVote.timestamp,
                )
                Outcome(conversationId, sender)
            }

            Content.BodyCase.PROFILE -> {
                // The name lands now; the avatar is a pointer, so fetching it is
                // the caller's job — this function is not suspending and a
                // profile must not wait on a download to take effect.
                messages.upsertProfile(
                    account = sender,
                    displayName = content.profile.displayName.ifEmpty { null },
                    avatarId = content.profile.avatar.id.ifEmpty { null },
                    revision = content.profile.timestamp,
                    // Empty means cleared, not absent: the sender publishes the
                    // whole profile each time, so an empty string is them
                    // removing it rather than an older client omitting it.
                    status = content.profile.status.ifEmpty { null },
                    bio = content.profile.bio.ifEmpty { null },
                )
                Outcome(
                    conversationId = conversationId,
                    peerAccount = sender,
                    profileAvatar = if (content.profile.hasAvatar()) content.profile.avatar else null,
                )
            }

            Content.BodyCase.SENDER_KEY_DISTRIBUTION -> {
                // A member handing us their sender key for the current epoch.
                // Must be processed before any of their group messages can be
                // decrypted, and it arrives over a pairwise session precisely so
                // it does not depend on already having one.
                messenger.processSenderKeyDistribution(
                    content.senderKeyDistribution.data.toByteArray(),
                    sender,
                    decrypted.senderDeviceId,
                )
                Outcome(conversationId, sender)
            }

            Content.BodyCase.GROUP_UPDATE -> applyGroupUpdate(content, sender, groupId)

            Content.BodyCase.CALL -> Outcome(
                conversationId = conversationId,
                peerAccount = sender,
                // Call signals are routed to the call manager rather than stored;
                // the caller decides what to do with them.
                callSignal = CallSignalling.parse(content, sender),
            )

            Content.BodyCase.TYPING -> Outcome(
                conversationId = conversationId,
                peerAccount = sender,
                typingStarted = content.typing.action == TypingMessage.Action.ACTION_STARTED,
            )
            else -> Outcome(conversationId, sender)
        }
    }

    /**
     * Applies a roster or metadata change.
     *
     * Groups are client-authoritative — the relay stores nothing — so this table
     * IS the roster, and [Content.getGroupId] plus the update's member list is
     * the only source of truth (PROTOCOL.md §0.2, §7.3).
     */
    private fun applyGroupUpdate(content: Content, sender: String, groupId: String?): Outcome {
        val update = content.groupUpdate
        val id = groupId ?: return Outcome(null, sender)
        val existing = messages.group(id)

        // `revision` exists to drop stale updates: at-least-once delivery and
        // per-device fan-out mean the same change can arrive more than once, and
        // out of order relative to a newer one.
        if (existing != null && update.revision in 1..existing.revision) {
            return Outcome(messages.groupConversationId(id), sender)
        }

        // An empty distribution_id means "metadata only, keep the current epoch".
        // A non-empty one on a REMOVE is the actor rotating it so the removed
        // member cannot read anything further.
        val distributionId = update.distributionId.ifEmpty {
            existing?.distributionId ?: UUID.randomUUID().toString()
        }
        val members = if (update.membersList.isNotEmpty()) {
            update.membersList.toList()
        } else {
            existing?.members.orEmpty()
        }
        val admins = if (update.adminsList.isNotEmpty()) {
            update.adminsList.toList()
        } else {
            existing?.admins.orEmpty()
        }

        messages.upsertGroup(
            id = id,
            name = update.name.ifEmpty { existing?.name ?: "Group" },
            distributionId = distributionId,
            revision = maxOf(update.revision, existing?.revision ?: 0),
            members = members,
            admins = admins,
            isAnnounceOnly = if (update.action == GroupUpdate.Action.SET_ANNOUNCE_ONLY) {
                update.announceOnly
            } else {
                existing?.isAnnounceOnly == true
            },
        )
        if (update.description.isNotEmpty()) messages.setGroupDescription(id, update.description)
        if (update.hasAvatar() || update.announceOnly != (existing?.isAnnounceOnly ?: false)) {
            messages.setGroupAnnounceOnly(id, update.announceOnly)
        }

        return Outcome(
            conversationId = messages.groupConversationId(id),
            peerAccount = sender,
            notificationBody = null, // roster changes are system lines, not notifications
        )
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
