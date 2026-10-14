//
//  ShareBridge.swift
//  Relay (main app)
//
//  App Group bridge between the app and its extensions (Share, Siri intents,
//  widget, notification content). Each extension compiles its own mirror of the
//  shared part of this file; keep the storage format in sync.
//
//  The App Group container is outside the encrypted database, so:
//  - conversations are identified only by the opaque local id, never a peer's
//    account id;
//  - hidden (panic-mode) conversations are never written;
//  - files are sealed (ShareSeal), carry explicit Data Protection and are
//    excluded from backups;
//  - a pending share is a protected file (not UserDefaults), deleted once read.
//

import Foundation

let kShareAppGroup = "group.app.relaymsg"

/// Lightweight snapshot of a conversation so extensions can show a picker.
struct ShareConversationSummary: Codable, Identifiable {
    let id: String          // opaque local conversation id
    let displayName: String
    let initials: String
    let isGroup: Bool

    init(id: String, displayName: String, initials: String, isGroup: Bool) {
        self.id = id
        self.displayName = displayName
        self.initials = initials
        self.isGroup = isGroup
    }

    /// Source-compatible initializer: `peerAccount` is accepted but NOT stored.
    @available(*, deprecated, message: "peerAccount is no longer stored; drop the argument")
    init(id: String, displayName: String, initials: String, isGroup: Bool, peerAccount: String) {
        self.init(id: id, displayName: displayName, initials: initials, isGroup: isGroup)
    }
}

/// Content and target chosen in the Share Extension, Siri or quick reply;
/// processed and deleted by the main app.
struct PendingShare: Codable {
    let conversationId: String
    let text: String?
    let imageData: Data?
    let imageUTI: String?
    let fileData: Data?
    let filename: String?
}

nonisolated enum ShareBridge {
    private static let unreadCountKey = "relay.share.unreadCount"
    // Legacy UserDefaults keys from before file storage; removed on sight.
    private static let legacyConversationsKey = "relay.share.conversations"
    private static let legacyPendingKey = "relay.share.pending"

    private static let shareDirName = "relay-share"
    private static let avatarDirName = "relay-avatars"
    private static let conversationsFile = "conversations.json"
    /// Single-slot file from builds that kept one pending share; read, then removed.
    private static let legacyPendingShareFile = "pending-share.json"
    private static let pendingSharePrefix = "pending-share-"
    private static let broadcastFrameFile = "RelayBroadcastFrame.jpg"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: kShareAppGroup) }
    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kShareAppGroup)
    }

    // MARK: - Conversations

    /// Writes the picker snapshot, minus hidden (panic-mode) conversations.
    static func writeConversations(_ list: [ShareConversationSummary]) {
        let hidden = PanicModeManager.hiddenConversationIdsSnapshot()
        let visible = list.filter { !hidden.contains($0.id) }
        defaults?.removeObject(forKey: legacyConversationsKey)
        guard let json = try? JSONEncoder().encode(visible), let data = ShareSeal.seal(json),
              let url = shareDir()?.appendingPathComponent(conversationsFile)
        else { return }
        // Readable after first unlock: the widget and Siri run while locked.
        writeProtected(data, to: url, protection: .completeFileProtectionUntilFirstUserAuthentication)
        // Drop avatars of conversations that are now hidden.
        for id in hidden { removeAvatar(forConversationId: id) }
    }

    static func readConversations() -> [ShareConversationSummary] {
        guard let url = shareDir()?.appendingPathComponent(conversationsFile),
              let stored = try? Data(contentsOf: url), let data = ShareSeal.open(stored),
              let list = try? JSONDecoder().decode([ShareConversationSummary].self, from: data)
        else { return [] }
        return list
    }

    /// Removes one conversation (e.g. just hidden or deleted) from the snapshot.
    static func removeConversation(_ id: String) {
        // If the file exists but can't be opened (key unavailable), leave it:
        // writing back an empty list would blank the widget and share sheet.
        if let url = shareDir()?.appendingPathComponent(conversationsFile),
           let stored = try? Data(contentsOf: url), ShareSeal.open(stored) == nil { return }
        let remaining = readConversations().filter { $0.id != id }
        if let json = try? JSONEncoder().encode(remaining), let data = ShareSeal.seal(json),
           let url = shareDir()?.appendingPathComponent(conversationsFile) {
            writeProtected(data, to: url, protection: .completeFileProtectionUntilFirstUserAuthentication)
        }
        removeAvatar(forConversationId: id)
    }

    // MARK: - Pending share

    /// Queues a share for the app to send. Each one gets its own file, named by
    /// time so they send in order: two Siri sends or quick replies made before
    /// the app opens must both go out.
    static func writePendingShare(_ share: PendingShare) {
        defaults?.removeObject(forKey: legacyPendingKey)
        guard let json = try? JSONEncoder().encode(share), let data = ShareSeal.seal(json),
              let url = shareDir()?.appendingPathComponent(newPendingShareFileName())
        else { return }
        // Complete protection: unreadable whenever the device is locked. If the
        // device is locked right now (e.g. a Siri request), fall back to
        // completeUnlessOpen, which can be created while locked but not read.
        if !writeProtected(data, to: url, protection: .completeFileProtection) {
            writeProtected(data, to: url, protection: .completeFileProtectionUnlessOpen)
        }
    }

    /// Returns every queued share, oldest first, and deletes each one read so it
    /// is processed exactly once. A file still locked stays for next time.
    static func readAndClearPendingShares() -> [PendingShare] {
        var shares: [PendingShare] = []
        // Migrate from the legacy UserDefaults location.
        if let legacy = defaults?.data(forKey: legacyPendingKey) {
            defaults?.removeObject(forKey: legacyPendingKey)
            if let share = try? JSONDecoder().decode(PendingShare.self, from: legacy) { shares.append(share) }
        }
        guard let dir = shareDir() else { return shares }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0 == legacyPendingShareFile || $0.hasPrefix(pendingSharePrefix) }
            .sorted { lhs, rhs in
                // The legacy single slot predates any queued file.
                if lhs == legacyPendingShareFile { return rhs != legacyPendingShareFile }
                if rhs == legacyPendingShareFile { return false }
                return lhs < rhs
            }
        for name in names {
            let url = dir.appendingPathComponent(name)
            guard let stored = try? Data(contentsOf: url) else { continue } // locked: leave it
            try? FileManager.default.removeItem(at: url)
            if let share = ShareSeal.open(stored).flatMap({ try? JSONDecoder().decode(PendingShare.self, from: $0) }) {
                shares.append(share)
            }
        }
        return shares
    }

    /// `pending-share-<ms, zero-padded>-<uuid>.json`: sorts in creation order.
    /// Same format as the extensions' copies.
    private static func newPendingShareFileName() -> String {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        return pendingSharePrefix + String(format: "%015lld-", ms) + UUID().uuidString + ".json"
    }

    // MARK: - Unread count (widget badge)

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

    // MARK: - Avatar files (widget / notification content / NSE)

    static func writeAvatar(_ data: Data, forConversationId id: String) {
        guard !PanicModeManager.hiddenConversationIdsSnapshot().contains(id),
              let url = avatarDir()?.appendingPathComponent(id),
              let sealed = ShareSeal.seal(data)
        else { return }
        writeProtected(sealed, to: url, protection: .completeFileProtectionUntilFirstUserAuthentication)
    }

    static func readAvatar(forConversationId id: String) -> Data? {
        guard let url = avatarDir()?.appendingPathComponent(id),
              let stored = try? Data(contentsOf: url)
        else { return nil }
        return ShareSeal.open(stored)
    }

    /// Re-seals files written before sealing (the chat list and photos).
    static func sealLegacyFiles() {
        if let url = shareDir()?.appendingPathComponent(conversationsFile),
           let stored = try? Data(contentsOf: url), !ShareSeal.isSealed(stored),
           let sealed = ShareSeal.seal(stored) {
            writeProtected(sealed, to: url, protection: .completeFileProtectionUntilFirstUserAuthentication)
        }
        guard let dir = avatarDir(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in files {
            guard let stored = try? Data(contentsOf: url), !ShareSeal.isSealed(stored),
                  let sealed = ShareSeal.seal(stored) else { continue }
            writeProtected(sealed, to: url, protection: .completeFileProtectionUntilFirstUserAuthentication)
        }
    }

    static func removeAvatar(forConversationId id: String) {
        guard let url = container?.appendingPathComponent(avatarDirName, isDirectory: true)
            .appendingPathComponent(id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes the entire avatar directory.
    static func clearAvatars() {
        guard let dir = container?.appendingPathComponent(avatarDirName, isDirectory: true) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Removes everything Relay keeps in the App Group container outside the
    /// encrypted database. Call on sign-out, remote wipe and panic wipe.
    static func clearAll() {
        defaults?.removeObject(forKey: legacyConversationsKey)
        defaults?.removeObject(forKey: legacyPendingKey)
        defaults?.removeObject(forKey: unreadCountKey)
        clearAvatars()
        ShareSeal.deleteKey()
        guard let container else { return }
        try? FileManager.default.removeItem(at: container.appendingPathComponent(shareDirName, isDirectory: true))
        try? FileManager.default.removeItem(at: container.appendingPathComponent(broadcastFrameFile))
    }

    // MARK: - File helpers

    private static func shareDir() -> URL? { protectedDir(named: shareDirName) }
    private static func avatarDir() -> URL? { protectedDir(named: avatarDirName) }

    /// Creates (if needed) an App Group subdirectory excluded from backups.
    private static func protectedDir(named name: String) -> URL? {
        guard var dir = container?.appendingPathComponent(name, isDirectory: true) else { return nil }
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    @discardableResult
    private static func writeProtected(_ data: Data, to url: URL, protection: Data.WritingOptions) -> Bool {
        do {
            try data.write(to: url, options: [.atomic, protection])
            var fileURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? fileURL.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }
}
