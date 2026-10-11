//
//  PasskeysView.swift
//  Relay
//
//  Settings → Account → Passkeys: list, add and remove passkeys.
//

import RelayKit
import SwiftUI

struct PasskeysView: View {
    let service: MessagingService
    @Environment(AppModel.self) private var model
    @State private var passkeys: [PasskeySummary] = []
    @State private var isLoading = true
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var pendingDelete: PasskeySummary?

    var body: some View {
        List {
            Section {
                ForEach(passkeys) { passkey in
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "person.badge.key.fill", color: .green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(passkey.name.isEmpty ? "Passkey" : passkey.name)
                            Text("Added \(Date(timeIntervalSince1970: Double(passkey.createdAt) / 1000).formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions {
                        Button("Remove", role: .destructive) { pendingDelete = passkey }
                    }
                }
                if isLoading && passkeys.isEmpty {
                    ProgressView()
                } else if passkeys.isEmpty {
                    Text("No passkeys yet")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(errorMessage ?? "A passkey signs you in with Face ID or Touch ID and is stored in your iCloud Keychain or password manager. Signing in with one on a new device brings your chat list back, and doesn't need your account password or an email code. Signing in signs out your other devices.")
            }

            Section {
                Button {
                    Task { await create() }
                } label: {
                    HStack {
                        Label("Create Passkey", systemImage: "plus.circle.fill")
                        if isCreating { Spacer(); ProgressView() }
                    }
                }
                .disabled(isCreating || passkeys.count >= 10)
            }
        }
        .navigationTitle("Passkeys")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .confirmationDialog(
            "Remove this passkey?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible, presenting: pendingDelete
        ) { passkey in
            Button("Remove", role: .destructive) { Task { await remove(passkey) } }
        } message: { _ in
            Text("You won't be able to sign in with it any more. To remove it from your iCloud Keychain too, use the Passwords app.")
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            passkeys = try await service.apiClient.passkeys()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        errorMessage = nil
        do {
            try await model.createPasskey()
            await reload()
        } catch PasskeyError.canceled {
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }

    private func remove(_ passkey: PasskeySummary) async {
        guard await BiometricGate.authenticate(reason: "Confirm it's you to remove this passkey.", requirePasscode: true) else { return }
        do {
            try await service.apiClient.deletePasskey(id: passkey.id)
            if let id = Data(base64URL: passkey.id) { await service.removePasskeySlot(credentialId: id) }
            await reload()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
}
