//
//  Spoilers.swift
//  RelayCore
//
//  Spoiler text is written ||like this|| inside a message body. Chat bubbles
//  hide it until tapped; everywhere else that shows a message as plain text
//  (chat list, notifications, banners, replies, widgets) blanks it out.
//

import Foundation

public enum Spoilers {
    /// One spoiler: text between double bars, on one line.
    nonisolated(unsafe) public static let regex = /\|\|([^\n]+?)\|\|/

    /// Shown in place of hidden spoiler text in plain-text previews.
    public static let placeholder = "▒▒▒▒"

    public static func contains(_ text: String) -> Bool {
        text.contains("||") && text.contains(regex)
    }

    /// The text with every spoiler blanked out.
    public static func redact(_ text: String) -> String {
        guard text.contains("||") else { return text }
        return text.replacing(regex) { _ in placeholder }
    }

    /// The text with the bars removed and the spoilers readable (copying,
    /// editing a message shows the raw form instead).
    public static func reveal(_ text: String) -> String {
        guard text.contains("||") else { return text }
        return text.replacing(regex) { String($0.output.1) }
    }
}
