//
//  WatchSession.swift
//  RelayWatch Watch App
//
//  Receives recent chats from the iPhone and asks it to send replies and start
//  calls. Messages are never decrypted here (the iPhone does that); the local
//  copy of the chat list is sealed with a key in this watch's keychain.
//

import CryptoKit
import Foundation
import Observation
import Security
import UIKit
import WatchConnectivity

@Observable
final class WatchSession: NSObject, WCSessionDelegate {
    private(set) var snapshot: WatchSnapshot = .empty
    private(set) var hasReceived = false
    private(set) var isReachable = false
    /// Sent from the watch but not yet in a snapshot from the iPhone.
    private(set) var pending: [String: [WatchSnapshot.Message]] = [:]
    /// Navigation path of chat ids; a notification tap pushes onto it.
    var path: [String] = []
    /// Bumped when a chat photo arrives, so avatars redraw.
    private(set) var avatarVersion = 0
    private var avatarCache: [String: UIImage] = [:]

    private static var avatarDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("avatars", isDirectory: true)
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chats.json")
    }

    override init() {
        super.init()
        if let data = Self.readCache(),
           let cached = try? JSONDecoder().decode(WatchSnapshot.self, from: data) {
            snapshot = cached
            hasReceived = true
        }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: Encrypted cache

    /// The cached chat list holds names and recent message text, so it's
    /// sealed with a key kept in this watch's keychain (this device only)
    /// rather than written as plain JSON.
    private static let keyAccount = "app.relaymsg.watch.cacheKey"

    private static func cacheKey() -> SymmetricKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: keyAccount,
            kSecReturnData: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess, let data = out as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        // Only make a new key when there's none: any other failure (e.g. the
        // keychain not available yet) must not throw away the existing one.
        guard status == errSecItemNotFound else { return nil }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: keyAccount,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: raw,
        ]
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: keyAccount] as CFDictionary)
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return key
    }

    private static func readCache() -> Data? {
        guard let stored = try? Data(contentsOf: cacheURL) else { return nil }
        if let key = cacheKey(), let box = try? AES.GCM.SealedBox(combined: stored),
           let plain = try? AES.GCM.open(box, using: key) {
            return plain
        }
        // An older build's plain JSON, or a key that's gone: start over.
        try? FileManager.default.removeItem(at: cacheURL)
        return nil
    }

    private static func writeCache(_ data: Data) {
        guard let key = cacheKey(), let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        try? sealed.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func open(chatId: String) {
        path = [chatId]
    }

    func avatar(for chatId: String) -> UIImage? {
        _ = avatarVersion
        if let cached = avatarCache[chatId] { return cached }
        let url = Self.avatarDir.appendingPathComponent(chatId + ".jpg")
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        avatarCache[chatId] = image
        return image
    }

    private func storeAvatar(from file: URL, chatId: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.avatarDir, withIntermediateDirectories: true)
        let dest = Self.avatarDir.appendingPathComponent(chatId + ".jpg")
        try? fm.removeItem(at: dest)
        guard (try? fm.moveItem(at: file, to: dest)) != nil else { return }
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dest.path)
        avatarCache[chatId] = nil
        avatarVersion += 1
    }

    /// Deletes photos of chats no longer in the snapshot.
    private func pruneAvatars(keeping ids: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.avatarDir, includingPropertiesForKeys: nil) else { return }
        for file in files where !ids.contains(file.deletingPathExtension().lastPathComponent) {
            try? fm.removeItem(at: file)
            avatarCache[file.deletingPathExtension().lastPathComponent] = nil
        }
    }

    func chat(id: String) -> WatchSnapshot.Chat? {
        snapshot.chats.first { $0.id == id }
    }

    func messages(in chatId: String) -> [WatchSnapshot.Message] {
        (chat(id: chatId)?.messages ?? []) + (pending[chatId] ?? [])
    }

    // MARK: Requests

    func refresh() {
        request([WatchProtocol.actionKey: WatchProtocol.Action.refresh.rawValue])
    }

    func markRead(_ chatId: String) {
        guard (chat(id: chatId)?.unread ?? 0) > 0 else { return }
        request([WatchProtocol.actionKey: WatchProtocol.Action.markRead.rawValue,
                 WatchProtocol.conversationKey: chatId])
    }

    func send(_ text: String, to chatId: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let local = WatchSnapshot.Message(
            id: "pending-" + UUID().uuidString, outgoing: true, text: trimmed, sender: nil,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )
        pending[chatId, default: []].append(local)
        let error = await requestWithReply([
            WatchProtocol.actionKey: WatchProtocol.Action.send.rawValue,
            WatchProtocol.conversationKey: chatId,
            WatchProtocol.textKey: trimmed,
        ])
        if error != nil { pending[chatId]?.removeAll { $0.id == local.id } }
        return error
    }

    func call(_ chatId: String, video: Bool) async -> String? {
        await requestWithReply([
            WatchProtocol.actionKey: WatchProtocol.Action.call.rawValue,
            WatchProtocol.conversationKey: chatId,
            WatchProtocol.videoKey: video,
        ])
    }

    private func request(_ message: [String: Any]) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(message, replyHandler: { _ in }, errorHandler: { _ in })
    }

    /// Returns an error message, or nil on success.
    private func requestWithReply(_ message: [String: Any]) async -> String? {
        guard WCSession.default.activationState == .activated else { return "Not connected to your iPhone" }
        guard WCSession.default.isReachable else { return "Your iPhone isn't nearby" }
        nonisolated(unsafe) let message = message
        return await withCheckedContinuation { continuation in
            WCSession.default.sendMessage(message, replyHandler: { reply in
                continuation.resume(returning: reply[WatchProtocol.errorKey] as? String)
            }, errorHandler: { _ in
                continuation.resume(returning: "Couldn't reach your iPhone")
            })
        }
    }

    // MARK: Snapshot

    private func apply(_ context: [String: Any]) {
        guard let data = context[WatchProtocol.snapshotKey] as? Data,
              let next = try? JSONDecoder().decode(WatchSnapshot.self, from: data)
        else { return }
        snapshot = next
        hasReceived = true
        // Drop pending bubbles the iPhone has now confirmed.
        for (chatId, sent) in pending {
            let confirmed = Set((next.chats.first { $0.id == chatId }?.messages ?? []).filter(\.outgoing).map(\.text))
            pending[chatId] = sent.filter { !confirmed.contains($0.text) }
        }
        pruneAvatars(keeping: Set(next.chats.map(\.id)))
        if next.chats.isEmpty {
            pending = [:]
            path = []
            try? FileManager.default.removeItem(at: Self.cacheURL)
        } else {
            try? FileManager.default.createDirectory(
                at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            Self.writeCache(data)
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        nonisolated(unsafe) let context = session.receivedApplicationContext
        let reachable = session.isReachable
        Task { @MainActor in
            self.apply(context)
            self.isReachable = reachable
            self.refresh()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        nonisolated(unsafe) let context = applicationContext
        Task { @MainActor in self.apply(context) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let chatId = file.metadata?[WatchProtocol.avatarKey] as? String,
              !chatId.contains("/"), !chatId.contains("..")
        else { return }
        // The system deletes the file when this returns, so move it first.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard (try? FileManager.default.moveItem(at: file.fileURL, to: staged)) != nil else { return }
        Task { @MainActor in self.storeAvatar(from: staged, chatId: chatId) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            if reachable { self.refresh() }
        }
    }
}
