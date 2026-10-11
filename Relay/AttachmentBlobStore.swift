//
//  AttachmentBlobStore.swift
//  Relay
//
//  On-disk cache of attachment ciphertext in the App Group container, with
//  complete file protection. Plaintext media is decrypted to memory on demand
//  and never written to disk.
//

import Foundation

struct AttachmentBlobStore {
    private let directory: URL

    init(appGroupId: String) {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = container.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Attachment ids come from other people's messages, so anything but a plain
    /// token (no "/", no "..") is rejected; otherwise "../relay.db" could reach
    /// files outside the cache.
    static func isSafeId(_ id: String) -> Bool {
        (1...128).contains(id.count) && id.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || char == "-" || char == "_")
        }
    }

    private func url(for id: String) throws -> URL {
        guard Self.isSafeId(id) else { throw CocoaError(.fileReadInvalidFileName) }
        return directory.appendingPathComponent(id, isDirectory: false)
    }

    func exists(_ id: String) -> Bool {
        guard let url = try? url(for: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func write(_ ciphertext: Data, for id: String) throws {
        try ciphertext.write(to: try url(for: id), options: [.atomic, .completeFileProtection])
    }

    func read(_ id: String) throws -> Data {
        try Data(contentsOf: try url(for: id))
    }

    func delete(_ id: String) {
        guard let url = try? url(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes cached ciphertext no attachment row refers to any more (expired
    /// messages, deleted chats). Files younger than `minimumAge` are kept: a
    /// send writes its file before the row exists.
    func sweepOrphans(keeping ids: Set<String>, minimumAge: TimeInterval = 3600) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-minimumAge)
        for file in files where !ids.contains(file.lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: file) }
        }
    }
}
