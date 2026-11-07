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
    /// The account's two-step methods, as of the last reload.
    @State private var twoStep: [TwoStepRequired.Method] = []
    @State private var offeringTwoStep = false

    var body: some View {
        List {
            Section {
                ForEach(passkeys) { passkey in
                    HStack(spacing: 14) {
                        SettingsIcon(systemName: "person.badge.key.fill", color: .teal)
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
        .modifier(ThemedPageBackground())
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
        .confirmationDialog("Also ask for a passkey?", isPresented: $offeringTwoStep, titleVisibility: .visible) {
            Button("Turn On") { Task { await turnOnPasskeyTwoStep() } }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("When someone signs in on a new device with an email or phone code, Relay will also ask for one of your passkeys.")
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            passkeys = try await service.apiClient.passkeys()
            if let methods = try? await service.apiClient.signInMethods() { twoStep = methods.twoStepMethods }
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
            // Most people adding a passkey want it to guard code sign-ins too;
            // offered, not automatic, so an email-only fallback isn't lost unasked.
            if !twoStep.contains(.passkey) && twoStep != [.recovery] { offeringTwoStep = true }
        } catch PasskeyError.canceled {
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }

    private func turnOnPasskeyTwoStep() async {
        do {
            try await service.setTwoStep(.passkey, enabled: true)
            await reload()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }

    private func remove(_ passkey: PasskeySummary) async {
        // With two-step on, the relay asks for it before removing; Face ID
        // would only ask a second time.
        if twoStep.isEmpty || twoStep == [.recovery] {
            guard await BiometricGate.authenticate(reason: "Confirm it's you to remove this passkey.", requirePasscode: true) else { return }
        }
        do {
            try await service.apiClient.deletePasskey(id: passkey.id)
            if let id = Data(base64URL: passkey.id) { await service.removePasskeySlot(credentialId: id) }
            await reload()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
}
