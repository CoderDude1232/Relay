//
//  DebugLogTests.swift
//  SecureStorageTests
//
//  The shareable debug log: storage limits, redaction, tags, and that a key
//  change is logged without the account id.
//

import CryptoCore
import Foundation
import LibSignalClient
import Testing

@testable import SecureStorage

private final class Credentials: IdentityCredentialProviding {
    let identity = IdentityKeyPair.generate()
    func identityKeyPair() throws -> IdentityKeyPair { identity }
    func registrationId() throws -> UInt32 { 42 }
}

private func makeStore() throws -> SecureStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-debuglog-\(UUID().uuidString).db").path
    return try SecureStore(path: path, key: .random(), credentials: Credentials())
}

private func entry(_ message: String, at date: Date = Date()) -> DebugLogEntry {
    DebugLogEntry(date: date, level: .warning, category: "test", message: message)
}

struct DebugLogStoreTests {
    @Test func entriesComeBackOldestFirst() throws {
        let log = try makeStore().debugLog
        try log.append([entry("one"), entry("two")])
        try log.append([entry("three")])
        #expect(try log.entries().map(\.message) == ["one", "two", "three"])
        #expect(try log.entries().first?.level == .warning)
        #expect(try log.entries().first?.category == "test")
    }

    @Test func keepsOnlyTheNewestEntries() throws {
        let log = try makeStore().debugLog
        let batch = (0..<(DebugLogStore.maxEntries + 25)).map { entry("line \($0)") }
        try log.append(batch)
        let kept = try log.entries()
        #expect(kept.count == DebugLogStore.maxEntries)
        #expect(kept.first?.message == "line 25")
        #expect(kept.last?.message == "line \(DebugLogStore.maxEntries + 24)")
    }

    @Test func dropsEntriesOlderThanMaxAge() throws {
        let log = try makeStore().debugLog
        let now = Date()
        try log.append([entry("old", at: now.addingTimeInterval(-DebugLogStore.maxAge - 60)),
                        entry("recent", at: now.addingTimeInterval(-60))], now: now)
        #expect(try log.entries().map(\.message) == ["recent"])
    }

    @Test func truncatesLongMessages() throws {
        let log = try makeStore().debugLog
        try log.append([entry(String(repeating: "x", count: 5000))])
        #expect(try log.entries().first?.message.count == DebugLogStore.maxMessageLength)
    }

    @Test func clearDeletesLinesAndRotatesTheSalt() throws {
        let log = try makeStore().debugLog
        let salt = try log.tagSalt()
        #expect(try log.tagSalt() == salt)
        try log.append([entry("x")])
        try log.clear()
        #expect(try log.entries().isEmpty)
        #expect(try log.tagSalt() != salt)
    }
}

struct DebugLogSinkTests {
    @Test func linesBeforeAttachAreWrittenOnAttach() throws {
        let sink = DebugLog()
        sink.record(entry("early"))
        #expect(sink.entries().map(\.message) == ["early"])
        let store = try makeStore().debugLog
        sink.attach(store)
        sink.record(entry("late"))
        #expect(sink.entries().map(\.message) == ["early", "late"])
        #expect(try store.entries().map(\.message) == ["early", "late"])
    }

    @Test func detachStopsWritingAndDropsPending() throws {
        let sink = DebugLog()
        let store = try makeStore().debugLog
        sink.attach(store)
        sink.record(entry("kept"))
        sink.detach()
        sink.record(entry("after detach"))
        #expect(try store.entries().map(\.message) == ["kept"])
        sink.detach()
        #expect(sink.entries().isEmpty)
    }

    @Test func linesBetweenAccountsReachNeitherLog() throws {
        let sink = DebugLog()
        let first = try makeStore().debugLog
        sink.attach(first)
        sink.record(entry("first account"))
        sink.detach()
        sink.record(entry("after sign-out"))
        let second = try makeStore().debugLog
        sink.attach(second)
        sink.record(entry("second account"))
        #expect(sink.entries().map(\.message) == ["second account"])
        #expect(try first.entries().map(\.message) == ["first account"])
    }

    @Test func literalsAreMarkedSoOnlyTheyArePublicInTheUnifiedLog() {
        let literal: RelayLogMessage = "starting call"
        let interpolated: RelayLogMessage = "attempt \(2)"
        #expect(literal.isLiteral)
        #expect(!interpolated.isLiteral)
    }

    @Test func tagsAreStablePerSaltAndShort() throws {
        let sink = DebugLog()
        #expect(sink.tag(peer: "a") == "c-?")
        let store = try makeStore().debugLog
        sink.attach(store)
        let tag = sink.tag(peer: "123e4567-e89b-12d3-a456-426614174000")
        #expect(tag.count == 8)
        #expect(tag.hasPrefix("c-"))
        #expect(sink.tag(peer: "123e4567-e89b-12d3-a456-426614174000") == tag)
        #expect(sink.tag(peer: "someone else") != tag)
        #expect(sink.tag(key: Data([1, 2, 3])).hasPrefix("k-"))

        // Another install (another salt) tags the same account differently.
        let other = DebugLog()
        other.attach(try makeStore().debugLog)
        #expect(other.tag(peer: "123e4567-e89b-12d3-a456-426614174000") != tag)

        // Clearing rotates the salt.
        sink.clear()
        #expect(sink.tag(peer: "123e4567-e89b-12d3-a456-426614174000") != tag)
    }

    @Test func exportHasHeaderLegendAndLines() throws {
        let sink = DebugLog()
        sink.attach(try makeStore().debugLog)
        let date = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 86_400).rounded(.down) * 86_400)
        sink.record(DebugLogEntry(date: date, level: .error, category: "safety", message: "blocked"))
        let text = DebugLog.exportText(header: ["Relay debug log"], entries: sink.entries())
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(text.hasPrefix("Relay debug log\n"))
        #expect(text.contains("\(formatter.string(from: date)) ERROR [safety] blocked"))
    }
}

struct PrivacyRedactorTests {
    private func redacts(_ secret: String, in text: String) -> Bool {
        let out = PrivacyRedactor.redactedString(text)
        return !out.contains(secret) && out.contains(PrivacyRedactor.redacted)
    }

    @Test func removesPersonalDetailsFromErrorText() {
        #expect(redacts("morgan@example.com", in: "signup failed for morgan@example.com"))
        #expect(redacts("+61 412 345 678", in: "number +61 412 345 678 rejected"))
        #expect(redacts("relay.example.org", in: "URLError -1004 https://relay.example.org/v1/keys?x=1"))
        #expect(redacts("192.168.1.20", in: "proxy 192.168.1.20 refused"))
        #expect(redacts("fe80::1c2b:3d4e", in: "candidate fe80::1c2b:3d4e failed"))
        #expect(redacts("2001:db8:85a3:0:0:8a2e:370:7334", in: "via 2001:db8:85a3:0:0:8a2e:370:7334"))
        #expect(redacts("123456789012", in: "registration 123456789012"))
        // A temp-file error names the attachment, which is chat content.
        let fileError = #"Error Domain=NSCocoaErrorDomain Code=4 "The file “Beach with Sam.jpg” couldn’t be saved." UserInfo={NSFilePath=/private/var/mobile/tmp/Beach with Sam.jpg, NSUnderlyingError=0x1}"#
        let cleaned = PrivacyRedactor.redactedString(fileError)
        #expect(!cleaned.contains("Sam"))
        #expect(!cleaned.contains("/private/var"))
        #expect(cleaned.contains("NSCocoaErrorDomain Code=4"))
    }

    @Test func leavesOrdinaryLogTextAlone() {
        let text = "reconnecting call (attempt 2) at 19:53:46; devices [1:k-1a2b3c 2:k-4d5e6f] distinct 2; 3 KB/s"
        #expect(PrivacyRedactor.redactedString(text) == text)
        // Only `name: value` / `name=value` count as a credential, not prose.
        let prose = "voip token uploaded; access key upload failed (attempt 2); signed prekey republish failed"
        #expect(PrivacyRedactor.redactedString(prose) == prose)
    }

    @Test func redactsCredentialAssignments() {
        for text in ["key: abc123", "accessKey=abc123", #"{"token":"abc123"}"#, "password = abc123"] {
            #expect(!PrivacyRedactor.redactedString(text).contains("abc123"), "\(text)")
        }
    }
}

struct RelayLogMessageTests {
    @Test func redactsInterpolatedAndLiteralSecrets() {
        let account = "123e4567-e89b-12d3-a456-426614174000"
        let message: RelayLogMessage = "send failed for \(account) token=abc123 count \(3)"
        #expect(!message.text.contains(account))
        #expect(!message.text.contains("abc123"))
        #expect(message.text.contains("count 3"))
        // A plain literal is the author's text and isn't scanned.
        let literal: RelayLogMessage = "apns token upload failed"
        #expect(literal.text == "apns token upload failed")
    }
}

/// Uses `DebugLog.shared`, which every store in the process logs into.
@Suite(.serialized)
struct IdentityLoggingTests {
    @Test func keyChangeIsLoggedWithTagsNotTheAccount() throws {
        let storage = try makeStore()
        DebugLog.shared.attach(storage.debugLog)
        defer { DebugLog.shared.detach() }

        let account = "9b2f4c1e-0000-4000-8000-00000000abcd"
        let address = try ProtocolAddress(name: account, deviceId: 1)
        let first = IdentityKeyPair.generate().identityKey
        let second = IdentityKeyPair.generate().identityKey
        _ = try storage.signalStore.saveIdentity(first, for: address, context: NullContext())
        _ = try storage.signalStore.saveIdentity(second, for: address, context: NullContext())
        try storage.signalStore.pruneIdentities(address: account, keepingDeviceIds: [2])

        let peerTag = DebugLog.shared.tag(peer: account)
        let lines = DebugLog.shared.entries().filter { $0.message.contains(peerTag) }.map(\.message)
        #expect(lines.contains { $0.hasPrefix("first identity (trust on first use): \(peerTag) device 1") })
        let firstTag = DebugLog.shared.tag(key: first.serialize())
        let secondTag = DebugLog.shared.tag(key: second.serialize())
        #expect(lines.contains("identity changed: \(peerTag) device 1 \(firstTag) -> \(secondTag)"))
        #expect(lines.contains { $0.hasPrefix("dropped identities of removed devices: \(peerTag) devices 1") })
        #expect(!DebugLog.exportText(header: [], entries: DebugLog.shared.entries()).contains(account))
    }
}
