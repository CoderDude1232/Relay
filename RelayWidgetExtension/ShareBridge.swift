//
//  ShareBridge.swift
//  RelayWidgetExtension
//
//  Mirror of Relay/ShareBridge.swift — read-only access to conversations and
//  avatars written by the main app into the App Group container.
//

import Foundation

let kShareAppGroup = "group.app.relaymsg"

struct ShareConversationSummary: Codable, Identifiable {
    let id: String
    let displayName: String
    let initials: String
    let isGroup: Bool
    let peerAccount: String
}

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

    static func readAndClearPendingShare() -> PendingShare? {
        guard let data = defaults?.data(forKey: pendingKey),
              let share = try? JSONDecoder().decode(PendingShare.self, from: data)
        else { return nil }
        defaults?.removeObject(forKey: pendingKey)
        return share
    }

    static func makeInitials(_ name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

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
}
