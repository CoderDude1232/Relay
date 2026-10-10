//
//  SiriPreviewCache.swift
//  Relay
//
//  A small encrypted snapshot of recent chats (last few messages, names, chat
//  theme) for the Siri UI extension, which can't open the message database.
//  Written to the App Group container, AES-GCM under a key kept in the shared
//  Keychain. Chats hidden by Panic Mode or with previews turned off are left out.
//

import CryptoKit
import Foundation
import RelayCore
import Security
import SecureStorage

struct SiriPreviewSnapshot: Codable {
    struct Message: Codable {
        let outgoing: Bool
        let text: String
        let sender: String?
    }
    struct Conversation: Codable {
        let id: String
        let name: String
        let isGroup: Bool
        let messages: [Message]
    }
    /// "RRGGBB-RRGGBB" outgoing bubble gradient, nil = accent colour.
    let bubble: String?
    let wallpaper: String
    let conversations: [Conversation]
}

enum SiriPreviewCache {
    static let fileName = "siri-preview.bin"
    static let keychainService = "app.relaymsg.siri-preview"
    private static let maxConversations = 15
    private static let messagesPerConversation = 4

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppModel.appGroupId)?
            .appendingPathComponent(fileName)
    }

    @MainActor
    static func write(service: MessagingService) {
        guard let url = fileURL, let key = loadOrCreateKey() else { return }
        let defaults = UserDefaults.standard
        let panic = PanicModeManager.shared
        var convs: [SiriPreviewSnapshot.Conversation] = []
        for conv in service.conversations where !conv.archived && !panic.isHidden(conv.id) {
            guard convs.count < maxConversations else { break }
            let name = conv.groupId.map { service.displayName(forAccount: $0) }
                ?? service.displayName(forAccount: conv.peerAccount)
            var messages: [SiriPreviewSnapshot.Message] = []
            if !conv.hidePreviews,
               let stored = try? service.storage.messages.messages(in: conv.id, limit: messagesPerConversation) {
                messages = stored.filter { !$0.isDeleted }.map { m in
                    SiriPreviewSnapshot.Message(
                        outgoing: m.isOutgoing,
                        text: previewText(m),
                        sender: conv.isGroup && !m.isOutgoing
                            ? m.senderAccount.map { service.displayName(forAccount: $0) } : nil
                    )
                }
            }
            convs.append(.init(id: conv.id, name: name, isGroup: conv.isGroup, messages: messages))
        }
        let snapshot = SiriPreviewSnapshot(
            bubble: defaults.string(forKey: "chat.bubbleTint"),
            wallpaper: defaults.string(forKey: "chat.wallpaper") ?? "none",
            conversations: convs
        )
        guard let json = try? JSONEncoder().encode(snapshot),
              let sealed = try? AES.GCM.seal(json, using: SymmetricKey(data: key)).combined
        else { return }
        try? sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Sign-out: remove the snapshot and its key.
    static func wipe() {
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        SecItemDelete(keyQuery() as CFDictionary)
    }

    private static func previewText(_ m: StoredMessage) -> String {
        let body = m.body
        if body == "__sticker__" { return "Sticker" }
        if body.hasPrefix("__poll__:") {
            let json = String(body.dropFirst("__poll__:".count))
            return "Poll: " + (PollPayload.decode(json)?.question ?? "")
        }
        if body.hasPrefix("__relay_loc__") { return "Location" }
        if body.hasPrefix("~once~") { return "View-once media" }
        if body.isEmpty, let a = m.attachments.first {
            return a.isImage ? "Photo" : a.isVideo ? "Video" : a.isAudio ? "Voice message" : "Attachment"
        }
        return String(body.prefix(240))
    }

    // MARK: Key

    private static func keyQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "key",
         kSecAttrAccessGroup as String: AppModel.appGroupId]
    }

    private static func loadOrCreateKey() -> Data? {
        var query = keyQuery()
        query[kSecReturnData as String] = true
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 32 {
            return data
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else { return nil }
        var add = keyQuery()
        add[kSecValueData as String] = Data(bytes)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(keyQuery() as CFDictionary)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? Data(bytes) : nil
    }
}
