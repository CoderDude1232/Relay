//
//  ContentView.swift
//  Relay
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .onboarding:
            OnboardingView()
        case .ready(let service):
            MainTabView(service: service)
        case .failed(let message):
            ContentUnavailableView(
                "Storage Unavailable",
                systemImage: "lock.trianglebadge.exclamationmark",
                description: Text(message)
            )
        }
    }
}

struct MainTabView: View {
    let service: MessagingService

    var body: some View {
        TabView {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill") {
                ConversationListView(service: service)
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView(service: service)
            }
        }
    }
}
