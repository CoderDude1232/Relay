//
//  ReservedNames.swift
//  RelayCore
//
//  Names nobody may use as a username or display name: what the app calls
//  you and its own chats ("You", "Relay", "Note to Self") and names that
//  would pass for staff or the system. Must match the relay's
//  server/internal/store/reserved_names.go, which enforces it for usernames.
//

import Foundation

public enum ReservedNames {
    static let names: Set<String> = [
        "you", "me", "myself", "self", "note", "notes",
        "notetoself", "notestoself", "savedmessages",
        "system", "admin", "administrator", "support", "help",
        "helpdesk", "official", "team", "staff", "moderator",
        "mod", "security", "safety", "root", "null", "nil",
        "undefined", "unknown", "deleted", "deletedaccount",
        "anonymous", "everyone", "all", "here",
    ]

    private static let lookAlikes: [Character: Character] = [
        "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b", "9": "g",
        "$": "s", "@": "a", "|": "l",
    ]

    /// Lower case, look-alike digits read as letters, everything but a–z
    /// dropped (accents folded first), so "Note To Self", "re1ay" and
    /// "Y.o.u" all compare equal to the reserved form.
    static func normalized(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        return String(folded.compactMap { ch -> Character? in
            let c = lookAlikes[ch] ?? ch
            return ("a"..."z").contains(c) ? c : nil
        })
    }

    public static func isReserved(_ name: String) -> Bool {
        let n = normalized(name)
        let ln = n.replacingOccurrences(of: "i", with: "l")
        return names.contains(n) || names.contains(ln) || n.hasPrefix("relay") || ln.hasPrefix("relay")
    }
}
