//
//  RelayFocusFilter.swift
//  Relay
//
//  Focus filter (Settings > Focus > a Focus > Add Filter > Relay): pick the
//  chats that matter during that Focus. Others leave the chat list (unless
//  turned off) and notify quietly. iOS runs the intent again with no chats
//  when the Focus ends, which clears the filter.
//

import AppIntents
import Foundation
import Observation
import RelayCore

nonisolated struct RelayFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Relay Chats"
    static let description: IntentDescription? = IntentDescription(
        "Choose the chats that show and notify during this Focus."
    )

    @Parameter(title: "Chats") var chats: [ChatEntity]?
    @Parameter(title: "Hide Other Chats", default: true) var hideOthers: Bool
    @Parameter(title: "Silence Other Chats", default: true) var silenceOthers: Bool

    var displayRepresentation: DisplayRepresentation {
        let names = (chats ?? []).map(\.name)
        let title: LocalizedStringResource = names.isEmpty ? "All chats" : "\(names.count) chats"
        return DisplayRepresentation(
            title: title,
            subtitle: names.isEmpty ? nil : "\(names.prefix(3).joined(separator: ", "))"
        )
    }

    func perform() async throws -> some IntentResult {
        let ids = (chats ?? []).map(\.id)
        let filter = ids.isEmpty ? nil : FocusChatFilter(
            chatIds: ids, hidesOtherChats: hideOthers, silencesOtherChats: silenceOthers
        )
        FocusChatFilter.save(filter)
        await MainActor.run { FocusFilterState.shared.reload() }
        return .result()
    }
}

/// The Focus filter as the app sees it, plus "Show All" for this session.
@Observable
final class FocusFilterState {
    static let shared = FocusFilterState()

    private(set) var filter: FocusChatFilter?
    /// The user tapped Show All on the chat list's Focus row.
    var showingAll = false

    private init() { filter = FocusChatFilter.load() }

    func reload() {
        let latest = FocusChatFilter.load()
        if latest != filter {
            filter = latest
            showingAll = false
        }
    }

    /// Left out of the chat list by the current Focus.
    func hides(_ conversationId: String) -> Bool {
        guard let filter, filter.hidesOtherChats, !showingAll else { return false }
        return !filter.allows(conversationId)
    }

    /// No in-app banner for this chat during the current Focus.
    func silences(_ conversationId: String) -> Bool {
        guard let filter, filter.silencesOtherChats else { return false }
        return !filter.allows(conversationId)
    }
}
