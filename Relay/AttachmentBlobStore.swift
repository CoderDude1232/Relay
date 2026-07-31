//
//  AttachmentBlobStore.swift
//  Relay
//
//  On-disk cache of attachment *ciphertext* in the App Group container. We
//  only ever persist the encrypted blob (and even that with complete file
//  protection); plaintext media is decrypted to memory on demand and never
//  written to disk, matching the SQLCipher-at-rest guarantee.
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

    private func url(for id: String) -> URL {
        directory.appendingPathComponent(id)
    }

    func exists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    func write(_ ciphertext: Data, for id: String) throws {
        try ciphertext.write(to: url(for: id), options: [.atomic, .completeFileProtection])
    }

    func read(_ id: String) throws -> Data {
        try Data(contentsOf: url(for: id))
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
