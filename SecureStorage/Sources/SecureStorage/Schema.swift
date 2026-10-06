//
//  Schema.swift
//  SecureStorage
//
//  Versioned migrations for the client database. Everything here is
//  encrypted at rest by SQLCipher; the identity private key is NOT here —
//  it lives in the Keychain (see KeychainIdentityStore).
//

import Foundation

enum Schema {
    /// Runs one migration step atomically and idempotently. The app and the
    /// Notification Service Extension can open the same file at the same time
    /// after an update; each step takes the write lock (BEGIN IMMEDIATE —
    /// the second process waits on the busy timeout), then re-reads
    /// `user_version` INSIDE the transaction and skips the step if another
    /// connection already applied it. `body` must end by setting
    /// `user_version` to `version`.
    private static func step(_ db: Database, to version: Int64, _ body: () throws -> Void) throws {
        // Cheap unlocked pre-check so a fully migrated DB doesn't take the
        // write lock 22 times on every open.
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
            // Records the identity key that was in effect when the user last
            // verified a peer. Lets the UI tell "never verified" (NULL) apart
            // from "was verified, key has since changed" (differs from the
            // current identity_key) — the safety-number-changed warning.
            try db.run("ALTER TABLE remote_identities ADD COLUMN verified_key BLOB;")
            try db.run("PRAGMA user_version = 2;")
        }
        try step(db, to: 3) {
            // Replies (quotes) and emoji reactions. A quote is a self-
            // contained snapshot stored on the replying message so it renders
            // without a lookup and survives the original's deletion. Reactions
            // reference their target by (conversation, sender timestamp), the
            // same author+timestamp identity Signal uses for messages.
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
            // "Unsend" tombstones. A deleted message keeps its row (and its
            // place in the timeline) but its plaintext is cleared; the UI
            // renders a "message was deleted" placeholder.
            try db.run("ALTER TABLE messages ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;")
            try db.run("PRAGMA user_version = 4;")
        }
        try step(db, to: 5) {
            // Envelope-level dedup shared by the app and the Notification
            // Service Extension. Double-Ratchet decryption is destructive, so
            // exactly one process may process a given envelope; whoever claims
            // its id here first decrypts it, the other skips.
            try db.run("""
                CREATE TABLE processed_envelopes (
                    id           TEXT PRIMARY KEY,
                    processed_at INTEGER NOT NULL
                );
                """)
            try db.run("PRAGMA user_version = 5;")
        }
        try step(db, to: 6) {
            // Media attachments. The encrypted blob lives on disk (App Group
            // container); this table holds only the metadata + the key/digest
            // needed to fetch and decrypt it. `downloaded` flips once the
            // ciphertext is cached locally.
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
            // Groups. A group is a conversation with `group_id` set; its
            // roster/metadata (mirrored from the relay) lives in group_state +
            // group_members. Messages record `sender_account` so group bubbles
            // can be attributed (1:1 leaves it null).
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
            // Peer profiles (self-set display name + avatar), distributed E2EE.
            // avatar_data holds the already-decrypted image bytes for display;
            // avatar_id tracks the source blob so unchanged avatars aren't
            // re-downloaded. revision is the sender's clock (newest wins).
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
            // Per-member receipts for group messages. A 1:1 message keeps its
            // single status column; a group message's author records each
            // member's delivered/read state here (keyed by the message's
            // sender clock) to drive "Read by N" and an aggregate status.
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
            // Calls are stored independently from chat messages so the Calls
            // tab can show missed, failed, declined, and completed sessions.
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
            // Conversation UX state: pinned ordering, local read position,
            // disappearing-message TTL, and per-chat privacy controls.
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
            // Archive conversations (hidden from main list) and pin specific
            // messages (shown in a banner at the top of the chat).
            try db.run("ALTER TABLE conversations ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;")
            try db.run("ALTER TABLE messages ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;")
            try db.run("PRAGMA user_version = 12;")
        }

        try step(db, to: 13) {
            // Starred messages: a per-user bookmark separate from pinning.
            // Pinning is conversation-wide (shows a banner); starring is personal.
            try db.run("ALTER TABLE messages ADD COLUMN starred INTEGER NOT NULL DEFAULT 0;")
            try db.run("CREATE INDEX idx_messages_starred ON messages (conversation_id, starred) WHERE starred = 1;")
            try db.run("PRAGMA user_version = 13;")
        }

        try step(db, to: 14) {
            // Conversation labels: user-defined tags (e.g. "Work", "Family")
            // for filtering the conversation list.
            try db.run("ALTER TABLE conversations ADD COLUMN label TEXT;")
            try db.run("PRAGMA user_version = 14;")
        }

        try step(db, to: 15) {
            // Per-conversation privacy: screen-capture protection and custom
            // notification sound (nil = system default).
            try db.run("ALTER TABLE conversations ADD COLUMN screen_security INTEGER NOT NULL DEFAULT 0;")
            try db.run("ALTER TABLE conversations ADD COLUMN notification_sound TEXT;")
            try db.run("PRAGMA user_version = 15;")
        }

        try step(db, to: 16) {
            // Group profile: description text and avatar blob stored locally.
            try db.run("ALTER TABLE group_state ADD COLUMN description TEXT NOT NULL DEFAULT '';")
            try db.run("ALTER TABLE group_state ADD COLUMN avatar_data BLOB;")
            try db.run("PRAGMA user_version = 16;")
        }

        try step(db, to: 17) {
            // Message editing: timestamp when a message was last edited; NULL = unedited.
            try db.run("ALTER TABLE messages ADD COLUMN edited_at INTEGER;")
            try db.run("PRAGMA user_version = 17;")
        }

        try step(db, to: 18) {
            // Admin roles and announce-only mode for groups.
            // Poll votes: keyed by (conversation, poll_author, poll_timestamp, voter_account).
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
            // Key peer identities by (address, device_id) instead of account
            // alone. A peer with multiple devices publishes a distinct identity
            // per device (or, post shared-identity, the same one) — keying by
            // account made the second device look like a key replacement of the
            // first, which raised UntrustedIdentity and blocked sends. SQLite
            // can't alter a PRIMARY KEY in place, so recreate the table and
            // migrate existing rows to device_id = 1 (they re-populate from the
            // next bundle fetch). verified/verified_key are preserved per row.
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
            // Peer profile: a short status line and a longer bio, distributed
            // E2EE alongside display name + avatar (newest-wins by revision).
            try db.run("ALTER TABLE profiles ADD COLUMN status TEXT;")
            try db.run("ALTER TABLE profiles ADD COLUMN bio TEXT;")
            try db.run("PRAGMA user_version = 20;")
        }

        try step(db, to: 21) {
            // Peer profile: labelled links, stored as a JSON array of
            // {label,url} objects, distributed E2EE inside ProfileUpdate.
            try db.run("ALTER TABLE profiles ADD COLUMN links TEXT;")
            try db.run("PRAGMA user_version = 21;")
        }

        try step(db, to: 22) {
            // Screenshot protection. `screen_security` is the local user's own
            // per-chat preference (already present); `peer_screen_security` mirrors
            // the DM peer's preference so the effective state is the OR of both
            // (content is hidden unless BOTH sides disable it). Groups get an
            // admin-controlled flag on group_state. All default ON (privacy-first):
            // existing conversations are flipped on, and the new columns default 1.
            try db.run("ALTER TABLE conversations ADD COLUMN peer_screen_security INTEGER NOT NULL DEFAULT 0;")
            try db.run("UPDATE conversations SET screen_security = 1;")
            try db.run("ALTER TABLE group_state ADD COLUMN screen_security INTEGER NOT NULL DEFAULT 1;")
            try db.run("PRAGMA user_version = 22;")
        }
    }
}
