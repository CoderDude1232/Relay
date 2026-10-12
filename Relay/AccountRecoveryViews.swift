//
//  AccountRecoveryViews.swift
//  Relay
//
//  Email-free sign-up, the recovery key (sign-in, viewing, saving) and email
//  removal, each with its trade-offs spelled out.
//

import RelayKit
import SwiftUI

// MARK: - Trade-offs

/// One trade-off line: a symbol and a sentence.
private struct TradeoffRow: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct NoEmailTradeoffs: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TradeoffRow(symbol: "checkmark.shield.fill", tint: .green,
                        text: "Nothing that identifies you is stored: no email, and no sign-in provider ever sees you.")
            TradeoffRow(symbol: "person.badge.key.fill", tint: .green,
                        text: "You sign in with a passkey, which syncs to your other Apple devices through iCloud Keychain.")
            TradeoffRow(symbol: "key.horizontal.fill", tint: .orange,
                        text: "Your recovery key is the only backup. Keep it somewhere safe, like a password manager or on paper.")
            TradeoffRow(symbol: "exclamationmark.triangle.fill", tint: .red,
                        text: "There's no \"forgot password\" by email. If you lose your passkey and your recovery key, the account can't be recovered by anyone, including us.")
        }
    }
}

// MARK: - Sign up without email (onboarding)

struct PasskeySignupIntroView: View {
    let onContinue: () -> Void
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: .circle)
                    }
                    .accessibilityLabel("Back")
                    Spacer()
                }
                .padding(.top, 16)

                VStack(spacing: 6) {
                    Text("No email")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("Just a username and a passkey.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }

                NoEmailTradeoffs()
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(20)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 20, style: .continuous))

                Button(action: onContinue) {
                    Text("I Understand, Continue")
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.06, green: 0.02, blue: 0.22))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white, in: .rect(cornerRadius: 16, style: .continuous))
                }

                Text("You'll pick a username, then create a passkey with Face ID. We'll show you your recovery key straight after.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                Spacer().frame(height: 30)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Sign in with a recovery key

struct RecoveryKeySignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $key, axis: .vertical)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .accessibilityLabel("Recovery key")
                } footer: {
                    Text(errorMessage ?? "Signs in without your password or an email code, and brings back your chat list. Your other devices are signed out.")
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Recovery Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Sign In") { signIn() }
                            .bold()
                            .disabled(!RecoveryKey.isPlausible(key))
                    }
                }
            }
            .interactiveDismissDisabled(working)
        }
        .presentationDetents([.medium])
    }

    private func signIn() {
        working = true
        errorMessage = nil
        Task {
            do {
                try await model.signInWithRecoveryKey(key)
                dismiss()
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
            working = false
        }
    }
}

// MARK: - Showing a key

struct RecoveryKeyCard: View {
    let key: String
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Text(RecoveryKey.format(key))
                .font(.title3.monospaced().weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(.fill.tertiary, in: .rect(cornerRadius: 14, style: .continuous))
                .accessibilityLabel(RecoveryKey.format(key).map { String($0) }.joined(separator: " "))
            Button {
                SecurePasteboard.copySecret(RecoveryKey.format(key))
                copied = true
                Task { try? await Task.sleep(for: .seconds(2)); copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
    }
}

/// Shown once after an email-free sign-up.
struct NewRecoveryKeySheet: View {
    let key: String
    let onDone: () -> Void
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("This is the only way back into your account if you lose your passkey. Store it somewhere safe: a password manager, or written down.")
                    RecoveryKeyCard(key: key)
                    Text("You can see it again any time in Settings → Account → Recovery Key.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("I've saved my recovery key", isOn: $saved)
                }
                .padding(24)
            }
            .navigationTitle("Your Recovery Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone).bold().disabled(!saved)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

// MARK: - Settings → Account → Recovery Key

struct RecoveryKeyView: View {
    let service: MessagingService
    let methods: SignInMethods?
    @Environment(AppModel.self) private var model
    @State private var revealed: String?
    @State private var working = false
    @State private var errorMessage: String?
    @State private var showingEmailCode = false
    @State private var confirmingReplace = false

    private var email: String? { model.accountEmail }
    private var hasPasskey: Bool { (methods?.passkeys ?? 0) > 0 }
    private var hasKey: Bool { methods?.recoveryKey == true || service.recoveryKey != nil }

    var body: some View {
        List {
            if let revealed {
                Section {
                    RecoveryKeyCard(key: revealed)
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("Anyone with this key can sign in to your account, so keep it private.")
                }
                Section {
                    Button("Create New Key", role: .destructive) { confirmingReplace = true }
                } footer: {
                    Text("Makes a new key and stops the old one working.")
                }
            } else {
                Section {
                    if hasPasskey {
                        Button { Task { await revealWithPasskey() } } label: {
                            Label("Show with Passkey", systemImage: "person.badge.key.fill")
                        }
                    }
                    if email != nil {
                        Button { showingEmailCode = true } label: {
                            Label("Show with Email Code", systemImage: "envelope.fill")
                        }
                    }
                    if !hasPasskey && email == nil {
                        Text("Add a passkey to view your recovery key.")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(errorMessage ?? (hasKey
                        ? "Your recovery key signs you in without your password, an email code or a passkey, and brings back your chat list. Confirm it's you to see it."
                        : "A recovery key signs you in without your password, an email code or a passkey, and brings back your chat list. Confirm it's you to create one."))
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                }
            }
        }
        .navigationTitle("Recovery Key")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if working { ProgressView() } }
        .sheet(isPresented: $showingEmailCode) {
            if let email {
                EmailCodeConfirmSheet(email: email) { Task { await reveal() } }
            }
        }
        .confirmationDialog("Create a new recovery key?", isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button("Create New Key", role: .destructive) { Task { await create() } }
        } message: {
            Text("Your old key will stop working straight away.")
        }
    }

    private func revealWithPasskey() async {
        errorMessage = nil
        do {
            try await model.confirmWithPasskey()
            await reveal()
        } catch PasskeyError.canceled {
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }

    /// Shows the key, making one only if the account has none. A key that
    /// exists but couldn't be loaded here (say, the chat list didn't download)
    /// is never silently replaced: the one the user wrote down would stop working.
    private func reveal() async {
        if service.recoveryKey == nil { await service.restoreAccountStorage() }
        if let key = service.recoveryKey {
            revealed = key
        } else if methods?.recoveryKey != false { // unknown counts as "has one"
            errorMessage = "Your recovery key couldn't be loaded on this device. Check your connection and try again, or create a new key (the old one will stop working)."
            confirmingReplace = true
        } else {
            await create()
        }
    }

    private func create() async {
        working = true
        defer { working = false }
        do {
            revealed = try await service.createRecoveryKey()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
}

/// Sends a sign-in code to the account's email and checks it.
private struct EmailCodeConfirmSheet: View {
    let email: String
    let onConfirmed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var sent = false
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if sent {
                        TextField("Code", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    } else {
                        LabeledContent("Email", value: email)
                    }
                } footer: {
                    Text(errorMessage ?? (sent ? "Enter the code we sent to \(email)." : "We'll email you a code to confirm it's you."))
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Confirm It's You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else if sent {
                        Button("Confirm") { Task { await verify() } }.bold().disabled(code.count < 6)
                    } else {
                        Button("Send Code") { Task { await send() } }.bold()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func send() async {
        working = true
        defer { working = false }
        do {
            try await SupabaseAuth.shared.requestSignInCode(email: email)
            sent = true
            errorMessage = nil
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }

    private func verify() async {
        working = true
        defer { working = false }
        do {
            _ = try await SupabaseAuth.shared.verifySignInCode(email: email, code: code)
            dismiss()
            onConfirmed()
        } catch {
            errorMessage = "That code didn't work. Check it and try again."
        }
    }
}

// MARK: - Remove email

struct RemoveEmailSheet: View {
    let onRemoved: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Your email is deleted from Relay and from our sign-in provider. After this, a legal demand to either couldn't link your account to an email address.")
                    NoEmailTradeoffs()
                    TradeoffRow(symbol: "envelope.badge.shield.half.filled.fill", tint: .orange,
                                text: "Signing in with an email code, Apple or Google stops working for this account. Find Me by Email is turned off.")
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                    Button(role: .destructive) {
                        Task { await remove() }
                    } label: {
                        HStack {
                            Spacer()
                            if working { ProgressView() } else { Text("Remove My Email").bold() }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(working)
                    Text("You'll confirm with Face ID and your passkey. Make sure you've saved your recovery key first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .navigationTitle("Remove Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(working)
                }
            }
        }
    }

    private func remove() async {
        working = true
        defer { working = false }
        errorMessage = nil
        do {
            try await model.removeEmail()
            dismiss()
            onRemoved()
        } catch PasskeyError.canceled {
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
}
