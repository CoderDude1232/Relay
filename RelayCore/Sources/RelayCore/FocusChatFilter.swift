//
//  FocusChatFilter.swift
//  RelayCore
//
//  The chats a Focus (Settings > Focus > Focus Filters) lets through. Set by
//  the app's Focus filter intent; read by the app's chat list and banners and
//  by the NSE, which delivers other chats' notifications quietly.
//

import Foundation

public struct FocusChatFilter: Codable, Equatable, Sendable {
    /// Local conversation ids allowed during the Focus.
    public var chatIds: [String]
    /// Chats not chosen are left out of the chat list.
    public var hidesOtherChats: Bool
    /// Chats not chosen notify without sound or a banner.
    public var silencesOtherChats: Bool

    public init(chatIds: [String], hidesOtherChats: Bool, silencesOtherChats: Bool) {
        self.chatIds = chatIds
        self.hidesOtherChats = hidesOtherChats
        self.silencesOtherChats = silencesOtherChats
    }

    public func allows(_ conversationId: String) -> Bool { chatIds.contains(conversationId) }

    private static let key = "focus.chatFilter"

    /// The filter of the Focus that's on, or nil when none applies.
    public static func load(defaults: UserDefaults? = UserDefaults(suiteName: RelayStore.appGroupId)) -> FocusChatFilter? {
        guard let data = defaults?.data(forKey: key),
              let filter = try? JSONDecoder().decode(FocusChatFilter.self, from: data),
              !filter.chatIds.isEmpty
        else { return nil }
        return filter
    }

    public static func save(_ filter: FocusChatFilter?, defaults: UserDefaults? = UserDefaults(suiteName: RelayStore.appGroupId)) {
        if let filter, !filter.chatIds.isEmpty, let data = try? JSONEncoder().encode(filter) {
            defaults?.set(data, forKey: key)
        } else {
            defaults?.removeObject(forKey: key)
        }
    }
}
