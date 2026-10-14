//
//  TextRulesTests.swift
//  RelayCoreTests
//
//  Small pure helpers: mention matching, reserved names, content padding.
//

import Foundation
import RelayKit
import Testing

@testable import RelayCore

struct MentionsTests {
    @Test func matchesWholeWordsCaseInsensitively() {
        #expect(Mentions.contains("hey @Ethan look", username: "ethan"))
        #expect(Mentions.contains("@ethan", username: "ethan"))
        #expect(Mentions.contains("thanks, @ethan!", username: "ethan"))
    }

    @Test func ignoresLongerNamesAndEmailAddresses() {
        #expect(!Mentions.contains("@ethan2 look", username: "ethan"))
        #expect(!Mentions.contains("mail me@ethan", username: "ethan"))
        #expect(!Mentions.contains("anything", username: ""))
    }
}

struct ReservedNamesTests {
    @Test(arguments: ["You", "Note To Self", "re1ay", "Y.o.u", "Relay Support", "ADMIN", "Rélay"])
    func reserved(_ name: String) {
        #expect(ReservedNames.isReserved(name))
    }

    @Test(arguments: ["Ethan", "Yourself Truly", "Alice"])
    func allowed(_ name: String) {
        #expect(!ReservedNames.isReserved(name))
    }
}

struct ContentPaddingTests {
    @Test func padsToTheNextBucketAndStillDecodes() throws {
        for length in [0, 10, 200, 600, 3000, 9000] {
            var content = Relay_Content_Content()
            content.text.body = String(repeating: "x", count: length)
            let plain = try content.serializedData()
            let padded = try ContentPadding.pad(plain)
            #expect(padded.count > plain.count)
            #expect(padded.count <= ContentPadding.targetSize(for: plain.count))
            let decoded = try Relay_Content_Content(serializedBytes: padded)
            #expect(decoded.text.body == content.text.body)
        }
    }

    @Test func bucketsAreFixed() {
        #expect(ContentPadding.targetSize(for: 0) == 256)
        #expect(ContentPadding.targetSize(for: 256) == 512)
        #expect(ContentPadding.targetSize(for: 4096) == 8192)
        #expect(ContentPadding.targetSize(for: 5000) == 8192)
    }
}
