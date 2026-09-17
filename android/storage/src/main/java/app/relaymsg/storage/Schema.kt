package app.relaymsg.storage

/**
 * Versioned schema for the client database. Everything here is encrypted at rest
 * by SQLCipher.
 *
 * **The identity private key and registration id are deliberately NOT here** —
 * they live in the Android Keystore (see [MasterKeyStore]), mirroring iOS where
 * they live only in the Keychain.
 *
 * iOS reached this shape through 18 incremental migrations because it has an
 * installed base to carry forward. Android has none, so the same final shape is
 * created as a single version 1. Table and column names are kept identical to
 * iOS so the two clients' local models stay directly comparable.
 */
internal object Schema {

    const val VERSION = 1

    /** Statements are executed in order inside one transaction. */
    val STATEMENTS: List<String> = listOf(
        // --- libsignal state -------------------------------------------------
        """
        CREATE TABLE remote_identities (
            address       TEXT PRIMARY KEY,      -- peer account id
            identity_key  BLOB NOT NULL,
            verified      INTEGER NOT NULL DEFAULT 0,
            first_seen_at INTEGER NOT NULL,
            -- The key in effect when the user last verified. Lets the UI tell
            -- "never verified" (NULL) from "was verified, key has since changed".
            verified_key  BLOB
        );
        """,
        """
        CREATE TABLE sessions (
            address    TEXT NOT NULL,
            device_id  INTEGER NOT NULL,
            record     BLOB NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (address, device_id)
        );
        """,
        "CREATE TABLE prekeys (id INTEGER PRIMARY KEY, record BLOB NOT NULL);",
        "CREATE TABLE signed_prekeys (id INTEGER PRIMARY KEY, record BLOB NOT NULL);",
        """
        CREATE TABLE kyber_prekeys (
            id     INTEGER PRIMARY KEY,
            record BLOB NOT NULL,
            -- The last-resort Kyber prekey is marked used but never deleted.
            used   INTEGER NOT NULL DEFAULT 0
        );
        """,
        """
        -- Replay protection for the LAST-RESORT Kyber prekey. Relay publishes one
        -- Kyber key per device and never rotates it per-handshake, so the same key
        -- is reused across sessions by design. libsignal guards against a replayed
        -- PreKeySignalMessage by asking the store whether it has seen this exact
        -- (kyber prekey, signed prekey, base key) tuple before; if it has, the
        -- handshake is refused. Without this table that check cannot be made.
        -- iOS's schema has no equivalent: its Swift KyberPreKeyStore protocol
        -- exposes no base key, so the check happens elsewhere in that API.
        CREATE TABLE kyber_prekey_uses (
            kyber_prekey_id  INTEGER NOT NULL,
            signed_prekey_id INTEGER NOT NULL,
            base_key         BLOB NOT NULL,
            used_at          INTEGER NOT NULL,
            PRIMARY KEY (kyber_prekey_id, signed_prekey_id, base_key)
        );
        """,
        """
        CREATE TABLE sender_keys (
            sender          TEXT NOT NULL,
            sender_device   INTEGER NOT NULL,
            distribution_id TEXT NOT NULL,
            record          BLOB NOT NULL,
            PRIMARY KEY (sender, sender_device, distribution_id)
        );
        """,

        // --- conversations and messages --------------------------------------
        """
        CREATE TABLE conversations (
            id                      TEXT PRIMARY KEY,
            peer_account            TEXT NOT NULL UNIQUE,
            peer_username           TEXT,
            created_at              INTEGER NOT NULL,
            last_message_at         INTEGER,
            group_id                TEXT,
            pinned_at               INTEGER,
            read_at                 INTEGER NOT NULL DEFAULT 0,
            disappearing_seconds    INTEGER NOT NULL DEFAULT 0,
            media_requires_biometric INTEGER NOT NULL DEFAULT 1,
            require_biometric_chat  INTEGER NOT NULL DEFAULT 0,
            hide_previews           INTEGER NOT NULL DEFAULT 0,
            archived                INTEGER NOT NULL DEFAULT 0,
            label                   TEXT,
            screen_security         INTEGER NOT NULL DEFAULT 0,
            notification_sound      TEXT
        );
        """,
        """
        CREATE TABLE messages (
            id                 TEXT PRIMARY KEY,   -- envelope id (in) or client uuid (out)
            conversation_id    TEXT NOT NULL REFERENCES conversations(id),
            is_outgoing        INTEGER NOT NULL,
            body               TEXT NOT NULL,
            timestamp          INTEGER NOT NULL,   -- sender clock; receipts reference this
            status             TEXT NOT NULL,      -- sending|sent|delivered|read|failed|received
            created_at         INTEGER NOT NULL,
            reply_to_timestamp INTEGER,
            reply_to_author    TEXT,
            reply_to_text      TEXT,
            deleted            INTEGER NOT NULL DEFAULT 0,
            sender_account     TEXT,               -- group messages only; NULL for 1:1
            expires_at         INTEGER,
            pinned             INTEGER NOT NULL DEFAULT 0,
            starred            INTEGER NOT NULL DEFAULT 0,
            edited_at          INTEGER
        );
        """,
        "CREATE INDEX idx_messages_conversation ON messages (conversation_id, timestamp);",
        "CREATE INDEX idx_messages_expires_at ON messages (expires_at);",
        "CREATE INDEX idx_messages_starred ON messages (conversation_id, starred) WHERE starred = 1;",
        """
        CREATE TABLE reactions (
            conversation_id  TEXT NOT NULL REFERENCES conversations(id),
            target_timestamp INTEGER NOT NULL,   -- sender clock of the reacted message
            author           TEXT NOT NULL,      -- account id of the reactor
            is_outgoing      INTEGER NOT NULL,
            emoji            TEXT NOT NULL,
            created_at       INTEGER NOT NULL,
            PRIMARY KEY (conversation_id, target_timestamp, author)
        );
        """,
        """
        CREATE TABLE message_receipts (
            conversation_id   TEXT NOT NULL,
            message_timestamp INTEGER NOT NULL,
            member_account    TEXT NOT NULL,
            status            TEXT NOT NULL,
            PRIMARY KEY (conversation_id, message_timestamp, member_account)
        );
        """,

        // --- delivery -----------------------------------------------------
        """
        -- Envelope-level dedup. Double Ratchet decryption is destructive, so
        -- exactly one process may decrypt a given envelope: whoever claims its
        -- id here first proceeds, anyone else skips. Shared with the push path.
        CREATE TABLE processed_envelopes (
            id           TEXT PRIMARY KEY,
            processed_at INTEGER NOT NULL
        );
        """,

        // --- attachments ----------------------------------------------------
        """
        -- The encrypted blob lives on disk; this holds metadata plus the key and
        -- digest needed to fetch and decrypt it.
        CREATE TABLE attachments (
            id           TEXT PRIMARY KEY,   -- relay blob id
            message_id   TEXT NOT NULL REFERENCES messages(id),
            key          BLOB NOT NULL,      -- AES-256-GCM key
            digest       BLOB NOT NULL,      -- SHA-256 of the ciphertext
            content_type TEXT NOT NULL,
            size         INTEGER NOT NULL,
            filename     TEXT,
            width        INTEGER NOT NULL DEFAULT 0,
            height       INTEGER NOT NULL DEFAULT 0,
            downloaded   INTEGER NOT NULL DEFAULT 0,
            ordinal      INTEGER NOT NULL DEFAULT 0
        );
        """,
        "CREATE INDEX idx_attachments_message ON attachments (message_id);",

        // --- groups ---------------------------------------------------------
        """
        -- Groups are client-authoritative: the relay stores no roster at all, so
        -- this table IS the source of truth, updated from GroupUpdate content.
        CREATE TABLE group_state (
            id               TEXT PRIMARY KEY,
            name             TEXT NOT NULL,
            distribution_id  TEXT NOT NULL,
            revision         INTEGER NOT NULL DEFAULT 0,
            description      TEXT NOT NULL DEFAULT '',
            avatar_data      BLOB,
            admins           TEXT NOT NULL DEFAULT '[]',
            is_announce_only INTEGER NOT NULL DEFAULT 0
        );
        """,
        """
        CREATE TABLE group_members (
            group_id   TEXT NOT NULL,
            account_id TEXT NOT NULL,
            PRIMARY KEY (group_id, account_id)
        );
        """,

        // --- profiles, calls, polls, kv ---------------------------------------
        """
        CREATE TABLE profiles (
            account_id   TEXT PRIMARY KEY,
            display_name TEXT,
            avatar_id    TEXT,
            avatar_data  BLOB,
            revision     INTEGER NOT NULL DEFAULT 0
        );
        """,
        """
        CREATE TABLE calls (
            id           TEXT PRIMARY KEY,
            peer_account TEXT NOT NULL,
            peer_name    TEXT NOT NULL,
            direction    TEXT NOT NULL,
            kind         TEXT NOT NULL,
            started_at   INTEGER NOT NULL,
            connected_at INTEGER,
            ended_at     INTEGER,
            outcome      TEXT NOT NULL
        );
        """,
        "CREATE INDEX idx_calls_started_at ON calls (started_at DESC);",
        """
        CREATE TABLE poll_votes (
            conversation_id  TEXT NOT NULL,
            poll_author      TEXT NOT NULL,
            poll_timestamp   INTEGER NOT NULL,
            voter_account    TEXT NOT NULL,
            selected_options TEXT NOT NULL DEFAULT '[]',
            voted_at         INTEGER NOT NULL,
            PRIMARY KEY (conversation_id, poll_author, poll_timestamp, voter_account)
        );
        """,
        "CREATE TABLE kv (key TEXT PRIMARY KEY, value BLOB NOT NULL);",
    )
}
