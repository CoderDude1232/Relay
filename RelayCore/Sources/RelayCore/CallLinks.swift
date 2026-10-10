//
//  CallLinks.swift
//  RelayCore
//
//  Call links this account has created, kept in App Group defaults so the NSE
//  can check a join request's secret before showing a "wants to join" banner.
//  Never leaves the device.
//

import Foundation
import Security

public struct CallLinkRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: String        // call id (UUID)
    public let secret: String    // 22-char base64url, only in the link's #fragment
    public var name: String
    public let createdAt: Date

    public init(id: String, secret: String, name: String, createdAt: Date) {
        self.id = id; self.secret = secret; self.name = name; self.createdAt = createdAt
    }

    /// https://relaymsg.app/call/<id>#<hostAccount>.<secret>
    public func url(hostAccount: String) -> URL {
        URL(string: "https://relaymsg.app/call/\(id)#\(hostAccount).\(secret)")!
    }
}

public enum CallLinkRecords {
    static let key = "relay.callLinks"

    public static func load(defaults: UserDefaults?) -> [CallLinkRecord] {
        guard let data = defaults?.data(forKey: key),
              let links = try? JSONDecoder().decode([CallLinkRecord].self, from: data)
        else { return [] }
        return links
    }

    public static func save(_ links: [CallLinkRecord], defaults: UserDefaults?) {
        defaults?.set(try? JSONEncoder().encode(links), forKey: key)
    }

    public static func clear(defaults: UserDefaults?) {
        defaults?.removeObject(forKey: key)
    }

    public static func secret(forCallId id: String, defaults: UserDefaults?) -> String? {
        load(defaults: defaults).first { $0.id == id }?.secret
    }

    public static func makeSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
