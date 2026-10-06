//
//  Mentions.swift
//  RelayCore
//

import Foundation

public enum Mentions {
    /// Whether `body` mentions `@username` as a whole word — so "@test2" is not
    /// found inside "@test2ax" or "me@test2". Case-insensitive.
    public static func contains(_ body: String, username: String) -> Bool {
        guard !username.isEmpty else { return false }
        let target = "@\(username)"
        func isNameChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var searchStart = body.startIndex
        while let found = body.range(of: target, options: .caseInsensitive, range: searchStart..<body.endIndex) {
            let endsWord = found.upperBound == body.endIndex || !isNameChar(body[found.upperBound])
            let startsWord = found.lowerBound == body.startIndex
                || !isNameChar(body[body.index(before: found.lowerBound)])
            if endsWord && startsWord { return true }
            searchStart = found.upperBound
        }
        return false
    }
}
