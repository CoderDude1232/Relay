//
//  WatchSnapshot.swift
//
//  Recent chats sent from the iPhone to the Apple Watch app over
//  WatchConnectivity, and the requests the watch sends back. The same file is
//  copied into "RelayWatch Watch App"; keep the copies identical.
//

import Foundation

struct WatchSnapshot: Codable, Sendable {
    struct Message: Codable, Sendable, Identifiable, Hashable {
        let id: String
        let outgoing: Bool
        let text: String
        let sender: String?
        /// Milliseconds since 1970.
        let timestamp: Int64
    }

    struct Chat: Codable, Sendable, Identifiable, Hashable {
        let id: String
        let name: String
        let isGroup: Bool
        let canCall: Bool
        let unread: Int
        let messages: [Message]
    }

    /// "RRGGBB-RRGGBB" outgoing bubble gradient, nil = accent colour.
    let bubble: String?
    let chats: [Chat]

    static let empty = WatchSnapshot(bubble: nil, chats: [])
}

/// Message keys shared by both sides.
enum WatchProtocol {
    static let snapshotKey = "snapshot"
    static let actionKey = "action"
    static let conversationKey = "conversationId"
    static let textKey = "text"
    static let videoKey = "video"
    static let okKey = "ok"
    static let errorKey = "error"

    enum Action: String {
        case refresh, send, call, markRead
    }
}
