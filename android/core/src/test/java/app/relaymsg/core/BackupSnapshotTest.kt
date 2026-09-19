package app.relaymsg.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BackupSnapshotTest {

    private fun snapshot() = BackupSnapshot(
        conversations = listOf(
            BackupSnapshot.Conversation(
                peerAccount = "acct-1",
                username = "alice",
                groupId = null,
                messages = listOf(
                    BackupSnapshot.Message(
                        id = "m1", body = "hello", timestamp = 1_700_000_000_000,
                        isOutgoing = true, status = "read", senderAccount = null,
                        replyTimestamp = null, replyAuthor = null, replyText = null,
                    ),
                    BackupSnapshot.Message(
                        id = "m2", body = "hi back", timestamp = 1_700_000_001_000,
                        isOutgoing = false, status = "received", senderAccount = "acct-1",
                        replyTimestamp = 1_700_000_000_000, replyAuthor = "acct-0", replyText = "hello",
                    ),
                ),
            ),
        ),
        groups = listOf(
            BackupSnapshot.Group(
                id = "g1", name = "Crew", distributionId = "dist-1", revision = 3,
                members = listOf("acct-0", "acct-1"), admins = listOf("acct-0"),
                isAnnounceOnly = true,
            ),
        ),
    )

    @Test
    fun `round-trips`() {
        val decoded = BackupSnapshot.decode(snapshot().encode())
        assertEquals(snapshot(), decoded)
    }

    @Test
    fun `uses the field names iOS encodes`() {
        val json = snapshot().toJson()
        assertEquals(1, json.getInt("version"))
        val conversation = json.getJSONArray("conversations").getJSONObject(0)
        assertEquals("acct-1", conversation.getString("peerAccount"))
        assertEquals("alice", conversation.getString("username"))
        val message = conversation.getJSONArray("messages").getJSONObject(1)
        assertEquals("m2", message.getString("id"))
        assertEquals("hi back", message.getString("body"))
        assertFalse(message.getBoolean("isOutgoing"))
        assertEquals("received", message.getString("status"))
        assertEquals("acct-1", message.getString("senderAccount"))
        assertEquals(1_700_000_000_000, message.getLong("replyTimestamp"))
        assertEquals("acct-0", message.getString("replyAuthor"))
        val group = json.getJSONArray("groups").getJSONObject(0)
        assertEquals("dist-1", group.getString("distributionId"))
        assertEquals(3, group.getLong("revision"))
        assertTrue(group.getBoolean("isAnnounceOnly"))
        assertEquals(2, group.getJSONArray("members").length())
    }

    @Test
    fun `omits absent optionals the way Swift's encoder does`() {
        val message = snapshot().toJson()
            .getJSONArray("conversations").getJSONObject(0)
            .getJSONArray("messages").getJSONObject(0)
        assertFalse(message.has("senderAccount"))
        assertFalse(message.has("replyTimestamp"))
        assertFalse(message.has("replyAuthor"))
        assertFalse(message.has("replyText"))
    }

    @Test
    fun `reads a snapshot written with explicit nulls`() {
        // Not what Swift writes, but its decoder accepts it, so ours does too.
        val json = JSONObject(
            """
            {"version":1,"groups":[],"conversations":[
              {"peerAccount":"a","username":null,"groupId":null,"messages":[
                {"id":"m","body":"b","timestamp":1,"isOutgoing":true,"status":"sent",
                 "senderAccount":null,"replyTimestamp":null,"replyAuthor":null,"replyText":null}
              ]}
            ]}
            """.trimIndent(),
        )
        val decoded = BackupSnapshot.fromJson(json)
        val conversation = decoded.conversations.single()
        assertNull(conversation.username)
        assertNull(conversation.groupId)
        assertNull(conversation.messages.single().replyTimestamp)
    }

    @Test
    fun `tolerates a snapshot with no groups key at all`() {
        val decoded = BackupSnapshot.fromJson(JSONObject("""{"version":1,"conversations":[]}"""))
        assertTrue(decoded.groups.isEmpty())
        assertTrue(decoded.conversations.isEmpty())
    }
}
