//
//  WatchBridge.swift
//  Relay
//
//  iPhone side of the Apple Watch app. The watch holds no keys: it shows a
//  snapshot of recent chats and asks the iPhone to send replies and start
//  calls. Chats hidden by Panic Mode never leave the phone, and chats with
//  previews off carry no message text.
//

import CryptoKit
import Foundation
import RelayCore
import SecureStorage
import UIKit
import WatchConnectivity

final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()

    private static let maxChats = 20
    private static let messagesPerChat = 12

    weak var appDelegate: AppDelegate?
    private var lastSent: Data?

    func activate(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private var canSend: Bool {
        let session = WCSession.default
        return WCSession.isSupported() && session.activationState == .activated
            && session.isPaired && session.isWatchAppInstalled
    }

    /// Sends the latest chats to the watch if they changed.
    func push(service: MessagingService) {
        guard canSend, let data = try? JSONEncoder().encode(snapshot(service: service)) else { return }
        guard data != lastSent else { return }
        do {
            try WCSession.default.updateApplicationContext([WatchProtocol.snapshotKey: data])
            lastSent = data
        } catch {}
        syncAvatars(service: service)
    }

    // MARK: Avatars

    private static let avatarHashesKey = "watch.avatarHashes"
    private static let avatarSize: CGFloat = 96

    /// Sends small copies of chat photos that changed since they were last sent.
    private func syncAvatars(service: MessagingService) {
        guard canSend else { return }
        let panic = PanicModeManager.shared
        var sentHashes = UserDefaults.standard.dictionary(forKey: Self.avatarHashesKey) as? [String: String] ?? [:]
        let chatIds = service.conversations.lazy
            .filter { !$0.archived && !panic.isHidden($0.id) }
            .prefix(Self.maxChats).map(\.id)
        for id in chatIds {
            guard let data = ShareBridge.readAvatar(forConversationId: id) else { continue }
            let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
            guard sentHashes[id] != hash, let thumbnail = Self.thumbnail(data) else { continue }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-avatar-\(UUID().uuidString).jpg")
            guard (try? thumbnail.write(to: url, options: .completeFileProtection)) != nil else { continue }
            WCSession.default.transferFile(url, metadata: [WatchProtocol.avatarKey: id])
            sentHashes[id] = hash
        }
        UserDefaults.standard.set(sentHashes, forKey: Self.avatarHashesKey)
    }

    private static func thumbnail(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let side = avatarSize
        let scale = max(side / image.size.width, side / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
        return small.jpegData(compressionQuality: 0.75)
    }

    /// Sign-out: leave nothing on the watch.
    func clear() {
        lastSent = nil
        UserDefaults.standard.removeObject(forKey: Self.avatarHashesKey)
        guard canSend, let data = try? JSONEncoder().encode(WatchSnapshot.empty) else { return }
        try? WCSession.default.updateApplicationContext([WatchProtocol.snapshotKey: data])
    }

    private func snapshot(service: MessagingService) -> WatchSnapshot {
        let panic = PanicModeManager.shared
        var chats: [WatchSnapshot.Chat] = []
        for conv in service.conversations where !conv.archived && !conv.isRequest && !panic.isHidden(conv.id) {
            guard chats.count < Self.maxChats else { break }
            let name = conv.groupId.map { service.displayName(forAccount: $0) }
                ?? service.displayName(forAccount: conv.peerAccount)
            var messages: [WatchSnapshot.Message] = []
            // No text for chats with previews off, a Face ID lock or a
            // disappearing timer: these copies outlive the app's own checks.
            if !conv.hidePreviews, !conv.requireBiometricChat, conv.disappearingSeconds == 0,
               let stored = try? service.storage.messages.messages(in: conv.id, limit: Self.messagesPerChat) {
                messages = stored.filter { !$0.isDeleted }.map { m in
                    WatchSnapshot.Message(
                        id: m.id,
                        outgoing: m.isOutgoing,
                        text: RecentChatsSnapshot.previewText(body: m.body, attachmentType: m.attachments.first?.contentType),
                        sender: conv.isGroup && !m.isOutgoing
                            ? m.senderAccount.map { service.displayName(forAccount: $0) } : nil,
                        timestamp: m.timestamp
                    )
                }
            }
            let canCall = !conv.isGroup && conv.peerAccount != service.noteToSelfAccount
                && !service.isBlocked(conv.peerAccount)
            chats.append(.init(
                id: conv.id, name: name, isGroup: conv.isGroup, canCall: canCall,
                unread: conv.unreadCount, messages: messages
            ))
        }
        return WatchSnapshot(bubble: UserDefaults.standard.string(forKey: "chat.bubbleTint"), chats: chats)
    }

    // MARK: Requests from the watch

    private func handle(_ message: [String: Any]) async -> [String: Any] {
        guard let raw = message[WatchProtocol.actionKey] as? String,
              let action = WatchProtocol.Action(rawValue: raw)
        else { return [WatchProtocol.errorKey: "Unknown request"] }

        let task = UIApplication.shared.beginBackgroundTask(withName: "relay.watch")
        defer { UIApplication.shared.endBackgroundTask(task) }
        guard let service = await readyService() else {
            return [WatchProtocol.errorKey: "Open Relay on your iPhone"]
        }
        let conversationId = message[WatchProtocol.conversationKey] as? String ?? ""

        switch action {
        case .refresh:
            lastSent = nil
            push(service: service)
        case .send:
            let text = (message[WatchProtocol.textKey] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !conversationId.isEmpty else { return [WatchProtocol.errorKey: "Nothing to send"] }
            await service.sendMessage(text, in: conversationId)
            service.markConversationRead(conversationId)
            push(service: service)
        case .markRead:
            guard !conversationId.isEmpty else { break }
            service.markConversationRead(conversationId)
            push(service: service)
        case .call:
            guard let conv = service.conversations.first(where: { $0.id == conversationId }),
                  !conv.isGroup, let callManager = appDelegate?.callManager
            else { return [WatchProtocol.errorKey: "Can't call this chat"] }
            let video = message[WatchProtocol.videoKey] as? Bool ?? false
            await callManager.startCall(
                peerAccount: conv.peerAccount,
                peerName: service.displayName(forAccount: conv.peerAccount),
                kind: video ? .video : .audio
            )
        }
        return [WatchProtocol.okKey: true]
    }

    /// Waits briefly for startup when the watch woke the app in the background.
    private func readyService() async -> MessagingService? {
        for _ in 0..<40 {
            if let model = appDelegate?.model, case .ready(let service) = model.phase { return service }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let model = self.appDelegate?.model, case .ready(let service) = model.phase {
                self.push(service: service)
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        guard error != nil, let id = fileTransfer.file.metadata?[WatchProtocol.avatarKey] as? String else { return }
        // Resend next time.
        Task { @MainActor in
            var hashes = UserDefaults.standard.dictionary(forKey: Self.avatarHashesKey) as? [String: String] ?? [:]
            hashes[id] = nil
            UserDefaults.standard.set(hashes, forKey: Self.avatarHashesKey)
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Switched to another watch.
        Task { @MainActor in
            self.lastSent = nil
            UserDefaults.standard.removeObject(forKey: Self.avatarHashesKey)
            WCSession.default.activate()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let installed = session.isWatchAppInstalled
        Task { @MainActor in
            self.lastSent = nil
            // A reinstalled watch app starts with no photos.
            if !installed { UserDefaults.standard.removeObject(forKey: Self.avatarHashesKey) }
            if let model = self.appDelegate?.model, case .ready(let service) = model.phase {
                self.push(service: service)
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        nonisolated(unsafe) let message = message
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in
            reply(await self.handle(message))
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        nonisolated(unsafe) let message = message
        Task { @MainActor in
            _ = await self.handle(message)
        }
    }
}
