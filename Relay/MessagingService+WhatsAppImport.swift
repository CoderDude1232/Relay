//
//  MessagingService+WhatsAppImport.swift
//  Relay
//
//  Brings a WhatsApp chat export into a Relay chat, so switching doesn't mean
//  losing the history. The messages and media stay on this device (sealed in
//  the attachment cache like everything else) and are never sent to anyone.
//

import CryptoCore
import CryptoKit
import Foundation
import ImageIO
import RelayKit
import SecureStorage
import UniformTypeIdentifiers

extension MessagingService {
    /// `sender_account` of imported group messages from someone with no Relay
    /// account in the group: "import:<their WhatsApp name>".
    nonisolated static let importedSenderPrefix = "import:"
    /// Ids of imported messages start with this.
    nonisolated static let importedIdPrefix = "wa-"

    /// Relay chats an export can go into: 1:1 chats for a two-person export,
    /// groups for either.
    func importTargets(for export: WhatsAppExport) -> [Conversation] {
        conversations.filter { conv in
            conv.accepted && conv.peerAccount != Self.relayOfficialAccount
                && conv.peerAccount != credentials.accountId
                && (conv.isGroup || !export.isGroup)
        }
    }

    /// Adds the export's messages to `conversationId` and returns how many
    /// were new (importing the same export twice adds nothing).
    /// `me` is the sender name that is this user.
    func importWhatsApp(
        _ export: WhatsAppExport, me: String, into conversationId: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> Int {
        let isGroupChat = group(for: conversationId) != nil
        // Group members whose Relay name matches their WhatsApp name get their
        // messages under their account; everyone else keeps the WhatsApp name.
        var accountByName: [String: String] = [:]
        if let group = group(for: conversationId) {
            for member in group.members where member != credentials.accountId {
                accountByName[displayName(forAccount: member).lowercased()] = member
            }
        }
        // Imports from before unsent messages were recognised kept WhatsApp's
        // wording as plain text; the unsent rows below replace them.
        _ = try? storage.database.run(
            """
            DELETE FROM messages WHERE conversation_id = ? AND id LIKE ? AND deleted = 0
              AND body IN ('This message was deleted', 'This message was deleted.',
                           'You deleted this message', 'You deleted this message.')
            """, [.text(conversationId), .text(Self.importedIdPrefix + "%")]
        )
        let messages = storage.messages
        let blobs = attachmentStore
        // Imported media stays on this device, so the relay's upload cap
        // doesn't apply; this just keeps one file from exhausting memory.
        let maxMediaBytes: UInt64 = 100 * 1024 * 1024

        let added = try await Task.detached(priority: .userInitiated) {
            var rows: [MessageStore.ImportedMessage] = []
            var seen: [String: Int] = [:]
            var lastSecond: Int64 = .min
            var sameSecond: Int64 = 0
            let total = Double(max(export.messages.count, 1))
            for (index, message) in export.messages.enumerated() {
                if index % 200 == 0 {
                    let fraction = Double(index) / total
                    await progress(fraction * 0.95)
                }
                // Seconds from the export; spread messages within a second so
                // their order survives.
                let second = Int64(message.date.timeIntervalSince1970) * 1000
                sameSecond = second == lastSecond ? sameSecond + 1 : 0
                lastSecond = second
                let timestamp = second + min(sameSecond, 999)

                let isMe = message.sender == me
                var body = message.text
                var attachments: [StoredAttachment] = []
                if let name = message.attachment {
                    if let entry = export.media[name], entry.size <= maxMediaBytes,
                       let data = try? export.archive?.extract(entry),
                       let attachment = try? Self.sealImported(data, filename: name, blobs: blobs) {
                        attachments.append(attachment)
                    } else {
                        body = body.isEmpty ? "[\(Self.mediaKind(name)) not included]" : body
                    }
                } else if message.omittedMedia {
                    body = "[Media not included in the export]"
                }
                if body.isEmpty, attachments.isEmpty, !message.deleted { continue }

                // Stable ids: the same export imported again matches its rows.
                let key = "\(conversationId)|\(timestamp)|\(message.sender)|\(message.text)|\(message.attachment ?? "")"
                let occurrence = seen[key, default: 0]
                seen[key] = occurrence + 1
                let digest = SHA256.hash(data: Data("\(key)|\(occurrence)".utf8))
                let id = Self.importedIdPrefix + digest.prefix(16).map { String(format: "%02x", $0) }.joined()

                var sender: String?
                if isGroupChat, !isMe {
                    sender = accountByName[message.sender.lowercased()]
                        ?? Self.importedSenderPrefix + message.sender
                }
                rows.append(MessageStore.ImportedMessage(
                    id: id, isOutgoing: isMe, body: body, timestamp: timestamp,
                    senderAccount: sender, attachments: attachments, isDeleted: message.deleted
                ))
            }
            return try messages.importMessages(rows, conversationId: conversationId)
        }.value
        progress(1)
        if added > 0 {
            // A notice under the history, added the same way so it isn't unread.
            let notice = MessageStore.ImportedMessage(
                id: UUID().uuidString, isOutgoing: false,
                body: "\(added.formatted()) \(added == 1 ? "message" : "messages") imported from WhatsApp. They're only on this device.",
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                senderAccount: Self.systemSender, attachments: []
            )
            _ = try? storage.messages.importMessages([notice], conversationId: conversationId)
        }
        refreshConversations()
        refreshActiveMessages(ifShowing: conversationId)
        return added
    }

    /// Seals media the way a sent attachment is cached, under a local id.
    private nonisolated static func sealImported(_ data: Data, filename: String, blobs: AttachmentBlobStore) throws -> StoredAttachment {
        let sealed = try AttachmentCipher.seal(data)
        let id = localAttachmentPrefix + UUID().uuidString
        try blobs.write(sealed.ciphertext, for: id)
        let ext = (filename as NSString).pathExtension.lowercased()
        let type = contentType(forExtension: ext)
        var width = 0, height = 0
        if type.hasPrefix("image/"),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            // EXIF orientations 5–8 are rotated a quarter turn.
            if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
                swap(&width, &height)
            }
        }
        return StoredAttachment(
            id: id, key: sealed.key, digest: sealed.digest, contentType: type,
            size: Int64(sealed.ciphertext.count), filename: filename,
            width: width, height: height, isDownloaded: true
        )
    }

    private nonisolated static func contentType(forExtension ext: String) -> String {
        switch ext {
        case "opus": return "audio/ogg"
        case "jpg", "jpeg": return "image/jpeg"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    private nonisolated static func mediaKind(_ filename: String) -> String {
        let type = contentType(forExtension: (filename as NSString).pathExtension.lowercased())
        if type.hasPrefix("image/") { return "Photo" }
        if type.hasPrefix("video/") { return "Video" }
        if type.hasPrefix("audio/") { return "Voice message" }
        return "File"
    }
}
