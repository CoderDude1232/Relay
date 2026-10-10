//
//  PendingControl.swift
//  RelayCore
//
//  Once the NSE processes an envelope, the ratchet has advanced and the app
//  can't decrypt it again. Anything the processor returns for the caller to
//  apply (group changes, profiles, receipts, notices) is persisted here and
//  applied by the app later (`MessagingService.drainPendingControlMessages`).
//  Rows live in the SQLCipher `kv` table.
//

import Foundation
import SecureStorage

/// A decrypted control payload the NSE couldn't apply itself.
public enum PendingControl: Codable, Sendable {
    case groupUpdate(GroupUpdateInfo, authenticatedSender: String?)
    case profile(ProfileInfo)
    /// A delivery receipt to send to `peerAccount`, the attested author.
    /// `conversationId` supplies the group context.
    case deliveryReceipt(peerAccount: String, conversationId: String?, timestamp: Int64)
    /// Unused; usernames come from the sender certificate. Kept so persisted
    /// items still decode.
    case backfillUsername(conversationId: String, account: String)
    case screenshotAlert(ScreenshotAlertInfo)
    case screenSecurity(ScreenSecurityInfo)
    /// A shared-notepad update (body without `notepadPrefix`).
    case notepad(conversationId: String, content: String)
    /// A call-link join request received while the app wasn't running. The app
    /// re-checks it and prompts if it's still recent.
    case callLinkRequest(callId: String, account: String, secret: String, receivedAt: Date)
}

public enum PendingControlStore {
    static let keyPrefix = "pending-control:"
    /// Must match `notepadPrefix` in Relay/NotepadView.swift.
    public static let notepadPrefix = "__relay_notepad__"

    /// The payloads in `result` the app would apply, in the order it applies them.
    public static func items(from result: ProcessedEnvelope) -> [PendingControl] {
        var items: [PendingControl] = []
        if let ts = result.sideEffects.deliveryReceiptTimestamp, let peer = result.peerAccount, !peer.isEmpty {
            items.append(.deliveryReceipt(peerAccount: peer, conversationId: result.conversationId, timestamp: ts))
        }
        if result.outcome == .stored, let conversationId = result.conversationId,
           let body = result.notification?.body, body.hasPrefix(notepadPrefix) {
            items.append(.notepad(conversationId: conversationId, content: String(body.dropFirst(notepadPrefix.count))))
        }
        if let update = result.groupUpdate {
            items.append(.groupUpdate(update, authenticatedSender: result.peerAccount))
        }
        if let profile = result.profile {
            items.append(.profile(profile))
        }
        if let shot = result.screenshotAlert {
            items.append(.screenshotAlert(shot))
        }
        if let upd = result.screenSecurityUpdate {
            items.append(.screenSecurity(upd))
        }
        if let call = result.callInfo, call.type == .linkJoinRequest {
            items.append(.callLinkRequest(callId: call.callId, account: call.callerAccount,
                                          secret: call.sdp, receivedAt: Date()))
        }
        return items
    }

    /// Persists every pending payload from `result`. Keys sort chronologically
    /// (microsecond clock + index) so the app replays them in arrival order.
    public static func persist(_ result: ProcessedEnvelope, envelopeId: String, in storage: SecureStore) {
        let items = items(from: result)
        guard !items.isEmpty else { return }
        let micros = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let encoder = JSONEncoder()
        for (index, item) in items.enumerated() {
            guard let data = try? encoder.encode(item) else { continue }
            let key = keyPrefix + String(format: "%017lld:%02d:", micros, index) + envelopeId
            try? storage.database.run(
                "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                [.text(key), .blob(data)]
            )
        }
    }

    /// All pending payloads, oldest first. Rows that fail to decode are deleted.
    public static func load(from storage: SecureStore) -> [(key: String, item: PendingControl)] {
        let rows = (try? storage.database.query(
            "SELECT key, value FROM kv WHERE key LIKE ? ORDER BY key",
            [.text(keyPrefix + "%")]
        )) ?? []
        let decoder = JSONDecoder()
        var out: [(key: String, item: PendingControl)] = []
        for row in rows {
            guard let key = row.first?.string else { continue }
            guard let data = row.dropFirst().first?.data,
                  let item = try? decoder.decode(PendingControl.self, from: data)
            else {
                remove(key, from: storage)
                continue
            }
            out.append((key, item))
        }
        return out
    }

    public static func remove(_ key: String, from storage: SecureStore) {
        try? storage.database.run("DELETE FROM kv WHERE key = ?", [.text(key)])
    }
}

/// Shared readers for app settings the NSE must honour.
extension RelayStore {
    /// Accounts the user blocked, stored by the app in the kv table under
    /// `relay.blockedAccounts` as a JSON array.
    public static func blockedAccounts(in storage: SecureStore) -> Set<String> {
        guard let data = (try? storage.database.query(
            "SELECT value FROM kv WHERE key = 'relay.blockedAccounts'"
        ).first?.first?.data) ?? nil,
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(list)
    }

    /// Whether a conversation is currently muted. `relay.muteExpiries` in App
    /// Group defaults is JSON `[conversationId: ms]`, `Int64.max` meaning forever.
    /// The older `relay.mutedConversationIds` array is also honoured.
    public static func isConversationMuted(_ conversationId: String, defaults: UserDefaults?) -> Bool {
        guard !conversationId.isEmpty, let defaults else { return false }
        if let data = defaults.data(forKey: "relay.muteExpiries"),
           let expiries = try? JSONDecoder().decode([String: Int64].self, from: data),
           let expiry = expiries[conversationId] {
            if expiry == Int64.max { return true }
            if expiry > Int64(Date().timeIntervalSince1970 * 1000) { return true }
        }
        return defaults.stringArray(forKey: "relay.mutedConversationIds")?.contains(conversationId) ?? false
    }
}
