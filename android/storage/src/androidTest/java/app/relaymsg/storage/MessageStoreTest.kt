package app.relaymsg.storage

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Stage 3 message-store tests. Instrumented — SQLCipher is an Android library. */
@RunWith(AndroidJUnit4::class)
class MessageStoreTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var keys: MasterKeyStore
    private lateinit var store: SecureStore
    private val messages get() = store.messages

    @Before
    fun setUp() {
        keys = MasterKeyStore(context, "test-secrets-${UUID.randomUUID()}")
        store = SecureStore.openInMemory(keys)
    }

    @After
    fun tearDown() {
        store.close()
        keys.wipe()
    }

    private fun peer() = UUID.randomUUID().toString()

    @Test
    fun conversationIsCreatedOncePerPeer() {
        val account = peer()
        val first = messages.conversation(account, username = "alice")
        val second = messages.conversation(account)
        assertEquals(first, second)
        assertEquals(1, messages.conversations().size)
        assertEquals("alice", messages.conversations().first().peerUsername)
    }

    @Test
    fun redeliveredEnvelopeIsIgnored() {
        // At-least-once delivery means the same envelope can arrive twice. The
        // envelope id is the row id, so the second insert must be a no-op rather
        // than a duplicate bubble.
        val conversation = messages.conversation(peer())
        val envelopeId = "0123456789abcdef0123456789abcdef"

        assertTrue(messages.insertMessage(envelopeId, conversation, false, "hi", 1000, MessageStatus.RECEIVED))
        assertFalse(messages.insertMessage(envelopeId, conversation, false, "hi", 1000, MessageStatus.RECEIVED))
        assertEquals(1, messages.messages(conversation).size)
    }

    @Test
    fun envelopeIsClaimedExactlyOnce() {
        // Double Ratchet decryption is destructive, so only one claimant may
        // proceed — this is what stops the app and the push handler from both
        // decrypting the same envelope.
        val id = "envelope-${UUID.randomUUID()}"
        assertTrue(messages.claimEnvelope(id))
        assertFalse(messages.claimEnvelope(id))
        assertTrue(messages.isEnvelopeProcessed(id))

        messages.releaseEnvelope(id)
        assertTrue(messages.claimEnvelope(id))
    }

    @Test
    fun readReceiptIsNotDowngradedByALateDeliveryReceipt() {
        val conversation = messages.conversation(peer())
        messages.insertMessage("m1", conversation, true, "sent", 5000, MessageStatus.SENT)

        messages.applyReceipt(conversation, listOf(5000), MessageStatus.READ)
        assertEquals(MessageStatus.READ, messages.messages(conversation).single().status)

        // Out-of-order receipts are normal; read must win.
        messages.applyReceipt(conversation, listOf(5000), MessageStatus.DELIVERED)
        assertEquals(MessageStatus.READ, messages.messages(conversation).single().status)
    }

    @Test
    fun groupReceiptsAreRecordedPerMember() {
        val conversation = messages.conversation(peer())
        val alice = peer()
        val bob = peer()

        messages.recordGroupReceipt(conversation, alice, listOf(7000), MessageStatus.DELIVERED)
        messages.recordGroupReceipt(conversation, bob, listOf(7000), MessageStatus.READ)
        messages.recordGroupReceipt(conversation, bob, listOf(7000), MessageStatus.DELIVERED)

        val receipts = messages.groupReceipts(conversation, 7000)
        assertEquals(MessageStatus.DELIVERED, receipts[alice])
        // Same no-downgrade rule applies per member.
        assertEquals(MessageStatus.READ, receipts[bob])
    }

    @Test
    fun reactionsReplacePerAuthorAndCanBeRetracted() {
        val conversation = messages.conversation(peer())
        val author = peer()
        messages.insertMessage("m1", conversation, false, "hi", 1000, MessageStatus.RECEIVED)

        messages.setReaction(conversation, 1000, author, false, "👍", remove = false)
        messages.setReaction(conversation, 1000, author, false, "🎉", remove = false)
        assertEquals(listOf("🎉"), messages.messages(conversation).single().reactions.map { it.emoji })

        messages.setReaction(conversation, 1000, author, false, "", remove = true)
        assertTrue(messages.messages(conversation).single().reactions.isEmpty())
    }

    @Test
    fun unsendLeavesATombstoneRatherThanErasingTheRow() {
        val conversation = messages.conversation(peer())
        messages.insertMessage("m1", conversation, false, "regrettable", 1000, MessageStatus.RECEIVED)

        messages.markDeleted(conversation, 1000)
        val message = messages.messages(conversation).single()
        assertTrue(message.isDeleted)
        assertEquals("", message.body)
    }

    @Test
    fun editRewritesTheBodyAndStampsEditedAt() {
        val conversation = messages.conversation(peer())
        messages.insertMessage("m1", conversation, false, "frist", 1000, MessageStatus.RECEIVED)

        messages.editMessage(conversation, 1000, "first")
        val message = messages.messages(conversation).single()
        assertEquals("first", message.body)
        assertTrue((message.editedAt ?: 0) > 0)
    }

    @Test
    fun disappearingMessagesExpireOnceTheTimerElapses() {
        val conversation = messages.conversation(peer())
        messages.setDisappearingSeconds(conversation, 60)

        val sentAt = System.currentTimeMillis()
        messages.insertMessage("m1", conversation, false, "ephemeral", sentAt, MessageStatus.RECEIVED)
        assertEquals(1, messages.messages(conversation).size)

        // Not yet due.
        assertEquals(0, messages.deleteExpiredMessages(now = sentAt + 30_000))
        // Past the timer.
        assertEquals(1, messages.deleteExpiredMessages(now = sentAt + 61_000))
        assertTrue(messages.messages(conversation).isEmpty())
    }

    @Test
    fun groupRosterRoundTrips() {
        // Groups are client-authoritative: this table is the only source of truth.
        val groupId = UUID.randomUUID().toString()
        val distributionId = UUID.randomUUID().toString()
        val members = listOf(peer(), peer(), peer())
        val admins = listOf(members.first())

        messages.upsertGroup(groupId, "Weekend", distributionId, 3, members, admins)

        val group = requireNotNull(messages.group(groupId))
        assertEquals("Weekend", group.name)
        assertEquals(distributionId, group.distributionId)
        assertEquals(3, group.revision)
        assertEquals(members.sorted(), group.members.sorted())
        assertEquals(admins, group.admins)
        assertTrue(messages.groupConversationId(groupId) != null)
    }

    @Test
    fun removingAMemberRotatesTheDistributionId() {
        val groupId = UUID.randomUUID().toString()
        val members = listOf(peer(), peer())
        messages.upsertGroup(groupId, "Trip", UUID.randomUUID().toString(), 1, members, emptyList())
        val before = requireNotNull(messages.group(groupId)).distributionId

        val rotated = UUID.randomUUID().toString()
        messages.upsertGroup(groupId, "Trip", rotated, 2, members.drop(1), emptyList())

        val after = requireNotNull(messages.group(groupId))
        assertEquals(rotated, after.distributionId)
        assertTrue(after.distributionId != before)
        assertEquals(1, after.members.size)
    }

    @Test
    fun profileKeepsTheNewestRevision() {
        val account = peer()
        messages.upsertProfile(account, "Old Name", null, revision = 5)
        // A stale update must not overwrite a newer one.
        messages.upsertProfile(account, "Stale", null, revision = 3)
        assertEquals("Old Name", messages.peerProfile(account)?.displayName)

        messages.upsertProfile(account, "New Name", null, revision = 9)
        assertEquals("New Name", messages.peerProfile(account)?.displayName)
    }

    @Test
    fun profileCarriesStatusAndBio() {
        val account = peer()
        messages.upsertProfile(
            account, "Ada", null, revision = 5,
            status = "Building things", bio = "Longer text about Ada.",
        )
        val stored = messages.peerProfile(account)
        assertEquals("Building things", stored?.status)
        assertEquals("Longer text about Ada.", stored?.bio)
    }

    @Test
    fun clearingStatusAndBioClearsThemLocally() {
        val account = peer()
        messages.upsertProfile(
            account, "Ada", null, revision = 5,
            status = "Building things", bio = "Longer text.",
        )
        // The peer cleared both: the wire carries empty strings, which the
        // receive path maps to null. Newest-wins still applies.
        messages.upsertProfile(account, "Ada", null, revision = 6, status = null, bio = null)
        val stored = messages.peerProfile(account)
        assertNull(stored?.status)
        assertNull(stored?.bio)
        assertEquals("Ada", stored?.displayName)
    }

    @Test
    fun staleProfileDoesNotClearStatusAndBio() {
        val account = peer()
        messages.upsertProfile(
            account, "Ada", null, revision = 9,
            status = "Current", bio = "Current bio.",
        )
        messages.upsertProfile(account, "Old", null, revision = 4, status = null, bio = null)
        val stored = messages.peerProfile(account)
        assertEquals("Current", stored?.status)
        assertEquals("Current bio.", stored?.bio)
    }

    @Test
    fun avatarSavesAtTheSameRevisionAsTheProfileThatAnnouncedIt() {
        val account = peer()
        messages.upsertProfile(account, "Ada", "blob-1", revision = 5, status = "Hi")
        // The download completes after the profile and carries no newer
        // revision; going through upsertProfile would reject it as stale.
        messages.setProfileAvatar(account, "blob-1", byteArrayOf(1, 2, 3))
        val stored = messages.peerProfile(account)
        assertEquals("blob-1", stored?.avatarId)
        assertEquals(3, stored?.avatarData?.size)
        // and it leaves everything else alone
        assertEquals("Ada", stored?.displayName)
        assertEquals("Hi", stored?.status)
        assertEquals(5L, stored?.revision)
    }

    @Test
    fun unreadCountTracksTheReadMarker() {
        val conversation = messages.conversation(peer())
        messages.insertMessage("m1", conversation, false, "one", 1000, MessageStatus.RECEIVED)
        messages.insertMessage("m2", conversation, false, "two", 2000, MessageStatus.RECEIVED)
        assertEquals(2, messages.conversations().single().unreadCount)

        messages.markConversationRead(conversation, at = 2000)
        assertEquals(0, messages.conversations().single().unreadCount)

        messages.markConversationUnread(conversation)
        assertTrue(messages.conversations().single().unreadCount > 0)
    }

    @Test
    fun wipeRemovesEverything() {
        val conversation = messages.conversation(peer())
        messages.insertMessage("m1", conversation, false, "secret", 1000, MessageStatus.RECEIVED)
        messages.kvPut("token", byteArrayOf(1, 2, 3))

        store.wipe()

        assertTrue(messages.conversations().isEmpty())
        assertNull(messages.kvGet("token"))
    }

    @Test
    fun searchFindsMessagesAndIgnoresWildcards() {
        val conversation = messages.conversation(peer())
        messages.insertMessage("m1", conversation, false, "dinner at eight", 1000, MessageStatus.RECEIVED)
        messages.insertMessage("m2", conversation, false, "100% sure", 2000, MessageStatus.RECEIVED)

        assertEquals(1, messages.searchMessages("dinner").size)
        // '%' is a LIKE wildcard; it must be escaped or this would match everything.
        assertEquals(1, messages.searchMessages("100%").size)
    }
}
