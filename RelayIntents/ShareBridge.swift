//
//  ShareBridge.swift
//  Extension mirror of Relay/ShareBridge.swift (read side + pending-share
//  writer). Keep the storage format in sync with the app's copy.
//
//  Conversations are identified only by opaque local conversation ids (never a
//  peer account id); files carry explicit Data Protection, live in directories
//  excluded from backup, and a pending share is a protected file (never
//  UserDefaults) that the app deletes once processed.
//

import Foundation

let kShareAppGroup = "group.app.relaymsg"

struct ShareConversationSummary: Codable, Identifiable {
    let id: String          // opaque local conversation id
    let displayName: String
    let initials: String
    let isGroup: Bool
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
    private static let legacyPendingKey = "relay.share.pending"
    private static let shareDirName = "relay-share"
    private static let avatarDirName = "relay-avatars"
    private static let conversationsFile = "conversations.json"
    private static let pendingShareFile = "pending-share.json"

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kShareAppGroup)
    }

    static func readConversations() -> [ShareConversationSummary] {
        guard let url = container?.appendingPathComponent(shareDirName, isDirectory: true)
                .appendingPathComponent(conversationsFile),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([ShareConversationSummary].self, from: data)
        else { return [] }
        return list
    }

    static func writePendingShare(_ share: PendingShare) {
        UserDefaults(suiteName: kShareAppGroup)?.removeObject(forKey: legacyPendingKey)
        guard let data = try? JSONEncoder().encode(share),
              var dir = container?.appendingPathComponent(shareDirName, isDirectory: true)
        else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        }
        var dirValues = URLResourceValues()
        dirValues.isExcludedFromBackup = true
        try? dir.setResourceValues(dirValues)

        var url = dir.appendingPathComponent(pendingShareFile)
        // Complete protection; if the device is locked right now, fall back to
        // completeUnlessOpen (creatable while locked, unreadable until unlock).
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    static func makeInitials(_ name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    static func readAvatar(forConversationId id: String) -> Data? {
        guard let url = container?.appendingPathComponent(avatarDirName, isDirectory: true)
                .appendingPathComponent(id)
        else { return nil }
        return try? Data(contentsOf: url)
    }
}
