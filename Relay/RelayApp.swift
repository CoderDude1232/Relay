//
//  RelayApp.swift
//  Relay
//
//  Created by Ethan Daly on 18/7/2026.
//

import SwiftUI

@main
struct RelayApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { model.boot() }
        }
    }
}
