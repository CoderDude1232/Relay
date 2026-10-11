//
//  SiriPreviewCache.swift
//  Relay
//
//  Writes the encrypted recent-chats snapshot (RecentChatsStore) that the Siri
//  UI and notification content extensions draw from. Chats hidden by Panic Mode
//  are left out, and chats with previews off carry no message text.
//

import Foundation
import RelayCore
import SecureStorage
import UIKit

enum SiriPreviewCache {
    private static let maxConversations = 15
    private static var wallpaperFingerprint: String?

    @MainActor
    static func write(service: MessagingService) {
        let defaults = UserDefaults.standard
        let panic = PanicModeManager.shared
        var convs: [RecentChatsSnapshot.Conversation] = []
        for conv in service.conversations where !conv.archived && !conv.isRequest && !panic.isHidden(conv.id) {
            guard convs.count < maxConversations else { break }
            let name = conv.groupId.map { service.displayName(forAccount: $0) }
                ?? service.displayName(forAccount: conv.peerAccount)
            var messages: [RecentChatsSnapshot.Message] = []
            if !conv.hidePreviews,
               let stored = try? service.storage.messages.messages(
                   in: conv.id, limit: RecentChatsSnapshot.messagesPerConversation
               ) {
                messages = stored.filter { !$0.isDeleted }.map { m in
                    RecentChatsSnapshot.Message(
                        outgoing: m.isOutgoing,
                        text: RecentChatsSnapshot.previewText(body: m.body, attachmentType: m.attachments.first?.contentType),
                        sender: conv.isGroup && !m.isOutgoing
                            ? m.senderAccount.map { service.displayName(forAccount: $0) } : nil
                    )
                }
            }
            convs.append(.init(id: conv.id, name: name, isGroup: conv.isGroup, messages: messages))
        }
        let wallpaper = defaults.string(forKey: "chat.wallpaper") ?? "none"
        RecentChatsStore.save(RecentChatsSnapshot(
            bubble: defaults.string(forKey: "chat.bubbleTint"),
            wallpaper: wallpaper,
            conversations: convs
        ))
        writeWallpaper(active: wallpaper == "photo")
    }

    /// Keeps a small copy of the chat wallpaper photo for the extensions.
    private static func writeWallpaper(active: Bool) {
        let source = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-wallpaper.jpg")
        guard active,
              let attrs = try? FileManager.default.attributesOfItem(atPath: source.path),
              let modified = attrs[.modificationDate] as? Date
        else {
            if wallpaperFingerprint != "" { RecentChatsStore.saveWallpaper(nil) }
            wallpaperFingerprint = ""
            return
        }
        let fingerprint = "\(modified.timeIntervalSince1970)-\(attrs[.size] ?? 0)"
        if fingerprint == wallpaperFingerprint, RecentChatsStore.hasWallpaper { return }
        guard let image = UIImage(contentsOfFile: source.path) else { return }
        let scale = min(1, 700 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let small = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = small.jpegData(compressionQuality: 0.7) else { return }
        RecentChatsStore.saveWallpaper(jpeg)
        wallpaperFingerprint = fingerprint
    }

    static func wipe() {
        RecentChatsStore.wipe()
        wallpaperFingerprint = nil
    }
}
