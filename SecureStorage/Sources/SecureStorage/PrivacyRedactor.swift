//
//  PrivacyRedactor.swift
//  SecureStorage
//
//  Strips credentials, tokens, keys, nonces, UUIDs (account ids), long hex
//  and long base64, plus personal details an error can carry (email
//  addresses, phone numbers, URLs, IP addresses, file paths and the file
//  names Apple quotes in error text, which for attachments are the sender's)
//  from text before it is logged. Every interpolated RelayLog line passes
//  through it, so the debug log a user shares holds none of these.
//

import Foundation

public enum PrivacyRedactor {
    public static let redacted = "<redacted>"

    /// Applied in order; a template may keep a captured prefix.
    private static let rules: [(NSRegularExpression, String)] = [
        // NSError userInfo paths and URLs (values may contain spaces).
        (#"\b(NS\w*(?:Path|URL)\w*=)[^,}]+"#, "$1\(redacted)"),
        (#"(?i)\b[a-z][a-z0-9+.-]*://[^\s,;)}\"'”]+"#, redacted),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, redacted),
        // File names Apple quotes in error text: “Holiday.jpg”.
        (#"“[^”]*”"#, "“\(redacted)”"),
        (#"(?:~|/)(?:[^\s/:,;\"'”]+/)+[^\s:,;\"'”)]*"#, redacted),
        (#"(?i)\bbearer\s+[^\s,;]+"#, redacted),
        // `name=value`, `name: value` and JSON `"name":"value"`. A plain space
        // isn't a separator, so prose like "token upload failed" survives.
        (#"(?i)(authorization|bearer|basic|password|token|secret|nonce|key|credential)(s?[\"']?\s*[:=]\s*[\"']?)[^\s,;}\"']+"#,
         "$1$2\(redacted)"),
        (#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, redacted),
        (#"\b[0-9a-fA-F]{32,}\b"#, redacted),
        (#"\b[A-Za-z0-9+/]{48,}={0,2}\b"#, redacted),
        // IPv4, then IPv6 (three or more colons, or a "::" form).
        (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, redacted),
        (#"(?i)\b(?:[0-9a-f]{1,4}:){3,7}[0-9a-f]{1,4}\b"#, redacted),
        (#"(?i)(?:\b[0-9a-f]{1,4})?(?::[0-9a-f]{1,4})*::(?:[0-9a-f]{1,4}\b)(?::[0-9a-f]{1,4}\b)*"#, redacted),
        // Phone numbers, and other long digit runs (registration ids, numbers).
        (#"\+\d[\d\s().-]{6,}\d"#, redacted),
        (#"\b\d{9,}\b"#, redacted),
    ].map { pattern, template in
        // The patterns are constants; a typo should fail loudly in tests.
        (try! NSRegularExpression(pattern: pattern), template)
    }

    public static func redactedString(_ value: String) -> String {
        let output = NSMutableString(string: value)
        for (regex, template) in rules {
            regex.replaceMatches(in: output, range: NSRange(location: 0, length: output.length),
                                 withTemplate: template)
        }
        return output as String
    }

    #if DEBUG
    public static func runSelfCheck() {
        let sample = "Authorization: Bearer abcdef123456 token=secretvalue 123E4567-E89B-12D3-A456-426614174000"
        let cleaned = redactedString(sample)
        assert(!cleaned.contains("abcdef123456"))
        assert(!cleaned.contains("secretvalue"))
        assert(!cleaned.contains("123E4567-E89B-12D3-A456-426614174000"))
    }
    #endif
}
