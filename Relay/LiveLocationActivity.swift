//
//  LiveLocationActivity.swift
//  Relay
//
//  Lock Screen and Dynamic Island card while live location is being shared.
//  LiveLocationAttributes and StopLiveLocationIntent are also defined in
//  RelayWidgetExtension (same names, which is how ActivityKit and App Intents
//  match them); this copy's intent is the one that runs, in the app.
//

import ActivityKit
import AppIntents
import Foundation

struct LiveLocationAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var expiresAt: Date
    }
    /// Who it's shared with, as shown in the chat list.
    var recipientName: String
}

struct StopLiveLocationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Sharing Location"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await MainActor.run { LocationShareManager.shared.stopCurrent() }
        return .result()
    }
}

@MainActor
enum LiveLocationActivity {
    private static var current: Activity<LiveLocationAttributes>?

    static func start(recipientName: String, expiresAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        current = try? Activity.request(
            attributes: LiveLocationAttributes(recipientName: recipientName),
            content: .init(state: .init(expiresAt: expiresAt), staleDate: expiresAt),
            pushType: nil
        )
    }

    static func end() {
        let activity = current
        current = nil
        Task {
            // Also clears any left over from a previous launch.
            await activity?.end(nil, dismissalPolicy: .immediate)
            for other in Activity<LiveLocationAttributes>.activities {
                await other.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
