//
//  RelayWatchApp.swift
//  RelayWatch Watch App
//

import SwiftUI

@main
struct RelayWatchApp: App {
    @State private var session = WatchSession()

    var body: some Scene {
        WindowGroup {
            ChatListView()
                .environment(session)
        }
    }
}
