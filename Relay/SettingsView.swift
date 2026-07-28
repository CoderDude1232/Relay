//
//  SettingsView.swift
//  Relay
//

import RelayKit
import SwiftUI

struct SettingsView: View {
    let service: MessagingService

    @Environment(AppModel.self) private var model
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        AvatarView(name: service.username ?? "?", size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.username ?? "Unknown")
                                .font(.title3.bold())
                            Text(connectionLabel)
                                .font(.footnote)
                                .foregroundStyle(connectionColor)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Account") {
                    LabeledContent("Account ID") {
                        Text(service.credentials.accountId)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Device", value: "#\(service.credentials.deviceId)")
                    LabeledContent("Server", value: service.serverURL.absoluteString)
                }

                Section("Security") {
                    LabeledContent("Encryption", value: "Signal protocol (PQXDH)")
                    LabeledContent("Local storage", value: "SQLCipher encrypted")
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        confirmingSignOut = true
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Sign out and delete all local messages?",
                isPresented: $confirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign Out & Delete", role: .destructive) {
                    model.signOut()
                }
            } message: {
                Text("Message history only exists on this device — it cannot be recovered.")
            }
        }
    }

    private var connectionLabel: String {
        switch service.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnected: "Offline"
        }
    }

    private var connectionColor: Color {
        switch service.connectionState {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .secondary
        }
    }
}

/// A circular initial avatar, used across the app.
struct AvatarView: View {
    let name: String
    var size: CGFloat = 44

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    private var initial: String {
        name.first.map { String($0).uppercased() } ?? "?"
    }

    private var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        var hash = 0
        for scalar in name.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) }
        return palette[abs(hash) % palette.count]
    }
}
