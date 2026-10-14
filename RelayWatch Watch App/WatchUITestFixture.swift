//
//  WatchUITestFixture.swift
//  RelayWatch Watch App
//
//  A built-in chat list for UI tests, which have no paired iPhone. Debug
//  builds only: launched with `WatchUITest.fixtureArgument`, the app shows
//  these chats and treats every send and call as accepted by the iPhone.
//

#if DEBUG
import Foundation

nonisolated enum WatchUITest {
    static let fixtureArgument = "-RelayWatchUITestFixture"
    /// No chats and nothing received yet: the first-launch screen.
    static let emptyArgument = "-RelayWatchUITestEmpty"
}

extension WatchSnapshot {
    nonisolated static func uiTestFixture(now: Date = Date()) -> WatchSnapshot {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        func minutesAgo(_ m: Int64) -> Int64 { nowMs - m * 60_000 }
        return WatchSnapshot(bubble: "0A84FF-5E5CE6", chats: [
            Chat(id: "alice", name: "Alice Smith", isGroup: false, canCall: true, unread: 2, messages: [
                Message(id: "a1", outgoing: true, text: "Lunch tomorrow?", sender: nil, timestamp: minutesAgo(30)),
                Message(id: "a2", outgoing: false, text: "Sure, noon works", sender: nil, timestamp: minutesAgo(5)),
                Message(id: "a3", outgoing: false, text: "See you there", sender: nil, timestamp: minutesAgo(4)),
            ]),
            Chat(id: "family", name: "Family", isGroup: true, canCall: false, unread: 0, messages: [
                Message(id: "f1", outgoing: false, text: "call:Missed group call", sender: nil, timestamp: minutesAgo(90)),
                Message(id: "f2", outgoing: false, text: "Dinner at 7", sender: "Mom", timestamp: minutesAgo(60)),
                Message(id: "f3", outgoing: true, text: "OK", sender: nil, timestamp: minutesAgo(59)),
            ]),
            Chat(id: "bob", name: "Bob", isGroup: false, canCall: true, unread: 0, messages: []),
        ])
    }
}
#endif
