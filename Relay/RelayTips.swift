//
//  RelayTips.swift
//  Relay
//
//  One-time hints for gestures that aren't visible: shown inline, one at a
//  time, and gone once dismissed or once the gesture has been used.
//

import SwiftUI
import TipKit

nonisolated struct SwipeToReplyTip: Tip {
    var title: Text { Text("Swipe to Reply") }
    var message: Text? { Text("Swipe a message to the right to reply to it.") }
    var image: Image? { Image(systemName: "arrowshape.turn.up.left") }
}

nonisolated struct DoubleTapReactTip: Tip {
    var title: Text { Text("Double-Tap to React") }
    var message: Text? { Text("Double-tap a message to send ❤️. Touch and hold for more reactions.") }
    var image: Image? { Image(systemName: "heart") }
}

nonisolated struct HoldToRecordTip: Tip {
    var title: Text { Text("Hold to Record") }
    var message: Text? { Text("Hold the microphone and let go to send. Slide left to cancel, or up to keep recording hands-free.") }
    var image: Image? { Image(systemName: "mic") }
}

nonisolated struct EditedHistoryTip: Tip {
    /// Set once an open chat has an edited message.
    @Parameter static var chatHasEdits: Bool = false

    var title: Text { Text("See Earlier Versions") }
    var message: Text? { Text("Tap Edited under a message to see what it said before.") }
    var image: Image? { Image(systemName: "pencil") }
    var rules: [Rule] { [#Rule(Self.$chatHasEdits) { $0 == true }] }
}

nonisolated struct ChatListGesturesTip: Tip {
    var title: Text { Text("More in Every Chat") }
    var message: Text? { Text("Touch and hold a chat to peek at it. Swipe right to mark it read or pin it, left to mute, archive or delete.") }
    var image: Image? { Image(systemName: "hand.tap") }
}

enum RelayTips {
    /// Hints shown in a chat, one after another.
    @MainActor static let chat = TipGroup(.ordered) {
        SwipeToReplyTip()
        DoubleTapReactTip()
        HoldToRecordTip()
        EditedHistoryTip()
    }

    static func configure() {
        try? Tips.configure([.displayFrequency(.immediate)])
    }
}
