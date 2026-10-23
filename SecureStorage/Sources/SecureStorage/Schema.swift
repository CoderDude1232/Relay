//
//  Schema.swift
//  SecureStorage
//
//  Versioned migrations for the client database, encrypted at rest by
//  SQLCipher. The identity private key is not stored here; it lives in the
//  Keychain (KeychainSecureStore).
//

import Foundation

enum Schema {
    /// Runs one migration step atomically and idempotently. The app and the NSE
    /// may open the file at the same time after an update, so each step takes the
    /// write lock (BEGIN IMMEDIATE; the other process waits on the busy timeout),
    /// re-reads `user_version` inside the transaction, and skips the step if it
    /// is already applied. `body` must set `user_version` to `version`.
    private static func step(_ db: Database, to version: Int64, _ body: () throws -> Void) throws {
        // Unlocked pre-check so a migrated DB doesn't take the write lock for every
        // step on each open.
        if try userVersion(db) >= version { return }
        try db.transaction {
            guard try userVersion(db) < version else { return }
            try body()
        }
    }

    static func userVersion(_ db: Database) throws -> Int64 {
        try db.query("PRAGMA user_version;").first?.first?.int64 ?? 0
    }

    static func migrate(_ db: Database) throws {
        try step(db, to: 1) {
            try db.run("""
                CREATE TABLE remote_identities (
                    address       TEXT PRIMARY KEY,      -- peer account id
                    identity_key  BLOB NOT NULL,
                    verified      INTEGER NOT NULL DEFAULT 0,
                    first_seen_at INTEGER NOT NULL
                );
                """)
            try db.run("""
                CREATE TABLE sessions (
                    address    TEXT NOT NULL,
                    device_id  INTEGER NOT NULL,
                    record     BLOB NOT NULL,
                    updated_at INTEGER NOT NULL,
                    PRIMARY KEY (address, device_id)
                );
                """)
            try db.run("CREATE TABLE prekeys (id INTEGER PRIMARY KEY, record BLOB NOT NULL);")
            try db.run("CREATE TABLE signed_prekeys (id INTEGER PRIMARY KEY, record BLOB NOT NULL);")
            try db.run("""
                CREATE TABLE kyber_prekeys (
                    id     INTEGER PRIMARY KEY,
                    record BLOB NOT NULL,
                    used   INTEGER NOT NULL DEFAULT 0
                );
                """)
            try db.run("""
                CREATE TABLE sender_keys (
                    sender          TEXT NOT NULL,
                    sender_device   INTEGER NOT NULL,
                    distribution_id TEXT NOT NULL,
                    record          BLOB NOT NULL,
                    PRIMARY KEY (sender, sender_device, distribution_id)
                );
                """)
            try db.run("""
                CREATE TABLE conversations (
                    id              TEXT PRIMARY KEY,
                    peer_account    TEXT NOT NULL UNIQUE,
                    peer_username   TEXT,
                    created_at      INTEGER NOT NULL,
                    last_message_at INTEGER
                );
                """)
            try db.run("""
                CREATE TABLE messages (
                    id              TEXT PRIMARY KEY,      -- envelope id (incoming) or client uuid (outgoing)
                    conversation_id TEXT NOT NULL REFERENCES conversations(id),
                    is_outgoing     INTEGER NOT NULL,
                    body            TEXT NOT NULL,
                    timestamp       INTEGER NOT NULL,      -- sender clock; doubles as receipt reference
                    status          TEXT NOT NULL,         -- sending|sent|delivered|read|failed|received
                    created_at      INTEGER NOT NULL
                );
                """)
            try db.run("""
                CREATE INDEX idx_messages_conversation
                    ON messages (conversation_id, timestamp);
                """)
            try db.run("CREATE TABLE kv (key TEXT PRIMARY KEY, value BLOB NOT NULL);")
            try db.run("PRAGMA user_version = 1;")
        }
        try step(db, to: 2) {
            // The identity key in effect when the user last verified a peer. NULL means
            // never verified; a value differing from identity_key means the key changed.
            try db.run("ALTER TABLE remote_identities ADD COLUMN verified_key BLOB;")
            try db.run("PRAGMA user_version = 2;")
        }
        try step(db, to: 3) {
            // Replies and reactions. A quote is a snapshot stored on the reply, so it
            // renders without a lookup and survives deletion of the original. Reactions
            // reference their target by (conversation, sender timestamp).
            try db.run("ALTER TABLE messages ADD COLUMN reply_to_timestamp INTEGER;")
            try db.run("ALTER TABLE messages ADD COLUMN reply_to_author TEXT;")
            try db.run("ALTER TABLE messages ADD COLUMN reply_to_text TEXT;")
            try db.run("""
                CREATE TABLE reactions (
                    conversation_id  TEXT NOT NULL REFERENCES conversations(id),
                    target_timestamp INTEGER NOT NULL,   -- sender clock of the reacted message
                    author           TEXT NOT NULL,       -- account id of the reactor
                    is_outgoing      INTEGER NOT NULL,    -- 1 if the local user reacted
                    emoji            TEXT NOT NULL,
                    created_at       INTEGER NOT NULL,
                    PRIMARY KEY (conversation_id, target_timestamp, author)
                );
                """)
            try db.run("PRAGMA user_version = 3;")
        }
        try step(db, to: 4) {
            // Unsend tombstones: the row keeps its place but its plaintext is cleared.
            try db.run("ALTER TABLE messages ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;")
            try db.run("PRAGMA user_version = 4;")
        }
        try step(db, to: 5) {
            // Envelope dedup shared by the app and the NSE. Ratchet decryption is
            // destructive, so only one process may handle an envelope: whoever claims
            // its id first.
            try db.run("""
                CREATE TABLE processed_envelopes (
                    id           TEXT PRIMARY KEY,
                    processed_at INTEGER NOT NULL
                );
                """)
            try db.run("PRAGMA user_version = 5;")
        }
        try step(db, to: 6) {
            // Attachments. The encrypted blob lives on disk in the App Group container;
            // this table holds metadata and the key and digest to fetch and decrypt it.
            // `downloaded` is set once the ciphertext is cached.
            try db.run("""
                CREATE TABLE attachments (
                    id           TEXT PRIMARY KEY,   -- relay blob id
                    message_id   TEXT NOT NULL REFERENCES messages(id),
                    key          BLOB NOT NULL,       -- AES-256-GCM key
                    digest       BLOB NOT NULL,       -- SHA-256 of ciphertext
                    content_type TEXT NOT NULL,
                    size         INTEGER NOT NULL,
                    filename     TEXT,
                    width        INTEGER NOT NULL DEFAULT 0,
                    height       INTEGER NOT NULL DEFAULT 0,
                    downloaded   INTEGER NOT NULL DEFAULT 0,
                    ordinal      INTEGER NOT NULL DEFAULT 0
                );
                """)
            try db.run("CREATE INDEX idx_attachments_message ON attachments (message_id);")
            try db.run("PRAGMA user_version = 6;")
        }
        try step(db, to: 7) {
            // Groups: a conversation with `group_id` set, with roster and metadata in
            // group_state and group_members. `sender_account` attributes group messages
            // and is null for 1:1.
            try db.run("ALTER TABLE conversations ADD COLUMN group_id TEXT;")
            try db.run("ALTER TABLE messages ADD COLUMN sender_account TEXT;")
            try db.run("""
                CREATE TABLE group_state (
                    id              TEXT PRIMARY KEY,
                    name            TEXT NOT NULL,
                    distribution_id TEXT NOT NULL,
                    revision        INTEGER NOT NULL DEFAULT 0
                );
                """)
            try db.run("""
                CREATE TABLE group_members (
                    group_id   TEXT NOT NULL,
                    account_id TEXT NOT NULL,
                    PRIMARY KEY (group_id, account_id)
                );
                """)
            try db.run("PRAGMA user_version = 7;")
        }

        try step(db, to: 8) {
            // Peer profiles (display name and avatar). avatar_data is the decrypted
            // image; avatar_id tracks the source blob so unchanged avatars aren't
            // downloaded again. revision is the sender's clock; newest wins.
            try db.run("""
                CREATE TABLE profiles (
                    account_id   TEXT PRIMARY KEY,
                    display_name TEXT,
                    avatar_id    TEXT,
                    avatar_data  BLOB,
                    revision     INTEGER NOT NULL DEFAULT 0
                );
                """)
            try db.run("PRAGMA user_version = 8;")
        }

        try step(db, to: 9) {
            // Per-member receipts for group messages, keyed by the message's sender
            // clock, for "Read by N" and the aggregate status. 1:1 messages use the
            // status column.
            try db.run("""
                CREATE TABLE message_receipts (
                    conversation_id   TEXT NOT NULL,
                    message_timestamp INTEGER NOT NULL,
                    member_account    TEXT NOT NULL,
                    status            TEXT NOT NULL,
                    PRIMARY KEY (conversation_id, message_timestamp, member_account)
                );
                """)
            try db.run("PRAGMA user_version = 9;")
        }

        try step(db, to: 10) {
            // Calls are stored apart from messages so the Calls tab can show missed,
            // failed, declined and completed calls.
            try db.run("""
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
                """)
            try db.run("CREATE INDEX idx_calls_started_at ON calls (started_at DESC);")
            try db.run("PRAGMA user_version = 10;")
        }

        try step(db, to: 11) {
            // Pinned order, local read position, disappearing-message TTL, per-chat
            // privacy controls.
            try db.run("ALTER TABLE conversations ADD COLUMN pinned_at INTEGER;")
            try db.run("ALTER TABLE conversations ADD COLUMN read_at INTEGER NOT NULL DEFAULT 0;")
            try db.run("ALTER TABLE conversations ADD COLUMN disappearing_seconds INTEGER NOT NULL DEFAULT 0;")
            try db.run("ALTER TABLE conversations ADD COLUMN media_requires_biometric INTEGER NOT NULL DEFAULT 1;")
            try db.run("ALTER TABLE conversations ADD COLUMN require_biometric_chat INTEGER NOT NULL DEFAULT 0;")
            try db.run("ALTER TABLE conversations ADD COLUMN hide_previews INTEGER NOT NULL DEFAULT 0;")
            try db.run("ALTER TABLE messages ADD COLUMN expires_at INTEGER;")
            try db.run("CREATE INDEX idx_messages_expires_at ON messages (expires_at);")
            try db.run("PRAGMA user_version = 11;")
        }

        try step(db, to: 12) {
            // Archived conversations and pinned messages.
            try db.run("ALTER TABLE conversations ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;")
            try db.run("ALTER TABLE messages ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;")
            try db.run("PRAGMA user_version = 12;")
        }

        try step(db, to: 13) {
            // Starred messages: a personal bookmark, unlike conversation-wide pins.
            try db.run("ALTER TABLE messages ADD COLUMN starred INTEGER NOT NULL DEFAULT 0;")
            try db.run("CREATE INDEX idx_messages_starred ON messages (conversation_id, starred) WHERE starred = 1;")
            try db.run("PRAGMA user_version = 13;")
        }

        try step(db, to: 14) {
            // User-defined conversation labels for filtering.
            try db.run("ALTER TABLE conversations ADD COLUMN label TEXT;")
            try db.run("PRAGMA user_version = 14;")
        }

        try step(db, to: 15) {
            // Screen-capture protection and custom notification sound (nil = default).
            try db.run("ALTER TABLE conversations ADD COLUMN screen_security INTEGER NOT NULL DEFAULT 0;")
            try db.run("ALTER TABLE conversations ADD COLUMN notification_sound TEXT;")
            try db.run("PRAGMA user_version = 15;")
        }

        try step(db, to: 16) {
            // Group description and avatar.
            try db.run("ALTER TABLE group_state ADD COLUMN description TEXT NOT NULL DEFAULT '';")
            try db.run("ALTER TABLE group_state ADD COLUMN avatar_data BLOB;")
            try db.run("PRAGMA user_version = 16;")
        }

        try step(db, to: 17) {
            // Last edit time; NULL means unedited.
            try db.run("ALTER TABLE messages ADD COLUMN edited_at INTEGER;")
            try db.run("PRAGMA user_version = 17;")
        }

        try step(db, to: 18) {
            // Group admins and announce-only mode. Poll votes keyed by (conversation,
            // poll_author, poll_timestamp, voter_account).
            try db.run("ALTER TABLE group_state ADD COLUMN admins TEXT NOT NULL DEFAULT '[]';")
            try db.run("ALTER TABLE group_state ADD COLUMN is_announce_only INTEGER NOT NULL DEFAULT 0;")
            try db.run("""
                CREATE TABLE IF NOT EXISTS poll_votes (
                    conversation_id  TEXT NOT NULL,
                    poll_author      TEXT NOT NULL,
                    poll_timestamp   INTEGER NOT NULL,
                    voter_account    TEXT NOT NULL,
                    selected_options TEXT NOT NULL DEFAULT '[]',
                    voted_at         INTEGER NOT NULL,
                    PRIMARY KEY (conversation_id, poll_author, poll_timestamp, voter_account)
                );
                """)
            try db.run("PRAGMA user_version = 18;")
        }

        try step(db, to: 19) {
            // Key peer identities by (address, device_id). Keyed by account alone, a
            // second device looked like a key replacement and blocked sends. SQLite
            // can't alter a PRIMARY KEY, so recreate the table; existing rows move to
            // device_id = 1 and refill on the next bundle fetch. verified and
            // verified_key are kept per row.
            try db.run("""
                CREATE TABLE remote_identities_v19 (
                    address       TEXT NOT NULL,
                    device_id     INTEGER NOT NULL,
                    identity_key  BLOB NOT NULL,
                    verified      INTEGER NOT NULL DEFAULT 0,
                    verified_key  BLOB,
                    first_seen_at INTEGER NOT NULL,
                    PRIMARY KEY (address, device_id)
                );
                """)
            try db.run("""
                INSERT INTO remote_identities_v19
                    (address, device_id, identity_key, verified, verified_key, first_seen_at)
                SELECT address, 1, identity_key, verified, verified_key, first_seen_at
                FROM remote_identities;
                """)
            try db.run("DROP TABLE remote_identities;")
            try db.run("ALTER TABLE remote_identities_v19 RENAME TO remote_identities;")
            try db.run("PRAGMA user_version = 19;")
        }

        try step(db, to: 20) {
            // Profile status line and bio.
            try db.run("ALTER TABLE profiles ADD COLUMN status TEXT;")
            try db.run("ALTER TABLE profiles ADD COLUMN bio TEXT;")
            try db.run("PRAGMA user_version = 20;")
        }

        try step(db, to: 21) {
            // Profile links as a JSON array of {label,url}.
            try db.run("ALTER TABLE profiles ADD COLUMN links TEXT;")
            try db.run("PRAGMA user_version = 21;")
        }

        try step(db, to: 22) {
            // Screenshot protection. The effective state is the OR of our
            // `screen_security` and the peer's `peer_screen_security`, so content is
            // hidden unless both sides turn it off. Groups use an admin flag on
            // group_state. Everything defaults on, including existing conversations.
            try db.run("ALTER TABLE conversations ADD COLUMN peer_screen_security INTEGER NOT NULL DEFAULT 0;")
            try db.run("UPDATE conversations SET screen_security = 1;")
            try db.run("ALTER TABLE group_state ADD COLUMN screen_security INTEGER NOT NULL DEFAULT 1;")
            try db.run("PRAGMA user_version = 22;")
        }
        try step(db, to: 23) {
            // Message requests: a 1:1 or group chat someone else started is held
            // until accepted. Every existing conversation counts as accepted.
            try db.run("ALTER TABLE conversations ADD COLUMN accepted INTEGER NOT NULL DEFAULT 1;")
            try db.run("PRAGMA user_version = 23;")
        }
        try step(db, to: 24) {
            // Base keys already used with a last-resort Kyber prekey, so a
            // replayed first message can't rebuild a session (libsignal leaves
            // this check to the store).
            try db.run("""
                CREATE TABLE IF NOT EXISTS kyber_last_resort_uses (
                    kyber_id         INTEGER NOT NULL,
                    signed_prekey_id INTEGER NOT NULL,
                    base_key         BLOB NOT NULL,
                    PRIMARY KEY (kyber_id, signed_prekey_id, base_key)
                );
                """)
            try db.run("PRAGMA user_version = 24;")
        }
        try step(db, to: 25) {
            // Link previews that came with a message (built by its sender).
            // Triggers drop a preview with its message, however it goes:
            // deleted, unsent or expired.
            try db.run("""
                CREATE TABLE IF NOT EXISTS link_previews (
                    message_id TEXT PRIMARY KEY,
                    url        TEXT NOT NULL,
                    title      TEXT NOT NULL,
                    image      BLOB
                );
                """)
            try db.run("""
                CREATE TRIGGER IF NOT EXISTS link_previews_on_delete AFTER DELETE ON messages
                BEGIN DELETE FROM link_previews WHERE message_id = OLD.id; END;
                """)
            try db.run("""
                CREATE TRIGGER IF NOT EXISTS link_previews_on_unsend AFTER UPDATE OF deleted ON messages
                WHEN NEW.deleted = 1
                BEGIN DELETE FROM link_previews WHERE message_id = NEW.id; END;
                """)
            try db.run("PRAGMA user_version = 25;")
        }
        try step(db, to: 26) {
            // Earlier versions of edited messages, for "edited" → history.
            // Dropped with the message, as link previews are.
            try db.run("""
                CREATE TABLE IF NOT EXISTS message_edits (
                    message_id TEXT NOT NULL,
                    body       TEXT NOT NULL,
                    replaced_at INTEGER NOT NULL
                );
                """)
            try db.run("CREATE INDEX IF NOT EXISTS message_edits_by_message ON message_edits(message_id);")
            try db.run("""
                CREATE TRIGGER IF NOT EXISTS message_edits_on_delete AFTER DELETE ON messages
                BEGIN DELETE FROM message_edits WHERE message_id = OLD.id; END;
                """)
            try db.run("""
                CREATE TRIGGER IF NOT EXISTS message_edits_on_unsend AFTER UPDATE OF deleted ON messages
                WHEN NEW.deleted = 1
                BEGIN DELETE FROM message_edits WHERE message_id = NEW.id; END;
                """)
            try db.run("PRAGMA user_version = 26;")
        }
    }
}
