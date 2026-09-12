//
//  PrivacyRedactor.swift
//  Relay
//

import Foundation

enum PrivacyRedactor {
    static let redacted = "<redacted>"

    static func error(_ error: any Error) -> String {
        redactedString(String(describing: error))
    }

    static func localizedError(_ error: any Error) -> String {
        redactedString(error.localizedDescription)
    }

    static func redactedString(_ value: String) -> String {
        var output = value
        let patterns = [
            #"(?i)\bbearer\s+[^\s,;]+"#,
            #"(?i)(authorization|bearer|basic|password|token|secret|nonce|key|credential)=([^\s,;]+)"#,
            #"(?i)(authorization|bearer|basic|password|token|secret|nonce|key|credential)([\"':\s=]+)([^\s,;}]+)"#,
            #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#,
            #"\b[0-9a-fA-F]{32,}\b"#,
            #"\b[A-Za-z0-9+/]{48,}={0,2}\b"#,
        ]

        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: redacted,
                options: .regularExpression
            )
        }
        return output
    }

    #if DEBUG
    static func runSelfCheck() {
        let sample = "Authorization: Bearer abcdef123456 token=secretvalue 123E4567-E89B-12D3-A456-426614174000"
        let cleaned = redactedString(sample)
        assert(!cleaned.contains("abcdef123456"))
        assert(!cleaned.contains("secretvalue"))
        assert(!cleaned.contains("123E4567-E89B-12D3-A456-426614174000"))
    }
    #endif
}
