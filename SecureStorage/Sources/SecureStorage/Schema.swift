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
    static func migrate(_ db: Database) throws {
        let version = try db.query("PRAGMA user_version;").first?.first?.int64 ?? 0
        if version < 1 {
            try db.transaction {
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
        }
        if version < 2 {
            // Records the identity key that was in effect when the user last
            // verified a peer. Lets the UI tell "never verified" (NULL) apart
            // from "was verified, key has since changed" (differs from the
            // current identity_key) — the safety-number-changed warning.
            try db.transaction {
                try db.run("ALTER TABLE remote_identities ADD COLUMN verified_key BLOB;")
                try db.run("PRAGMA user_version = 2;")
            }
        }
        if version < 3 {
            // Replies (quotes) and emoji reactions. A quote is a self-
            // contained snapshot stored on the replying message so it renders
            // without a lookup and survives the original's deletion. Reactions
            // reference their target by (conversation, sender timestamp), the
            // same author+timestamp identity Signal uses for messages.
            try db.transaction {
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
        }
        if version < 4 {
            // "Unsend" tombstones. A deleted message keeps its row (and its
            // place in the timeline) but its plaintext is cleared; the UI
            // renders a "message was deleted" placeholder.
            try db.transaction {
                try db.run("ALTER TABLE messages ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;")
                try db.run("PRAGMA user_version = 4;")
            }
        }
        if version < 5 {
            // Envelope-level dedup shared by the app and the Notification
            // Service Extension. Double-Ratchet decryption is destructive, so
            // exactly one process may process a given envelope; whoever claims
            // its id here first decrypts it, the other skips.
            try db.transaction {
                try db.run("""
                    CREATE TABLE processed_envelopes (
                        id           TEXT PRIMARY KEY,
                        processed_at INTEGER NOT NULL
                    );
                    """)
                try db.run("PRAGMA user_version = 5;")
            }
        }
    }
}
