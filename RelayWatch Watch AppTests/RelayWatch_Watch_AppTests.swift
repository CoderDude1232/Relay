//
//  RelayWatch_Watch_AppTests.swift
//  RelayWatch Watch AppTests
//
//  The watch's own logic: the snapshot format shared with the iPhone,
//  reconciling sent bubbles with the iPhone's copy, and display helpers.
//

import Foundation
import SwiftUI
import Testing
@testable import RelayWatch_Watch_App

private typealias Message = WatchSnapshot.Message

private let now: Int64 = 1_800_000_000_000

private func message(_ text: String, outgoing: Bool = true, at timestamp: Int64, id: String = UUID().uuidString) -> Message {
    Message(id: id, outgoing: outgoing, text: text, sender: nil, timestamp: timestamp)
}

private func snapshot(_ chatId: String, _ messages: [Message]) -> WatchSnapshot {
    WatchSnapshot(bubble: nil, chats: [
        WatchSnapshot.Chat(id: chatId, name: "Alice", isGroup: false, canCall: true, unread: 0, messages: messages)
    ])
}

struct SnapshotFormatTests {
    /// The iPhone encodes `Relay/WatchSnapshot.swift`; this is its JSON shape.
    @Test func decodesTheIPhonesJSON() throws {
        let json = Data("""
        {"bubble":"FF0000-00FF00","chats":[{"id":"c1","name":"Alice","isGroup":false,"canCall":true,"unread":3,
        "messages":[{"id":"m1","outgoing":false,"text":"hi","sender":"Al","timestamp":1700000000000}]}]}
        """.utf8)
        let decoded = try JSONDecoder().decode(WatchSnapshot.self, from: json)
        #expect(decoded.bubble == "FF0000-00FF00")
        #expect(decoded.chats.count == 1)
        let chat = try #require(decoded.chats.first)
        #expect(chat.unread == 3)
        #expect(chat.messages == [Message(id: "m1", outgoing: false, text: "hi", sender: "Al", timestamp: 1_700_000_000_000)])
    }

    @Test func missingBubbleAndSenderDecodeAsNil() throws {
        let json = Data("""
        {"chats":[{"id":"c1","name":"A","isGroup":true,"canCall":false,"unread":0,
        "messages":[{"id":"m1","outgoing":true,"text":"x","timestamp":1}]}]}
        """.utf8)
        let decoded = try JSONDecoder().decode(WatchSnapshot.self, from: json)
        #expect(decoded.bubble == nil)
        #expect(decoded.chats.first?.messages.first?.sender == nil)
    }

    @Test func roundTrips() throws {
        let original = WatchSnapshot.uiTestFixture()
        let decoded = try JSONDecoder().decode(WatchSnapshot.self, from: JSONEncoder().encode(original))
        #expect(decoded.chats == original.chats)
        #expect(decoded.bubble == original.bubble)
    }
}

struct PendingReconcileTests {
    @Test func confirmedBubbleIsDropped() {
        let sent = message("On my way", at: now - 1_000)
        let result = WatchSession.reconcile(
            ["c1": [sent]], with: snapshot("c1", [message("On my way", at: now - 500)]), nowMs: now
        )
        #expect(result.isEmpty)
    }

    @Test func anOlderMessageWithTheSameTextDoesNotConfirm() {
        let sent = message("OK", at: now - 1_000)
        let history = [message("OK", at: now - 3_600_000)]
        let result = WatchSession.reconcile(["c1": [sent]], with: snapshot("c1", history), nowMs: now)
        #expect(result["c1"] == [sent])
    }

    @Test func eachStoredMessageConfirmsOneBubble() {
        let first = message("OK", at: now - 2_000)
        let second = message("OK", at: now - 1_000)
        let result = WatchSession.reconcile(
            ["c1": [first, second]], with: snapshot("c1", [message("OK", at: now - 1_500)]), nowMs: now
        )
        #expect(result["c1"]?.count == 1)
    }

    @Test func incomingMessagesNeverConfirm() {
        let sent = message("👍", at: now - 1_000)
        let result = WatchSession.reconcile(
            ["c1": [sent]], with: snapshot("c1", [message("👍", outgoing: false, at: now)]), nowMs: now
        )
        #expect(result["c1"] == [sent])
    }

    @Test func toleratesTheIPhoneClockTrailingSlightly() {
        let sent = message("Hi", at: now - 1_000)
        let stored = message("Hi", at: now - 1_000 - WatchSession.confirmSkewMs + 1)
        #expect(WatchSession.reconcile(["c1": [sent]], with: snapshot("c1", [stored]), nowMs: now).isEmpty)
    }

    @Test func staleBubbleIsDropped() {
        let sent = message("Hello?", at: now - WatchSession.pendingMaxAgeMs - 1)
        #expect(WatchSession.reconcile(["c1": [sent]], with: snapshot("c1", []), nowMs: now).isEmpty)
    }

    @Test func emptySnapshotClearsEverything() {
        let sent = message("Hi", at: now)
        #expect(WatchSession.reconcile(["c1": [sent]], with: .empty, nowMs: now).isEmpty)
    }

    @Test func otherChatsKeepTheirBubbles() {
        let sent = message("Hi", at: now - 1_000)
        let result = WatchSession.reconcile(["c2": [sent]], with: snapshot("c1", []), nowMs: now)
        #expect(result["c2"] == [sent])
    }
}

@MainActor
struct DisplayTests {
    @Test func previewMarksOurOwnMessages() {
        let fixture = WatchSnapshot.uiTestFixture()
        #expect(fixture.chats.first { $0.id == "alice" }?.preview == "See you there")
        #expect(fixture.chats.first { $0.id == "family" }?.preview == "You: OK")
        #expect(fixture.chats.first { $0.id == "bob" }?.preview == nil)
    }

    @Test func initials() {
        #expect(WatchAvatar.initials(for: "Ada Lovelace") == "AL")
        #expect(WatchAvatar.initials(for: "bob") == "B")
        #expect(WatchAvatar.initials(for: "Mary Ann Evans") == "MA")
        #expect(WatchAvatar.initials(for: "") == "")
    }

    @Test func bubbleHexColours() {
        #expect(Color(relayHex: "0A84FF") != nil)
        #expect(Color(relayHex: "0a84ff") != nil)
        #expect(Color(relayHex: "0A84F") == nil)
        #expect(Color(relayHex: "GGGGGG") == nil)
        #expect(Color(relayHex: "") == nil)
    }
}
