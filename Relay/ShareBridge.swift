//
//  ShareBridge.swift
//  Relay + RelayShareExtension
//
//  IMPORTANT: This file is compiled into BOTH the main app target AND the
//  RelayShareExtension target. Keep it free of any main-app-only imports.
//

import Foundation

let kShareAppGroup = "group.com.morgandaly.RelayMessenger"

// Lightweight, unencrypted snapshot of a conversation written to App Group
// storage by the main app so the Share Extension can display a picker.
struct ShareConversationSummary: Codable, Identifiable {
    let id: String          // conversation id (primary key in MessageStore)
    let displayName: String
    let initials: String
    let isGroup: Bool
    let peerAccount: String // used to match INSendMessageIntent recipients
}

// Content + target chosen in the Share Extension; processed by the main app.
struct PendingShare: Codable {
    let conversationId: String
    let text: String?
    let imageData: Data?
    let imageUTI: String?
    let fileData: Data?
    let filename: String?
}

enum ShareBridge {
    private static let conversationsKey = "relay.share.conversations"
    private static let pendingKey = "relay.share.pending"
    private static let unreadCountKey = "relay.share.unreadCount"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: kShareAppGroup) }

    static func writeConversations(_ list: [ShareConversationSummary]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults?.set(data, forKey: conversationsKey)
    }

    static func readConversations() -> [ShareConversationSummary] {
        guard let data = defaults?.data(forKey: conversationsKey),
              let list = try? JSONDecoder().decode([ShareConversationSummary].self, from: data)
        else { return [] }
        return list
    }

    static func writePendingShare(_ share: PendingShare) {
        guard let data = try? JSONEncoder().encode(share) else { return }
        defaults?.set(data, forKey: pendingKey)
    }

    // Returns the share and atomically removes it so callers don't process it twice.
    static func readAndClearPendingShare() -> PendingShare? {
        guard let data = defaults?.data(forKey: pendingKey),
              let share = try? JSONDecoder().decode(PendingShare.self, from: data)
        else { return nil }
        defaults?.removeObject(forKey: pendingKey)
        return share
    }

    static func writeUnreadCount(_ count: Int) {
        defaults?.set(count, forKey: unreadCountKey)
    }

    static func readUnreadCount() -> Int {
        defaults?.integer(forKey: unreadCountKey) ?? 0
    }

    static func makeInitials(_ name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    // MARK: - Avatar files (stored in App Group container for widget / content extension access)

    private static func avatarDir() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kShareAppGroup)?
            .appendingPathComponent("relay-avatars", isDirectory: true)
    }

    static func writeAvatar(_ data: Data, forConversationId id: String) {
        guard let dir = avatarDir() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(id), options: .atomic)
    }

    static func readAvatar(forConversationId id: String) -> Data? {
        guard let url = avatarDir()?.appendingPathComponent(id) else { return nil }
        return try? Data(contentsOf: url)
    }

    // Removes the entire avatar directory; call on sign-out so the next
    // account starts with no leftover images.
    static func clearAvatars() {
        guard let dir = avatarDir() else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    // Clears all App Group share state (conversations, unread count, avatars).
    // Call on sign-out so a new account sees a clean slate everywhere.
    static func clearAll() {
        defaults?.removeObject(forKey: conversationsKey)
        defaults?.removeObject(forKey: unreadCountKey)
        clearAvatars()
    }
}
