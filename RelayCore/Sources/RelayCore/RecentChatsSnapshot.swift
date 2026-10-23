//
//  RecentChatsSnapshot.swift
//  RelayCore
//
//  Encrypted snapshot of recent chats (names, last few messages, chat theme)
//  for the Siri UI and notification content extensions, which can't open the
//  message database. The app writes it; the notification service extension
//  appends incoming messages. AES-GCM under a key in the shared Keychain.
//

import CryptoKit
import Foundation
import Security

public struct RecentChatsSnapshot: Codable, Sendable {
    public struct Message: Codable, Sendable {
        public let outgoing: Bool
        public let text: String
        public let sender: String?

        public init(outgoing: Bool, text: String, sender: String?) {
            self.outgoing = outgoing; self.text = text; self.sender = sender
        }
    }

    public struct Conversation: Codable, Sendable {
        public let id: String
        public let name: String
        public let isGroup: Bool
        public var messages: [Message]

        public init(id: String, name: String, isGroup: Bool, messages: [Message]) {
            self.id = id; self.name = name; self.isGroup = isGroup; self.messages = messages
        }
    }

    /// "RRGGBB-RRGGBB" outgoing bubble gradient, nil = accent colour.
    public let bubble: String?
    public let wallpaper: String
    public var conversations: [Conversation]

    public init(bubble: String?, wallpaper: String, conversations: [Conversation]) {
        self.bubble = bubble; self.wallpaper = wallpaper; self.conversations = conversations
    }

    public static let messagesPerConversation = 10

    /// Display text for a stored message body.
    public static func previewText(body: String, attachmentType: String?) -> String {
        if body == "__sticker__" { return "Sticker" }
        if body.hasPrefix("__poll__:") {
            let json = Data(body.dropFirst("__poll__:".count).utf8)
            let question = (try? JSONSerialization.jsonObject(with: json) as? [String: Any])?["question"] as? String
            return "Poll: " + (question ?? "")
        }
        if body.hasPrefix("__relay_loc__") { return "Location" }
        if body.hasPrefix("~once~") { return "View-once media" }
        if body.hasPrefix(PendingControlStore.notepadPrefix) { return "Updated the shared notepad" }
        if body.isEmpty {
            guard let type = attachmentType else { return "Attachment" }
            if type.hasPrefix("image/") { return "Photo" }
            if type.hasPrefix("video/") { return "Video" }
            if type.hasPrefix("audio/") { return "Voice message" }
            return "Attachment"
        }
        return String(Spoilers.redact(body).prefix(240))
    }
}

public enum RecentChatsStore {
    public static let appGroupId = "group.app.relaymsg"
    static let fileName = "siri-preview.bin"
    static let wallpaperFileName = "siri-wallpaper.bin"
    static let keychainService = "app.relaymsg.siri-preview"

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    // MARK: Snapshot

    public static func load() -> RecentChatsSnapshot? {
        guard let data = read(fileName) else { return nil }
        return try? JSONDecoder().decode(RecentChatsSnapshot.self, from: data)
    }

    public static func save(_ snapshot: RecentChatsSnapshot) {
        guard let json = try? JSONEncoder().encode(snapshot) else { return }
        write(json, to: fileName)
    }

    /// Adds an incoming message to a chat already in the snapshot. Chats the
    /// app left out (Panic Mode, previews off) are never added here.
    public static func appendIncoming(conversationId: String, text: String, sender: String?) {
        guard var snapshot = load(),
              let index = snapshot.conversations.firstIndex(where: { $0.id == conversationId })
        else { return }
        var conv = snapshot.conversations.remove(at: index)
        conv.messages.append(.init(outgoing: false, text: text, sender: conv.isGroup ? sender : nil))
        conv.messages = Array(conv.messages.suffix(RecentChatsSnapshot.messagesPerConversation))
        snapshot.conversations.insert(conv, at: 0)
        save(snapshot)
    }

    // MARK: Wallpaper photo

    public static func loadWallpaper() -> Data? { read(wallpaperFileName) }

    public static func saveWallpaper(_ jpeg: Data?) {
        if let jpeg {
            write(jpeg, to: wallpaperFileName)
        } else if let url = container?.appendingPathComponent(wallpaperFileName) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static var hasWallpaper: Bool {
        guard let url = container?.appendingPathComponent(wallpaperFileName) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Sign-out: remove the snapshot, wallpaper and key.
    public static func wipe() {
        for name in [fileName, wallpaperFileName] {
            if let url = container?.appendingPathComponent(name) { try? FileManager.default.removeItem(at: url) }
        }
        SecItemDelete(keyQuery() as CFDictionary)
    }

    // MARK: Encryption

    private static func read(_ name: String) -> Data? {
        guard let url = container?.appendingPathComponent(name),
              let sealed = try? Data(contentsOf: url),
              let key = loadKey(create: false),
              let box = try? AES.GCM.SealedBox(combined: sealed)
        else { return nil }
        return try? AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    private static func write(_ plaintext: Data, to name: String) {
        guard let url = container?.appendingPathComponent(name),
              let key = loadKey(create: true),
              let sealed = try? AES.GCM.seal(plaintext, using: SymmetricKey(data: key)).combined
        else { return }
        try? sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func keyQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "key",
         kSecAttrAccessGroup as String: appGroupId]
    }

    private static func loadKey(create: Bool) -> Data? {
        var query = keyQuery()
        query[kSecReturnData as String] = true
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 32 {
            return data
        }
        guard create else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else { return nil }
        var add = keyQuery()
        add[kSecValueData as String] = Data(bytes)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(keyQuery() as CFDictionary)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? Data(bytes) : nil
    }
}
