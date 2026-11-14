//
//  PinLockSettingsView.swift
//  Relay
//
//  Settings → Panic Mode → Relay PIN Lock (PinLockManager).
//

import SwiftUI

struct PinLockSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var manager = PinLockManager.shared
    @State private var choosing: PinLockMode?
    @State private var settingDistress = false
    @State private var confirmingOff = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                SettingsHero(systemName: "lock.shield.fill", color: .indigo, title: "Relay PIN Lock",
                             message: "Ask for a PIN every time you come back to Relay. A separate distress PIN erases Relay instead.")
                    .settingsBareRow()
            }
            Section {
                option(.off, title: "Off", detail: "Relay opens as normal.")
                option(.ask, title: "Ask for PIN", detail: "Your messages stay on this iPhone, behind the PIN.")
                option(.forget, title: "Forget Messages",
                       detail: "Relay locks its messages away until the PIN is entered. Forget the PIN and they're gone.")
            } header: {
                Text("When You Leave Relay")
            } footer: {
                if manager.mode == .forget {
                    Text("While locked, notifications just say \"New message\" and calls can't ring. Unlocking needs internet. After 10 wrong PINs the messages on this iPhone are erased.")
                }
            }
            if manager.mode != .off {
                Section {
                    Button { choosing = manager.mode } label: {
                        SettingsNavRow(systemName: "circle.grid.3x3.fill", color: .indigo, title: "Change PIN")
                    }
                    .tint(.primary)
                }
            }
            Section {
                Button { settingDistress = true } label: {
                    SettingsNavRow(systemName: "exclamationmark.octagon.fill", color: .red,
                                   title: manager.hasDistressPin ? "Change Distress PIN" : "Set Distress PIN")
                }
                .tint(.primary)
                if manager.hasDistressPin {
                    Button("Remove Distress PIN", role: .destructive) {
                        Task {
                            do { try await manager.setDistressPin(nil) } catch { self.error = FriendlyError.message(for: error) }
                        }
                    }
                }
            } header: {
                Text("Distress PIN")
            } footer: {
                Text("Typing it instead of your PIN erases Relay on all your devices and shows the sign-up screen, as if Relay was never used.")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Relay PIN Lock")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $choosing) { mode in
            PinChooseView(title: mode == .forget ? "Forget Messages" : "Ask for PIN",
                          message: "Choose a PIN of 4 to 8 digits. You'll enter it every time you come back to Relay.") { pin in
                try await manager.setUp(mode: mode, pin: pin, model: model)
            }
        }
        .navigationDestination(isPresented: $settingDistress) {
            PinChooseView(title: "Distress PIN",
                          message: "Use different digits from your Relay PIN. Typing this one erases Relay everywhere.") { pin in
                try await manager.setDistressPin(pin)
            }
        }
        .confirmationDialog("Turn off the Relay PIN lock?", isPresented: $confirmingOff, titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) {
                Task {
                    do { try await manager.turnOff(model: model) } catch { self.error = FriendlyError.message(for: error) }
                }
            }
        }
    }

    private func option(_ mode: PinLockMode, title: String, detail: String) -> some View {
        Button {
            error = nil
            if mode == .off {
                if manager.mode != .off { confirmingOff = true }
            } else if mode != manager.mode {
                choosing = mode
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if manager.mode == mode {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(manager.mode == mode ? .isSelected : [])
    }
}

/// Enter a PIN twice, then save it.
private struct PinChooseView: View {
    let title: String
    let message: String
    let save: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                SettingsHero(systemName: "circle.grid.3x3.fill", color: .indigo, title: title, message: message)
                    .settingsBareRow()
            }
            Section {
                SecureField("PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .focused($focused)
                SecureField("Confirm PIN", text: $confirm)
                    .keyboardType(.numberPad)
            } footer: {
                Text(error ?? "Relay can't show you this PIN later, so pick one you'll remember.")
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
            }
            Section {
                SettingsPrimaryButton(title: saving ? "Saving…" : "Save PIN", color: .indigo) { submit() }
                    .disabled(saving || pin.count < 4 || confirm.isEmpty)
                    .settingsBareRow()
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private func submit() {
        guard (4...8).contains(pin.count) else { error = "Use 4 to 8 digits."; return }
        guard pin.allSatisfy({ $0.isASCII && $0.isNumber }) else { error = "Use digits only."; return }
        guard pin == confirm else { error = "The two PINs don't match."; return }
        saving = true
        error = nil
        let chosen = pin
        Task {
            do {
                try await save(chosen)
                dismiss()
            } catch {
                self.error = FriendlyError.message(for: error)
            }
            saving = false
        }
    }
}
