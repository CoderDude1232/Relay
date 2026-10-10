//
//  TempMediaFiles.swift
//  Relay
//
// Decrypted attachments that must exist as files (QuickLook, AVPlayer).
// Files get random names and complete Data Protection, are excluded from
// backup, deleted when the viewer closes, and swept at launch.
//

import Foundation

nonisolated enum TempMediaFiles {
    private static let dirName = "relay-media-tmp"

    /// tmp/relay-media-tmp, created on demand and excluded from backup.
    static var directory: URL {
        var dir = FileManager.default.temporaryDirectory.appendingPathComponent(dirName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    /// Writes decrypted bytes to a randomly named file, keeping only the
    /// extension of `originalName` so the right viewer is picked.
    static func write(_ data: Data, originalName: String?, fallbackExtension: String) throws -> URL {
        let ext = sanitizedExtension(from: originalName) ?? fallbackExtension
        var url = directory.appendingPathComponent(UUID().uuidString)
        if !ext.isEmpty { url.appendPathExtension(ext) }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    /// Deletes one temp file (no-op for nil or files outside the temp dir).
    static func remove(_ url: URL?) {
        guard let url, url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes every leftover decrypted temp file. Call at launch and on wipe.
    static func sweep() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(dirName, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    private static func sanitizedExtension(from name: String?) -> String? {
        guard let name else { return nil }
        let ext = (URL(fileURLWithPath: name).lastPathComponent as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, ext.count <= 8, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return ext
    }
}
