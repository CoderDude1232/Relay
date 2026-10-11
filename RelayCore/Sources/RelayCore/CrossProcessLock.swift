//
//  CrossProcessLock.swift
//  RelayCore
//

import Foundation

/// An exclusive `flock` in the App Group container that keeps the app and the
/// NSE from decrypting at the same time. Two concurrent decrypts from one sender
/// would read the same session state, and the later write would undo the
/// earlier ratchet step, breaking every message after it.
public struct CrossProcessLock: Sendable {
    let url: URL
    /// How long to wait for the other process; nil waits as long as it takes.
    /// The notification extension sets one: blocked behind a suspended app it
    /// would otherwise run out its 30 seconds and be killed mid-work.
    let timeout: TimeInterval?

    /// The lock wasn't free within `timeout`. Nothing was done; the caller
    /// should leave the envelope for later (not ack it).
    public struct Timeout: Error {}

    public init(url: URL, timeout: TimeInterval? = nil) {
        self.url = url
        self.timeout = timeout
    }

    /// The envelope-processing lock for this App Group, if the container exists.
    public static func envelopeProcessing(appGroupId: String, timeout: TimeInterval? = nil) -> CrossProcessLock? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
            .map { CrossProcessLock(url: $0.appendingPathComponent("envelope-processing.lock"), timeout: timeout) }
    }

    public func withLock<T>(_ body: () throws -> T) throws -> T {
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return try body() } // can't lock: proceed rather than stall
        defer { close(fd) }
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { throw Timeout() }
                usleep(50_000)
            }
        } else {
            while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
