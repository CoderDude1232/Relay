//
//  TwoStepSettingsView.swift
//  Relay
//
//  Settings → Account → Two-Step Verification. An email or phone code proves
//  only the inbox or the number; with this on, signing in on a new device
//  that way also needs one of the methods turned on: a code from an
//  authenticator app, a passkey, or a PIN. Passkey and recovery-key sign-ins
//  never ask.
//

import CoreImage.CIFilterBuiltins
import RelayKit
import SwiftUI

struct TwoStepSettingsView: View {
    let service: MessagingService

    @State private var methods: SignInMethods?
    @State private var working = false
    @State private var errorMessage: String?
    @State private var showingAuthenticator = false
    @State private var showingPIN = false
    @State private var showingAddPasskeyFirst = false
    @State private var showingPasskeys = false

    private var on: [TwoStepRequired.Method] { methods?.twoStepMethods ?? [] }

    var body: some View {
        List {
            if let methods {
                Section {
                    toggle("Authenticator App", icon: "lock.rotation", color: .indigo, method: .authenticator) {
                        showingAuthenticator = true
                    }
                    toggle("Passkey", icon: "person.badge.key.fill", color: .teal, method: .passkey) {
                        if methods.passkeys > 0 { set(.passkey, on: true) } else { showingAddPasskeyFirst = true }
                    }
                    toggle("PIN", icon: "circle.grid.3x3.fill", color: .orange, method: .pin) {
                        if methods.accountPassword && !methods.accountPasswordNeedsUpdate {
                            set(.pin, on: true)
                        } else {
                            showingPIN = true
                        }
                    }
                    if on.contains(.pin) {
                        Button("Change PIN") { showingPIN = true }
                    }
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    } else if on.contains(.pin) && methods.accountPasswordNeedsUpdate {
                        Text("Enter your PIN again with Change PIN. It was saved by an older version of Relay and can't be checked on a new device until you do.")
                            .foregroundStyle(.orange)
                    } else {
                        Text(footer)
                    }
                }

                if on == [.recovery] {
                    Section {
                        LabeledContent("Recovery Key Only") {
                            Button("Turn Off") { set(.recovery, on: false) }
                        }
                    } footer: {
                        Text("Set before two-step verification had other options. Turning on one above replaces it.")
                    }
                }

            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Two-Step Verification")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .task { await reload() }
        .navigationDestination(isPresented: $showingAuthenticator) {
            AuthenticatorSetupView(service: service)
        }
        .navigationDestination(isPresented: $showingPIN) {
            PINSetupView(service: service)
        }
        .navigationDestination(isPresented: $showingPasskeys) {
            PasskeysView(service: service)
        }
        .onChange(of: showingAuthenticator) { _, on in if !on { Task { await reload() } } }
        .onChange(of: showingPIN) { _, on in if !on { Task { await reload() } } }
        .onChange(of: showingPasskeys) { _, on in if !on { Task { await reload() } } }
        .alert("Add a Passkey First", isPresented: $showingAddPasskeyFirst) {
            Button("Add Passkey") { showingPasskeys = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a passkey for this account, then turn it on here.")
        }
    }

    private var footer: String {
        if on == [.recovery] {
            return "Signing in with an email or phone code on a new device needs your recovery key."
        }
        if on.isEmpty {
            return "Turn one on to also ask for it when someone signs in with an email or phone code."
        }
        return "Signing in with an email or phone code also asks for one of these. Your recovery key always works instead."
    }

    private func toggle(_ title: String, icon: String, color: Color, method: TwoStepRequired.Method,
                        turnOn: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(
            get: { on.contains(method) },
            set: { newValue in newValue ? turnOn() : set(method, on: false) }
        )) {
            HStack(spacing: 14) {
                SettingsIcon(systemName: icon, color: color)
                Text(title)
            }
        }
    }

    private func set(_ method: TwoStepRequired.Method, on enabled: Bool) {
        working = true
        errorMessage = nil
        Task {
            do {
                try await service.setTwoStep(method, enabled: enabled)
                await reload()
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            working = false
        }
    }

    private func reload() async {
        if let fresh = try? await service.apiClient.signInMethods() { methods = fresh }
    }
}

// MARK: - Authenticator

private struct AuthenticatorSetupView: View {
    let service: MessagingService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var setup: (secret: String, uri: String)?
    @State private var code = ""
    @State private var working = false
    @State private var errorMessage: String?
    @State private var copied = false

    var body: some View {
        Form {
            if let setup {
                Section {
                    if let url = URL(string: setup.uri) {
                        Button("Add to Authenticator App") {
                            openURL(url) { opened in
                                if !opened { errorMessage = "No authenticator app on this iPhone opened it. Scan the code or enter the setup key instead." }
                            }
                        }
                    }
                    if let image = Self.qrImage(setup.uri) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 200)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .accessibilityLabel("Setup QR code")
                    }
                    Button {
                        SecurePasteboard.copy(setup.secret)
                        copied = true
                    } label: {
                        LabeledContent(copied ? "Copied" : "Setup Key") {
                            Text(Self.grouped(setup.secret)).font(.footnote.monospaced()).textSelection(.enabled)
                        }
                    }
                    .tint(.primary)
                } footer: {
                    Text("Add Relay to an authenticator app (Passwords, Google Authenticator, 1Password…): tap the button, scan the code from another device, or enter the setup key.")
                }
                Section {
                    TextField("6-digit code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .onChange(of: code) { _, new in
                            let digits = String(new.filter(\.isNumber).prefix(6))
                            if digits != new { code = digits }
                        }
                } header: {
                    Text("Code from the app")
                } footer: {
                    Text(errorMessage ?? "Enter the code the app shows for Relay to finish.")
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                }
            } else if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("Authenticator App")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if working {
                    ProgressView()
                } else if setup != nil {
                    Button("Turn On") { confirm() }.bold().disabled(code.count != 6)
                }
            }
        }
        .navigationBarBackButtonHidden(working)
        .task {
            do {
                setup = try await service.apiClient.setUpAuthenticator()
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
        }
    }

    private func confirm() {
        working = true
        errorMessage = nil
        Task {
            do {
                try await service.confirmAuthenticator(code: code)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch RelayAPIError.http(401, _) {
                errorMessage = "That code isn't right. Check the app's code for Relay and try again."
                code = ""
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            working = false
        }
    }

    /// "ABCD EFGH …" for reading the key off the screen.
    private static func grouped(_ secret: String) -> String {
        stride(from: 0, to: secret.count, by: 4).map { i -> String in
            let start = secret.index(secret.startIndex, offsetBy: i)
            return String(secret[start..<(secret.index(start, offsetBy: 4, limitedBy: secret.endIndex) ?? secret.endIndex)])
        }.joined(separator: " ")
    }

    private static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - PIN

private struct PINSetupView: View {
    let service: MessagingService
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var errorMessage: String?

    private static let minimumLength = 6
    private var valid: Bool { pin.count >= Self.minimumLength && pin == confirm }

    var body: some View {
        Form {
            Section {
                SecureField("PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.newPassword)
                SecureField("Confirm PIN", text: $confirm)
                    .keyboardType(.numberPad)
                    .textContentType(.newPassword)
            } footer: {
                Text(errorMessage ?? "At least \(Self.minimumLength) digits. It's asked for when you sign in on a new device with an email or phone code, and it unlocks your backup there. A longer PIN is much harder to guess.")
                    .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
            }
        }
        .modifier(ThemedPageBackground())
        .navigationTitle("PIN")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if working {
                    ProgressView()
                } else {
                    Button("Save") { save() }.bold().disabled(!valid)
                }
            }
        }
        .navigationBarBackButtonHidden(working)
        .onChange(of: pin) { _, new in let d = new.filter(\.isNumber); if d != new { pin = d } }
        .onChange(of: confirm) { _, new in let d = new.filter(\.isNumber); if d != new { confirm = d } }
    }

    private func save() {
        working = true
        errorMessage = nil
        Task {
            do {
                try await service.setPIN(pin)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            working = false
        }
    }
}
