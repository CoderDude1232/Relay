//
//  LinkConfirmation.swift
//  Relay
//
//  Text for the "open this link?" confirmation shown for links in received
//  messages. Shows the REAL destination (host in its ASCII/punycode form, so
//  look-alike Unicode domains are visible), not the link text the sender chose.
//

import Foundation

nonisolated enum LinkConfirmation {
    static func displayHost(for url: URL) -> String {
        if let host = url.host(percentEncoded: true), !host.isEmpty { return host }
        return url.scheme.map { "\($0): link" } ?? "this link"
    }

    static func message(for url: URL) -> String {
        var full = url.absoluteString
        if full.count > 200 { full = String(full.prefix(200)) + "…" }
        var lines = [full]
        switch url.scheme?.lowercased() {
        case "https":
            lines.append("Opening it lets that site see your IP address.")
        case "http":
            lines.append("This link isn't encrypted (http), and opening it lets that site see your IP address.")
        default:
            lines.append("This link opens another app or action, not a web page.")
        }
        return lines.joined(separator: "\n\n")
    }
}
