//
//  CrossProcessLock.swift
//  RelayCore
//

import Foundation

/// An exclusive `flock` on a file in the App Group container, so the app and
/// the Notification Service Extension — separate processes sharing one
/// database — never decrypt at the same time. Two concurrent decrypts from the
/// same sender would read the same session state and the later write would
/// clobber the earlier ratchet step, breaking every later message.
public struct CrossProcessLock: Sendable {
    let url: URL

    public init(url: URL) { self.url = url }

    /// The shared lock for envelope processing in this App Group, if the
    /// container is available.
    public static func envelopeProcessing(appGroupId: String) -> CrossProcessLock? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
            .map { CrossProcessLock(url: $0.appendingPathComponent("envelope-processing.lock")) }
    }

    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return try body() } // can't lock: proceed rather than stall
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
