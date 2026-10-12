//
//  ProfileText.swift
//  RelayCore
//
//  Cleans the profile text other people send before it's stored or shown:
//  no direction overrides or invisible characters (which can make a name read
//  as someone else's, or reverse surrounding text), no line breaks in a name,
//  bounded lengths, and no names the app itself uses for system senders.
//

import Foundation

public enum ProfileText {
    public static let maxNameLength = 64
    public static let maxStatusLength = 140
    public static let maxBioLength = 500
    public static let maxLinks = 5
    public static let maxLinkLabelLength = 40
    public static let maxLinkURLLength = 300

    /// A display name: one line, visible characters only. Empty if nothing
    /// usable remains or it's a reserved name.
    public static func name(_ raw: String) -> String {
        let cleaned = collapseWhitespace(stripInvisible(raw, keepNewlines: false))
        let limited = String(cleaned.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
        // Joiners and direction marks alone would be an invisible name.
        let visible = limited.unicodeScalars.contains { !(0x200C...0x200F).contains($0.value) && !$0.properties.isWhitespace }
        return !visible || ReservedNames.isReserved(limited) ? "" : limited
    }

    /// A group name: one line, visible characters, at most 100.
    public static func groupName(_ raw: String) -> String {
        String(collapseWhitespace(stripInvisible(raw, keepNewlines: false)).prefix(100))
            .trimmingCharacters(in: .whitespaces)
    }

    public static func groupDescription(_ raw: String) -> String {
        let text = stripInvisible(raw, keepNewlines: true)
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        return String(text.prefix(1000)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func status(_ raw: String) -> String {
        String(collapseWhitespace(stripInvisible(raw, keepNewlines: false)).prefix(maxStatusLength))
            .trimmingCharacters(in: .whitespaces)
    }

    public static func bio(_ raw: String) -> String {
        let text = stripInvisible(raw, keepNewlines: true)
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        return String(text.prefix(maxBioLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Links kept only when they're http(s) URLs with a host.
    public static func links(_ raw: [(label: String, url: String)]) -> [(label: String, url: String)] {
        raw.compactMap { link -> (label: String, url: String)? in
            let url = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard url.count <= maxLinkURLLength,
                  let parsed = URL(string: url),
                  let scheme = parsed.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = parsed.host, !host.isEmpty
            else { return nil }
            let label = String(collapseWhitespace(stripInvisible(link.label, keepNewlines: false))
                .prefix(maxLinkLabelLength)).trimmingCharacters(in: .whitespaces)
            return (label, url)
        }
        .prefix(maxLinks)
        .map { $0 }
    }

    /// Removes control characters, direction overrides/embeddings/isolates
    /// and other invisible format characters.
    static func stripInvisible(_ s: String, keepNewlines: Bool) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x0A where keepNewlines:
                out.append(scalar)
            case 0x09, 0x0A, 0x0D:
                out.append(" ")
            case 0x200C, 0x200D, 0x200E, 0x200F:
                // Joiners (emoji sequences, Persian and Indic names) and
                // direction marks (right-to-left names) are part of real names.
                out.append(scalar)
            case 0x00...0x1F, 0x7F...0x9F,          // C0/C1 controls
                 0x061C,                            // Arabic letter mark
                 0x202A...0x202E, 0x2066...0x2069,  // embeddings, overrides, isolates
                 0x200B, 0x2060...0x2064,           // zero-width space, invisible operators
                 0xFEFF, 0xFFF9...0xFFFB,           // BOM, interlinear annotations
                 0x2028, 0x2029, 0x00AD, 0x115F, 0x1160, 0x3164, 0xFFA0, 0x180E:
                if scalar.value == 0x2028 || scalar.value == 0x2029 { out.append(keepNewlines ? "\n" : " ") }
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }

    static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
