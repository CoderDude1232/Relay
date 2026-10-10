//
//  WatchSession.swift
//  RelayWatch Watch App
//
//  Receives recent chats from the iPhone and asks it to send replies and start
//  calls. Nothing is encrypted or decrypted here; the iPhone does all of that.
//

import Foundation
import Observation
import WatchConnectivity

@Observable
final class WatchSession: NSObject, WCSessionDelegate {
    private(set) var snapshot: WatchSnapshot = .empty
    private(set) var hasReceived = false
    private(set) var isReachable = false
    /// Sent from the watch but not yet in a snapshot from the iPhone.
    private(set) var pending: [String: [WatchSnapshot.Message]] = [:]

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chats.json")
    }

    override init() {
        super.init()
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? JSONDecoder().decode(WatchSnapshot.self, from: data) {
            snapshot = cached
            hasReceived = true
        }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
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
        if next.chats.isEmpty {
            pending = [:]
            try? FileManager.default.removeItem(at: Self.cacheURL)
        } else {
            try? FileManager.default.createDirectory(
                at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: Self.cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            if reachable { self.refresh() }
        }
    }
}
